defmodule SymphonyElixir.Iap do
  @moduledoc """
  Verifies the signed header Google Identity-Aware Proxy adds to every request
  it lets through (`x-goog-iap-jwt-assertion`).

  The dashboard has no sign-in of its own: IAP signs people in with Google and
  enforces who may open the address. Checking the signed header, not the plain
  `x-goog-authenticated-user-email`, means a request that reaches Symphony some
  other way (the internal load balancer, a port-forward) gets nothing.

  A token is accepted when it is an ES256 JWT signed by one of Google's IAP keys
  (`#{"https://www.gstatic.com/iap/verify/public_key-jwk"}`), issued by
  `https://cloud.google.com/iap`, unexpired, and addressed to one of
  `server.iap_audiences` (`/projects/<number>/global/backendServices/<id>`).
  A list, so moving the load balancer to a new backend service doesn't sign
  everyone out mid-cutover.

  Keys are fetched on first use and cached for an hour; an unknown key id
  refetches at most once a minute. Tests set `:iap_jwks` (a list of JWK maps)
  instead.
  """

  require Logger

  @table :symphony_iap_keys
  @keys_url "https://www.gstatic.com/iap/verify/public_key-jwk"
  @issuer "https://cloud.google.com/iap"
  @keys_ttl_ms 3_600_000
  @refetch_interval_ms 60_000
  # Clock skew allowed between Google and this host.
  @leeway_s 30

  @type identity :: %{email: String.t(), subject: String.t() | nil}

  @doc false
  @spec create_table() :: :ok
  def create_table do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  @doc """
  Checks an IAP assertion against the accepted audiences.
  """
  @spec verify(String.t() | nil, [String.t()]) :: {:ok, identity()} | {:error, atom()}
  def verify(token, audiences) when is_binary(token) and is_list(audiences) and audiences != [] do
    with [header64, claims64, signature64] <- String.split(token, "."),
         {:ok, %{"alg" => "ES256", "kid" => kid}} when is_binary(kid) <- decode_json(header64),
         {:ok, claims} when is_map(claims) <- decode_json(claims64),
         {:ok, signature} <- Base.url_decode64(signature64, padding: false),
         {:ok, key} <- key(kid),
         true <- signature_valid?(header64 <> "." <> claims64, signature, key) || {:error, :bad_signature},
         :ok <- check_claims(claims, audiences) do
      {:ok, %{email: String.downcase(claims["email"]), subject: claims["sub"]}}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def verify(nil, _audiences), do: {:error, :missing}
  def verify(_token, []), do: {:error, :no_audience}
  def verify(_token, _audiences), do: {:error, :malformed}

  defp decode_json(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false),
         {:ok, value} <- Jason.decode(json) do
      {:ok, value}
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_claims(claims, audiences) do
    now = System.system_time(:second)

    cond do
      claims["iss"] != @issuer -> {:error, :bad_issuer}
      claims["aud"] not in audiences -> {:error, :bad_audience}
      not before?(now - @leeway_s, claims["exp"]) -> {:error, :expired}
      not before?(claims["iat"], now + @leeway_s) -> {:error, :not_yet_valid}
      not is_binary(claims["email"]) or claims["email"] == "" -> {:error, :no_email}
      true -> :ok
    end
  end

  # Both times must be integers, and `a` no later than `b`.
  defp before?(a, b), do: is_integer(a) and is_integer(b) and a <= b

  # JOSE ES256 signatures are r || s; :crypto wants a DER ECDSA-Sig-Value.
  defp signature_valid?(message, <<r::binary-size(32), s::binary-size(32)>>, key) do
    :crypto.verify(:ecdsa, :sha256, message, der_signature(r, s), [key, :secp256r1])
  end

  defp signature_valid?(_message, _signature, _key), do: false

  defp der_signature(r, s) do
    body = der_integer(r) <> der_integer(s)
    <<0x30, byte_size(body)>> <> body
  end

  defp der_integer(bytes) do
    bytes = bytes |> :binary.decode_unsigned() |> :binary.encode_unsigned()
    bytes = if :binary.first(bytes) >= 0x80, do: <<0>> <> bytes, else: bytes
    <<0x02, byte_size(bytes)>> <> bytes
  end

  # ------------------------------------------------------------------ keys

  defp key(kid) do
    case Map.fetch(keys(false), kid) do
      {:ok, key} ->
        {:ok, key}

      :error ->
        # Google rotates keys; a new kid may be newer than our copy.
        case Map.fetch(keys(true), kid) do
          {:ok, key} -> {:ok, key}
          :error -> {:error, :unknown_key}
        end
    end
  end

  defp keys(refresh?) do
    case Application.get_env(:symphony_elixir, :iap_jwks) do
      jwks when is_list(jwks) -> parse_keys(jwks)
      _ -> cached_keys(refresh?)
    end
  end

  defp cached_keys(refresh?) do
    create_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, :keys) do
      [{:keys, keys, fetched_at}] when not refresh? and now - fetched_at < @keys_ttl_ms -> keys
      [{:keys, keys, fetched_at}] when refresh? and now - fetched_at < @refetch_interval_ms -> keys
      cached -> fetch_keys(now, cached)
    end
  end

  defp fetch_keys(now, cached) do
    case Req.get(@keys_url, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200, body: %{"keys" => jwks}}} when is_list(jwks) ->
        keys = parse_keys(jwks)
        :ets.insert(@table, {:keys, keys, now})
        keys

      other ->
        Logger.warning("IAP key fetch failed: #{inspect(other, limit: 5)}")

        case cached do
          # Keep using the old keys, and don't ask again for a minute.
          [{:keys, keys, _fetched_at}] -> tap(keys, &:ets.insert(@table, {:keys, &1, now - @keys_ttl_ms + @refetch_interval_ms}))
          _ -> %{}
        end
    end
  end

  defp parse_keys(jwks) do
    for %{"kty" => "EC", "crv" => "P-256", "kid" => kid, "x" => x, "y" => y} <- jwks,
        {:ok, x} <- [Base.url_decode64(x, padding: false)],
        {:ok, y} <- [Base.url_decode64(y, padding: false)],
        into: %{},
        do: {kid, <<4>> <> x <> y}
  end
end
