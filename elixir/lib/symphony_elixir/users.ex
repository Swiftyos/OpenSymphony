defmodule SymphonyElixir.Users do
  @moduledoc """
  Dashboard user accounts, one per email Google IAP verified, tied to the
  Linear user with that email.

  Accounts hold only what Linear can't: access Symphony grants on top of
  Linear, and whether the person has seen the MCP setup. Linear team membership
  and admin rights are read from Linear (see `SymphonyElixir.Auth`); on top of
  that:

    * `team_admin` - teams the person administers in Symphony (set by admins)
    * `access` - extra teams (`PAY`) or projects (`project:<slug>`) the person
      may work in, granted by an admin or one of the team's admins
    * `role` - a global role: `admin`, or `global_viewer` (sees every team,
      changes nothing); `nil` for neither. See `SymphonyElixir.Policy`.

  Lifecycle:

    * an account is created, active, the first time its email arrives through
      IAP (`ensure/1`); the first account on a fresh install is the bootstrap
      admin
    * admins can disable accounts, which signs them out everywhere, and enable
      them again
    * accounts from the password era keep their id, username and grants; a
      `pending` one becomes active on its first IAP visit, since IAP now proves
      the email
    * admins can provision accounts ahead of a first visit
      (`SymphonyElixir.Users.Import`): `imported_at` is set, and the person
      gets the provisioned grants when they first arrive through IAP

  Stored as JSON (mode 0600) in `~/.symphony/users.json`.
  """

  use GenServer
  require Logger

  @table :symphony_users

  @type user :: %{
          id: String.t(),
          username: String.t(),
          email: String.t(),
          status: String.t(),
          bootstrap_admin: boolean(),
          created_at: String.t(),
          approved_by: String.t() | nil,
          last_sign_in_at: String.t() | nil,
          session_version: pos_integer(),
          team_admin: [String.t()],
          access: [String.t()],
          role: String.t() | nil,
          imported_at: String.t() | nil,
          mcp_welcomed_at: String.t() | nil
        }

  @roles ["admin", "global_viewer"]

  @team_pattern ~r/^[A-Z0-9][A-Z0-9_-]{0,15}$/
  @project_pattern ~r/^project:[A-Za-z0-9][A-Za-z0-9_-]{0,95}$/

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The account for an email IAP verified, created (active) on first visit. A
  `pending` account from the password era is activated: IAP proved the email.
  Disabled accounts are returned as they are; `SymphonyElixir.Auth` refuses them.
  """
  @spec ensure(String.t()) :: {:ok, user()} | {:error, atom()}
  def ensure(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    with :ok <- validate_email(email), do: GenServer.call(__MODULE__, {:ensure, email})
  end

  @doc "The account with this email (any case), if there is one."
  @spec get_by_email(String.t() | nil) :: user() | nil
  def get_by_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    if ready?(), do: Enum.find(all_records(), &(&1.email == email)), else: nil
  end

  def get_by_email(_email), do: nil

  @doc """
  Sets the account's global role: `"admin"`, `"global_viewer"`, or `nil` for
  neither. Callers check the person setting it is an admin.
  """
  @spec set_role(String.t(), String.t() | nil, String.t()) :: {:ok, user()} | {:error, atom()}
  def set_role(id, role, by) when is_nil(role) or role in @roles, do: GenServer.call(__MODULE__, {:set_role, id, role, by})
  def set_role(_id, _role, _by), do: {:error, :invalid_role}

  @doc """
  Creates or updates accounts in one write, for `SymphonyElixir.Users.Import`.
  Each entry is `{email, %{role: role | :keep, team_admin: [team], access:
  [scope]}}`, the account's complete lists after the change. New accounts are
  active and marked `imported_at`; existing ones keep their status, id and
  everything else.
  """
  @spec provision([{String.t(), map()}], String.t()) :: {:ok, [user()]} | {:error, atom()}
  def provision(entries, by) when is_list(entries), do: GenServer.call(__MODULE__, {:provision, entries, by})

  @doc """
  Records that the person has seen the MCP setup, so it doesn't open again.
  """
  @spec mark_mcp_welcomed(String.t()) :: {:ok, user()} | {:error, atom()}
  def mark_mcp_welcomed(id) when is_binary(id), do: GenServer.call(__MODULE__, {:mark_mcp_welcomed, id})

  @doc """
  Makes the account an admin of a team (`true`) or removes that (`false`).
  """
  @spec set_team_admin(String.t(), String.t(), boolean(), String.t()) :: {:ok, user()} | {:error, atom()}
  def set_team_admin(id, team, admin?, by) do
    with {:ok, team} <- scope_key(team, :team), do: GenServer.call(__MODULE__, {:set_list, id, :team_admin, team, admin?, by})
  end

  @doc """
  Grants (`true`) or revokes (`false`) access to a team (`PAY`) or a project
  (`project:<slug>`). Callers check the granter may do this (`Policy.can?(user, {:grant, scope})`).
  """
  @spec set_access(String.t(), String.t(), boolean(), String.t()) :: {:ok, user()} | {:error, atom()}
  def set_access(id, scope, granted?, by) do
    with {:ok, scope} <- scope_key(scope, :any), do: GenServer.call(__MODULE__, {:set_list, id, :access, scope, granted?, by})
  end

  defp scope_key(scope, kind) when is_binary(scope) do
    scope = String.trim(scope)
    team = String.upcase(scope)

    cond do
      Regex.match?(@team_pattern, team) -> {:ok, team}
      kind == :any and Regex.match?(@project_pattern, scope) -> {:ok, scope}
      true -> {:error, :invalid_scope}
    end
  end

  defp scope_key(_scope, _kind), do: {:error, :invalid_scope}

  @doc """
  Whether the accounts store is up and its document readable from the state
  store (Postgres in a cluster), for the controller's readiness probe.
  """
  @spec readable?() :: boolean()
  def readable? do
    path = GenServer.call(__MODULE__, :path)

    case if(path, do: SymphonyElixir.StateStore.read(path), else: {:ok, ""}) do
      {:ok, _body} -> true
      {:error, :enoent} -> true
      {:error, _reason} -> false
    end
  catch
    :exit, _reason -> false
  end

  @spec get(String.t() | nil) :: user() | nil
  def get(id) when is_binary(id) do
    case lookup(id) do
      nil -> nil
      record -> public(record)
    end
  end

  def get(_id), do: nil

  @spec list(String.t() | nil) :: [user()]
  def list(status \\ nil) do
    if ready?() do
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, record} -> public(record) end)
      |> Enum.filter(&(is_nil(status) or &1.status == status))
      |> Enum.sort_by(& &1.created_at)
    else
      []
    end
  end

  @spec disable(String.t(), String.t()) :: {:ok, user()} | {:error, atom()}
  def disable(id, by), do: GenServer.call(__MODULE__, {:set_status, id, "disabled", by})

  @spec enable(String.t(), String.t()) :: {:ok, user()} | {:error, atom()}
  def enable(id, by), do: GenServer.call(__MODULE__, {:set_status, id, "active", by})

  @spec any?() :: boolean()
  def any?, do: ready?() and :ets.info(@table, :size) > 0

  @doc false
  @spec reset() :: :ok
  def reset do
    if ready?(), do: GenServer.call(__MODULE__, :reset)
    :ok
  end

  # ------------------------------------------------------------------ server

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    load(path)
    {:ok, %{path: path}}
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call({:ensure, email}, _from, state) do
    records = all_records()

    case Enum.find(records, &(&1.email == email)) do
      %{status: "pending"} = record ->
        record = %{record | status: "active", approved_by: "iap", last_sign_in_at: now()}
        :ets.insert(@table, {record.id, record})
        persist(state.path)
        Logger.info("Account activated through IAP user=#{record.username}")
        {:reply, {:ok, public(record)}, state}

      %{status: "active"} = record ->
        # Every request passes through here; the visit time is saved at most hourly.
        record = if stale_visit?(record.last_sign_in_at), do: save_visit(record, state.path), else: record
        {:reply, {:ok, public(record)}, state}

      %{} = record ->
        {:reply, {:ok, public(record)}, state}

      nil ->
        first? = records == []

        record = %{
          id: "usr_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
          username: unique_username(email, records),
          email: email,
          status: "active",
          bootstrap_admin: first?,
          created_at: now(),
          approved_by: if(first?, do: "bootstrap", else: "iap"),
          last_sign_in_at: now(),
          session_version: 1,
          team_admin: [],
          access: [],
          role: nil,
          imported_at: nil,
          mcp_welcomed_at: nil
        }

        :ets.insert(@table, {record.id, record})
        persist(state.path)
        Logger.info("Account created through IAP user=#{record.username} bootstrap_admin=#{first?}")
        {:reply, {:ok, public(record)}, state}
    end
  end

  def handle_call({:mark_mcp_welcomed, id}, _from, state) do
    case lookup(id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      record ->
        record = %{record | mcp_welcomed_at: record.mcp_welcomed_at || now()}
        :ets.insert(@table, {id, record})
        persist(state.path)
        {:reply, {:ok, public(record)}, state}
    end
  end

  def handle_call({:set_status, id, status, by}, _from, state) do
    case lookup(id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{bootstrap_admin: true} when status == "disabled" ->
        # The bootstrap account is the one admin Symphony itself guarantees.
        {:reply, {:error, :cannot_disable_bootstrap}, state}

      record ->
        record = %{
          record
          | status: status,
            approved_by: if(status == "active", do: record.approved_by || by, else: record.approved_by),
            # Disabling signs the account out everywhere.
            session_version: if(status == "disabled", do: record.session_version + 1, else: record.session_version)
        }

        :ets.insert(@table, {id, record})
        persist(state.path)
        {:reply, {:ok, public(record)}, state}
    end
  end

  def handle_call({:set_list, id, field, value, add?, by}, _from, state) do
    case lookup(id) do
      %{status: "active"} = record ->
        current = Map.get(record, field, [])
        updated = if add?, do: Enum.sort(Enum.uniq([value | current])), else: List.delete(current, value)
        record = Map.put(record, field, updated)
        :ets.insert(@table, {id, record})
        persist(state.path)
        Logger.info("Account #{field} #{if add?, do: "granted", else: "revoked"} user=#{record.username} scope=#{value} by=#{by}")
        {:reply, {:ok, public(record)}, state}

      nil ->
        {:reply, {:error, :not_found}, state}

      _inactive ->
        {:reply, {:error, :not_active}, state}
    end
  end

  def handle_call({:set_role, id, role, by}, _from, state) do
    case lookup(id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      record ->
        record = %{record | role: role}
        :ets.insert(@table, {id, record})
        persist(state.path)
        Logger.info("Account role set user=#{record.username} role=#{role || "none"} by=#{by}")
        {:reply, {:ok, public(record)}, state}
    end
  end

  def handle_call({:provision, entries, by}, _from, state) do
    records = Enum.reduce(entries, all_records(), &provision_entry(&1, &2, by))
    by_email = Map.new(records, &{&1.email, &1})
    persist(state.path)
    {:reply, {:ok, for({email, _attrs} <- entries, do: public(by_email[email]))}, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp provision_entry({email, attrs}, records, by) do
    record =
      case Enum.find(records, &(&1.email == email)) do
        nil ->
          %{
            id: "usr_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
            username: unique_username(email, records),
            email: email,
            status: "active",
            bootstrap_admin: false,
            created_at: now(),
            approved_by: by,
            last_sign_in_at: nil,
            session_version: 1,
            team_admin: [],
            access: [],
            role: nil,
            imported_at: now(),
            mcp_welcomed_at: nil
          }

        existing ->
          existing
      end

    role = if Map.get(attrs, :role, :keep) == :keep, do: record.role, else: attrs.role

    record = %{
      record
      | team_admin: attrs |> Map.get(:team_admin, record.team_admin) |> load_scopes(:team) |> Enum.sort(),
        access: attrs |> Map.get(:access, record.access) |> load_scopes(:any) |> Enum.sort(),
        role: role
    }

    :ets.insert(@table, {record.id, record})
    [record | Enum.reject(records, &(&1.id == record.id))]
  end

  defp stale_visit?(at) do
    case DateTime.from_iso8601(at || "") do
      {:ok, at, _offset} -> DateTime.diff(DateTime.utc_now(), at) >= 3_600
      _ -> true
    end
  end

  defp save_visit(record, path) do
    record = %{record | last_sign_in_at: now()}
    :ets.insert(@table, {record.id, record})
    persist(path)
    record
  end

  # ------------------------------------------------------------------ validation

  defp validate_email(email) do
    if Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, email), do: :ok, else: {:error, :invalid_email}
  end

  # The email's local part, made to fit the username rules (3-32 of a-z 0-9 . _ -),
  # with a number added when someone already has it.
  defp unique_username(email, records) do
    base =
      email
      |> String.split("@")
      |> hd()
      |> String.replace(~r/[^a-z0-9._-]/, "")
      |> String.trim_leading(".")
      |> String.slice(0, 28)
      |> then(&if(String.length(&1) < 3, do: "user" <> &1, else: &1))

    taken = MapSet.new(records, & &1.username)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&if(&1 == 1, do: base, else: base <> Integer.to_string(&1)))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  # ------------------------------------------------------------------ storage

  defp ready?, do: :ets.whereis(@table) != :undefined

  defp lookup(id) do
    with true <- ready?(),
         [{^id, record}] <- :ets.lookup(@table, id) do
      record
    else
      _ -> nil
    end
  end

  defp all_records, do: @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

  defp public(record), do: record

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp default_path do
    case Application.get_env(:symphony_elixir, :users_path, :default) do
      :default -> Path.expand("~/.symphony/users.json")
      path -> path
    end
  end

  defp persist(nil), do: :ok

  defp persist(path) do
    body = Jason.encode!(%{version: 1, users: all_records()}, pretty: true)

    case SymphonyElixir.StateStore.write(path, body) do
      :ok -> :ok
      {:error, reason} -> Logger.error("User accounts save failed path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp load(nil), do: :ok

  defp load(path) do
    with {:ok, body} <- SymphonyElixir.StateStore.read(path),
         {:ok, %{"users" => users}} <- Jason.decode(body) do
      Enum.each(users, &load_record/1)
    else
      {:error, :enoent} -> :ok
      other -> Logger.error("User accounts load failed path=#{path} reason=#{inspect(other, limit: 5)}")
    end
  end

  defp load_record(%{"id" => id} = raw) when is_binary(id) do
    record = %{
      id: id,
      username: raw["username"],
      email: raw["email"] && String.downcase(raw["email"]),
      # Password-era fields (password_hash, reset, requested_from) are dropped on the next save.
      status: raw["status"] || "pending",
      bootstrap_admin: raw["bootstrap_admin"] == true,
      created_at: raw["created_at"],
      approved_by: raw["approved_by"],
      last_sign_in_at: raw["last_sign_in_at"],
      session_version: raw["session_version"] || 1,
      team_admin: load_scopes(raw["team_admin"], :team),
      access: load_scopes(raw["access"], :any),
      role: if(raw["role"] in @roles, do: raw["role"]),
      imported_at: raw["imported_at"],
      mcp_welcomed_at: raw["mcp_welcomed_at"]
    }

    :ets.insert(@table, {id, record})
  end

  defp load_record(_raw), do: :ok

  defp load_scopes(scopes, kind) when is_list(scopes) do
    for scope <- scopes, {:ok, key} <- [scope_key(scope, kind)], uniq: true, do: key
  end

  defp load_scopes(_scopes, _kind), do: []
end
