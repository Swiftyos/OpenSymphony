defmodule SymphonyElixir.RunEvents do
  @moduledoc """
  How event payloads travel between a runner and the controller.

  Agent events carry atoms, structs and `DateTime`s, so a payload is an Erlang
  term encoded with `term_to_binary/1` and base64ed for JSON. The controller
  decodes with the `:safe` option, which refuses to create atoms or functions
  that weren't already loaded in the controller. Runner and controller run the
  same release, so nothing legitimate is refused.
  """

  @doc "Encodes one event payload as a JSON-safe string."
  @spec encode(term()) :: String.t()
  def encode(term), do: term |> :erlang.term_to_binary() |> Base.encode64()

  @doc "Decodes a payload produced by `encode/1`; `{:error, :invalid}` for anything else."
  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, binary} <- decode64(encoded) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end

  def decode(_encoded), do: {:error, :invalid}

  defp decode64(encoded) do
    case Base.decode64(encoded) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid}
    end
  end
end
