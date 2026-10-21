defmodule SymphonyElixir.RunToken do
  @moduledoc """
  The bearer token a runner presents to the controller.

  A token is `HMAC-SHA256(secret_key_base, "<run_id>:<epoch>")`, base64url
  encoded without padding. The epoch fences attempts: a token minted for an
  earlier run of the issue no longer verifies against the epoch the registry
  records, and the controller answers `409` instead of accepting its events.
  See `docs/durable-runs.md`.

  The secret is the endpoint's `secret_key_base`: it is stable across a
  restart (or everyone would be signed out), which is what lets a runner use
  the token it was given before the controller restarted.
  """

  alias SymphonyElixir.HttpServer
  alias SymphonyElixirWeb.Endpoint

  @doc "The HMAC token for a run at an epoch."
  @spec sign(String.t(), pos_integer()) :: String.t()
  def sign(run_id, epoch) when is_binary(run_id) and is_integer(epoch) and epoch > 0 do
    :crypto.mac(:hmac, :sha256, secret(), "#{run_id}:#{epoch}")
    |> Base.url_encode64(padding: false)
  end

  @doc "Whether `token` is the token for this run at this epoch."
  @spec verify(String.t(), pos_integer(), String.t() | nil) :: boolean()
  def verify(run_id, epoch, token) when is_binary(run_id) and is_integer(epoch) and epoch > 0 and is_binary(token) do
    Plug.Crypto.secure_compare(sign(run_id, epoch), token)
  end

  def verify(_run_id, _epoch, _token), do: false

  @doc """
  Whether `token` is valid for any epoch from `max_epoch` down to 1.

  Used only to tell a stale epoch (the token is genuine but for an earlier run,
  so `409`) from a forged one (`401`): the token is an HMAC and doesn't carry
  its epoch in readable form.
  """
  @spec verify_any_epoch(String.t(), String.t() | nil, pos_integer()) :: boolean()
  def verify_any_epoch(run_id, token, max_epoch)
      when is_binary(run_id) and is_binary(token) and is_integer(max_epoch) and max_epoch > 0 do
    Enum.any?(1..max_epoch, &verify(run_id, &1, token))
  end

  def verify_any_epoch(_run_id, _token, _max_epoch), do: false

  @doc "The secret the token is signed with."
  @spec secret() :: String.t()
  def secret do
    case Application.get_env(:symphony_elixir, Endpoint, [])[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) >= 64 -> secret
      _ -> HttpServer.secret_key_base()
    end
  end
end
