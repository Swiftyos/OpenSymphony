defmodule SymphonyElixir.McpTokens do
  @moduledoc """
  Access tokens for the MCP endpoint (`/mcp`), so agents can watch and steer
  Symphony without a browser session.

  A token belongs to a Symphony account (or to the local operator in `:local`
  auth mode) and never carries more than that account may do: every request
  re-resolves the account through `SymphonyElixir.Auth`, so a disabled account
  or a lost Linear role stops its tokens at once. On top of that a token has
  scopes: `read` (look) and optionally `write` (change flows, move issues,
  message agents), and resources: `["*"]` for everything (admins only), or
  team keys and `project:<slug>` scopes it is limited to
  (`SymphonyElixir.Auth.restrict_to/2`).

  Tokens are 256-bit random strings shown once at creation. Only their SHA-256
  is stored (`~/.symphony/mcp_tokens.json` through `SymphonyElixir.StateStore`, so
  a file at mode 0600 or a Postgres row), so the file can't be
  used to call the API. Every token expires; the longest lifetime is
  `server.mcp.token_max_days`.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config

  @table :symphony_mcp_tokens
  @prefix "symp_"
  @scopes ["read", "write"]
  @max_per_account 20
  @max_name_length 60
  @max_resources 50
  @team_pattern ~r/^[A-Z0-9][A-Z0-9_-]{0,15}$/
  @project_pattern ~r/^project:[A-Za-z0-9][A-Za-z0-9_-]{0,95}$/
  # last_used_at is written to disk at most this often per token.
  @touch_interval_ms 60_000

  @type token :: %{
          id: String.t(),
          name: String.t(),
          account_id: String.t(),
          scopes: [String.t()],
          resources: [String.t()],
          hint: String.t(),
          created_at: String.t(),
          expires_at: String.t(),
          last_used_at: String.t() | nil,
          last_used_ip: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Creates a token for an account. Returns the secret once; it can't be shown
  again. The caller checks that the owner may grant `resources`.
  """
  @spec create(String.t(), String.t(), [String.t()], pos_integer(), [String.t()]) ::
          {:ok, String.t(), token()} | {:error, atom()}
  def create(account_id, name, scopes, days, resources) do
    GenServer.call(__MODULE__, {:create, account_id, name, scopes, days, resources})
  end

  @doc """
  The account's tokens, newest first, without secrets.
  """
  @spec list(String.t()) :: [token()]
  def list(account_id) when is_binary(account_id) do
    if ready?() do
      @table
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&(&1.account_id == account_id))
      |> Enum.sort_by(& &1.created_at, :desc)
    else
      []
    end
  end

  @spec revoke(String.t(), String.t()) :: :ok | {:error, :not_found}
  def revoke(account_id, id), do: GenServer.call(__MODULE__, {:revoke, account_id, id})

  @doc """
  Looks up a presented secret. Expired tokens are refused.
  """
  @spec verify(String.t()) :: {:ok, token()} | {:error, :invalid_token | :expired_token}
  def verify(@prefix <> _rest = secret) do
    with true <- ready?(),
         [{_hash, record}] <- :ets.lookup(@table, hash(secret)) do
      if expired?(record), do: {:error, :expired_token}, else: {:ok, record}
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
  def handle_call({:create, account_id, name, scopes, days, resources}, _from, state) do
    with :ok <- validate_account(account_id),
         {:ok, name} <- validate_name(name),
         {:ok, scopes} <- validate_scopes(scopes),
         {:ok, resources} <- validate_resources(resources),
         {:ok, days} <- validate_days(days),
         :ok <- check_limit(account_id) do
      secret = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      record = %{
        id: "tok_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        name: name,
        account_id: account_id,
        scopes: scopes,
        resources: resources,
        # Enough to recognise a token in a list, far too little to guess it.
        hint: String.slice(secret, 0, 9) <> "…" <> String.slice(secret, -4, 4),
        created_at: DateTime.to_iso8601(now),
        expires_at: now |> DateTime.add(days * 86_400, :second) |> DateTime.to_iso8601(),
        last_used_at: nil,
        last_used_ip: nil
      }

      :ets.insert(@table, {hash(secret), record})
      persist(state.path)
      Logger.info("MCP token created id=#{record.id} account=#{account_id} scopes=#{Enum.join(scopes, ",")} resources=#{Enum.join(resources, ",")} days=#{days}")
      {:reply, {:ok, secret, record}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:revoke, account_id, id}, _from, state) do
    case Enum.find(:ets.tab2list(@table), fn {_hash, record} -> record.id == id and record.account_id == account_id end) do
      {hash, _record} ->
        :ets.delete(@table, hash)
        persist(state.path)
        Logger.info("MCP token revoked id=#{id} account=#{account_id}")
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
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

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  defp expired?(%{expires_at: expires_at}) do
    case DateTime.from_iso8601(expires_at || "") do
      {:ok, at, _offset} -> DateTime.compare(at, DateTime.utc_now()) != :gt
      _ -> true
    end
  end

  defp validate_account(account_id) when is_binary(account_id) and account_id != "", do: :ok
  defp validate_account(_account_id), do: {:error, :invalid_account}

  defp validate_name(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" -> {:error, :name_required}
      String.length(name) > @max_name_length -> {:error, :name_too_long}
      String.match?(name, ~r/[\x00-\x1F\x7F]/u) -> {:error, :invalid_name}
      true -> {:ok, name}
    end
  end

  defp validate_name(_name), do: {:error, :name_required}

  # Write access always comes with read.
  defp validate_scopes(scopes) when is_list(scopes) do
    cond do
      scopes == [] -> {:error, :invalid_scopes}
      Enum.all?(scopes, &(&1 in @scopes)) -> {:ok, Enum.filter(@scopes, &(&1 == "read" or &1 in scopes))}
      true -> {:error, :invalid_scopes}
    end
  end

  defp validate_scopes(_scopes), do: {:error, :invalid_scopes}

  # "*" stands alone; otherwise team keys (upper-cased) and project:<slug>.
  defp validate_resources(resources) when is_list(resources) and resources != [] do
    resources = resources |> Enum.map(&normalize_resource/1) |> Enum.uniq()

    cond do
      "*" in resources -> {:ok, ["*"]}
      length(resources) > @max_resources -> {:error, :invalid_resources}
      Enum.all?(resources, &(Regex.match?(@team_pattern, &1) or Regex.match?(@project_pattern, &1))) -> {:ok, resources}
      true -> {:error, :invalid_resources}
    end
  end

  defp validate_resources(_resources), do: {:error, :invalid_resources}

  defp normalize_resource("project:" <> slug), do: "project:" <> String.trim(slug)
  defp normalize_resource(resource) when is_binary(resource), do: resource |> String.trim() |> String.upcase()
  defp normalize_resource(_resource), do: ""

  defp validate_days(days) when is_integer(days) and days > 0 do
    if days <= max_days(), do: {:ok, days}, else: {:error, :lifetime_too_long}
  end

  defp validate_days(_days), do: {:error, :invalid_lifetime}

  defp check_limit(account_id) do
    if length(list(account_id)) >= @max_per_account, do: {:error, :too_many_tokens}, else: :ok
  end

  @spec max_days() :: pos_integer()
  def max_days, do: Config.settings!().server.mcp.token_max_days

  defp default_path, do: Application.get_env(:symphony_elixir, :mcp_tokens_path, Path.expand("~/.symphony/mcp_tokens.json"))

  defp persist(nil), do: :ok

  defp persist(path) do
    tokens =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {hash, record} -> Map.put(record, :hash, hash) end)
      |> Enum.sort_by(& &1.created_at)

    case SymphonyElixir.StateStore.write(path, Jason.encode!(%{version: 1, tokens: tokens}, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("MCP token save failed path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp load(nil), do: :ok

  defp load(path) do
    with {:ok, body} <- SymphonyElixir.StateStore.read(path),
         {:ok, %{"tokens" => tokens}} when is_list(tokens) <- Jason.decode(body) do
      Enum.each(tokens, &load_record/1)
    else
      {:error, :enoent} -> :ok
      other -> Logger.error("MCP token load failed path=#{path} reason=#{inspect(other, limit: 5)}")
    end
  end

  defp load_record(%{"hash" => hash, "id" => id, "account_id" => account_id} = raw)
       when is_binary(hash) and is_binary(id) and is_binary(account_id) do
    record = %{
      id: id,
      name: raw["name"] || id,
      account_id: account_id,
      scopes: Enum.filter(List.wrap(raw["scopes"]), &(&1 in @scopes)),
      # A record without resources reaches nothing.
      resources: Enum.filter(List.wrap(raw["resources"]), &is_binary/1),
      hint: raw["hint"] || "",
      created_at: raw["created_at"],
      expires_at: raw["expires_at"],
      last_used_at: raw["last_used_at"],
      last_used_ip: raw["last_used_ip"]
    }

    :ets.insert(@table, {hash, record})
  end

  defp load_record(_raw), do: :ok
end
