defmodule SymphonyElixir.McpTokens do
  @moduledoc """
  Access tokens for the MCP endpoint (`/mcp`), so agents can watch and steer
  Symphony without a browser session.

  Each Symphony account (or the local operator in `:local` auth mode) has one
  token, and it can do exactly what its account can: every request re-resolves
  the account through `SymphonyElixir.Auth`, so a disabled account or a lost
  Linear role applies at once. Rotating issues a new token and stops every
  older one.

  Tokens are 256-bit random strings. Lookups use their SHA-256; the dashboard
  also keeps a copy encrypted with the server's `secret_key_base`
  (`Plug.Crypto.encrypt/4`), so the setup page can always show the install
  commands with the current token in them. Stored in
  `~/.symphony/mcp_tokens.json` through `SymphonyElixir.StateStore` (a file at
  mode 0600 or a Postgres row).

  Tokens from before this design (several per account, with scopes, shown only
  once and stored only as a hash) are dropped when the store loads: they would
  otherwise gain their account's full access. Their owners get a new token on
  their next dashboard visit.
  """

  use GenServer
  require Logger

  @table :symphony_mcp_tokens
  @prefix "symp_"
  @encryption_salt "symphony mcp token"
  # last_used_at is written to disk at most this often per token.
  @touch_interval_ms 60_000

  @type token :: %{
          id: String.t(),
          account_id: String.t(),
          hint: String.t(),
          created_at: String.t(),
          last_used_at: String.t() | nil,
          last_used_ip: String.t() | nil,
          sealed: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The account's token and its secret, created the first time it's asked for.
  """
  @spec current(String.t()) :: {:ok, String.t(), token()} | {:error, atom()}
  def current(account_id), do: GenServer.call(__MODULE__, {:current, account_id})

  @doc """
  Replaces the account's token with a new one. Every older token stops working.
  """
  @spec rotate(String.t()) :: {:ok, String.t(), token()} | {:error, atom()}
  def rotate(account_id), do: GenServer.call(__MODULE__, {:rotate, account_id})

  @doc """
  Looks up a presented secret.
  """
  @spec verify(String.t()) :: {:ok, token()} | {:error, :invalid_token}
  def verify(@prefix <> _rest = secret) do
    with true <- ready?(),
         [{_hash, record}] <- :ets.lookup(@table, hash(secret)) do
      {:ok, record}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_secret), do: {:error, :invalid_token}

  @doc """
  Records that a token was used (throttled, asynchronous).
  """
  @spec touch(String.t(), String.t() | nil) :: :ok
  def touch(id, ip), do: GenServer.cast(__MODULE__, {:touch, id, ip})

  @doc false
  @spec reset() :: :ok
  def reset do
    if ready?(), do: GenServer.call(__MODULE__, :reset)
    :ok
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    load(path)
    {:ok, %{path: path, touched: %{}}}
  end

  @impl true
  def handle_call({action, account_id}, _from, state)
      when action in [:current, :rotate] and (not is_binary(account_id) or account_id == "") do
    {:reply, {:error, :invalid_account}, state}
  end

  def handle_call({:current, account_id}, _from, state) do
    case Enum.find_value(records(), &(&1.account_id == account_id and unseal(&1))) do
      {secret, record} -> {:reply, {:ok, secret, record}, state}
      nil -> {:reply, issue(account_id, state), state}
    end
  end

  def handle_call({:rotate, account_id}, _from, state) do
    :ets.match_delete(@table, {:_, %{account_id: account_id}})
    Logger.info("MCP token rotated account=#{account_id}")
    {:reply, issue(account_id, state), state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | touched: %{}}}
  end

  @impl true
  def handle_cast({:touch, id, ip}, state) do
    now_ms = System.monotonic_time(:millisecond)

    # Monotonic time can be negative, so "never touched" isn't a number.
    if not Map.has_key?(state.touched, id) or now_ms - state.touched[id] >= @touch_interval_ms do
      record_use(state.path, id, ip)
      {:noreply, %{state | touched: Map.put(state.touched, id, now_ms)}}
    else
      {:noreply, state}
    end
  end

  defp issue(account_id, state) do
    secret = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    record = %{
      id: "tok_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      account_id: account_id,
      # Enough to recognise a token, far too little to guess it.
      hint: String.slice(secret, 0, 9) <> "…" <> String.slice(secret, -4, 4),
      created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      last_used_at: nil,
      last_used_ip: nil,
      sealed: Plug.Crypto.encrypt(key_base(), @encryption_salt, secret)
    }

    :ets.insert(@table, {hash(secret), record})
    persist(state.path)
    Logger.info("MCP token issued id=#{record.id} account=#{account_id}")
    {:ok, secret, record}
  end

  # A token whose copy can't be decrypted (the secret_key_base changed) still
  # works for agents; the page then issues a new one to show.
  defp unseal(%{sealed: sealed} = record) do
    case Plug.Crypto.decrypt(key_base(), @encryption_salt, sealed, max_age: :infinity) do
      {:ok, secret} when is_binary(secret) -> {secret, record}
      _ -> nil
    end
  end

  # The running endpoint's key (what sessions use); without an endpoint, the
  # persisted one.
  defp key_base do
    SymphonyElixirWeb.Endpoint.config(:secret_key_base) || SymphonyElixir.HttpServer.secret_key_base()
  rescue
    ArgumentError -> SymphonyElixir.HttpServer.secret_key_base()
  end

  defp record_use(path, id, ip) do
    case Enum.find(:ets.tab2list(@table), fn {_hash, record} -> record.id == id end) do
      {hash, record} ->
        used_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        :ets.insert(@table, {hash, %{record | last_used_at: used_at, last_used_ip: ip}})
        persist(path)

      nil ->
        :ok
    end
  end

  defp ready?, do: :ets.whereis(@table) != :undefined

  defp records, do: if(ready?(), do: @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)), else: [])

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  defp default_path, do: Application.get_env(:symphony_elixir, :mcp_tokens_path, Path.expand("~/.symphony/mcp_tokens.json"))

  defp persist(nil), do: :ok

  defp persist(path) do
    tokens =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {hash, record} -> Map.put(record, :hash, hash) end)
      |> Enum.sort_by(& &1.created_at)

    case SymphonyElixir.StateStore.write(path, Jason.encode!(%{version: 2, tokens: tokens}, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("MCP token save failed path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp load(nil), do: :ok

  defp load(path) do
    with {:ok, body} <- SymphonyElixir.StateStore.read(path),
         {:ok, %{"tokens" => tokens}} when is_list(tokens) <- Jason.decode(body) do
      dropped = Enum.count(tokens, &(load_record(&1) == :dropped))

      if dropped > 0 do
        Logger.warning("MCP tokens from before rotation dropped count=#{dropped}")
        persist(path)
      end
    else
      {:error, :enoent} -> :ok
      other -> Logger.error("MCP token load failed path=#{path} reason=#{inspect(other, limit: 5)}")
    end
  end

  # Only tokens with an encrypted copy load. Version 1 records (several per
  # account, scoped, hash only) are dropped rather than gaining their account's
  # full access.
  defp load_record(%{"hash" => hash, "id" => id, "account_id" => account_id, "sealed" => sealed} = raw)
       when is_binary(hash) and is_binary(id) and is_binary(account_id) and is_binary(sealed) do
    record = %{
      id: id,
      account_id: account_id,
      hint: raw["hint"] || "",
      created_at: raw["created_at"],
      last_used_at: raw["last_used_at"],
      last_used_ip: raw["last_used_ip"],
      sealed: sealed
    }

    :ets.insert(@table, {hash, record})
  end

  defp load_record(_raw), do: :dropped
end
