defmodule SymphonyElixir.Users do
  @moduledoc """
  Dashboard user accounts: username + password, tied to a Linear user by email.

  Accounts hold only what Linear can't: a username and a password hash. Teams and
  admin rights are always read from Linear (see `SymphonyElixir.Auth`).

  Lifecycle:

    * the first account on a fresh install is active and is the bootstrap admin
    * later sign-ups must use the email of an active member of the Linear
      workspace, and wait as `pending` until an admin approves them
    * admins can reject (delete) pending accounts or disable active ones

  Passwords are hashed with PBKDF2-HMAC-SHA256 (OTP `:crypto`), per-user salt.
  Five failed sign-ins lock an account for 15 minutes.

  Stored as JSON (mode 0600) in `~/.symphony/users.json`.
  """

  use GenServer
  require Logger

  @table :symphony_users
  @hash_scheme "pbkdf2-sha256"
  @default_iterations 600_000
  @min_password_length 12
  @max_failures 5
  @lockout_ms 15 * 60_000

  @type user :: %{
          id: String.t(),
          username: String.t(),
          email: String.t(),
          status: String.t(),
          bootstrap_admin: boolean(),
          created_at: String.t(),
          approved_by: String.t() | nil,
          last_sign_in_at: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Creates an account. `linear_check` decides whether the email belongs to an
  active Linear workspace member (`:ok`, `{:error, reason}`, or `:skip` when no
  Linear tracker is configured).
  """
  @spec register(map(), (String.t() -> :ok | :skip | {:error, atom()})) :: {:ok, user()} | {:error, atom()}
  def register(params, linear_check) when is_map(params) and is_function(linear_check, 1) do
    username = params |> Map.get("username", "") |> to_string() |> String.trim() |> String.downcase()
    email = params |> Map.get("email", "") |> to_string() |> String.trim() |> String.downcase()
    password = params |> Map.get("password", "") |> to_string()
    confirmation = params |> Map.get("password_confirmation", password) |> to_string()

    with :ok <- validate_username(username),
         :ok <- validate_email(email),
         :ok <- validate_password(password, confirmation),
         :ok <- linear_check.(email) |> skip_ok() do
      GenServer.call(__MODULE__, {:register, username, email, hash_password(password)})
    end
  end

  @spec authenticate(String.t(), String.t()) :: {:ok, user()} | {:error, atom()}
  def authenticate(login, password) when is_binary(login) and is_binary(password) do
    login = login |> String.trim() |> String.downcase()

    case find_record(login) do
      nil ->
        # Burn the same time as a real check so usernames can't be probed by timing.
        _ = verify_password(password, dummy_hash())
        {:error, :invalid_credentials}

      record ->
        # Hash outside the GenServer so concurrent sign-ins don't queue on PBKDF2.
        with :ok <- GenServer.call(__MODULE__, {:check_lock, record.id}) do
          GenServer.call(__MODULE__, {:record_attempt, record.id, verify_password(password, record.password_hash)})
        end
    end
  end

  def authenticate(_login, _password), do: {:error, :invalid_credentials}

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

  @spec approve(String.t(), String.t()) :: {:ok, user()} | {:error, atom()}
  def approve(id, approved_by), do: GenServer.call(__MODULE__, {:set_status, id, "active", approved_by})

  @spec disable(String.t(), String.t()) :: {:ok, user()} | {:error, atom()}
  def disable(id, by), do: GenServer.call(__MODULE__, {:set_status, id, "disabled", by})

  @spec reject(String.t()) :: :ok | {:error, atom()}
  def reject(id), do: GenServer.call(__MODULE__, {:reject, id})

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
    {:ok, %{path: path, failures: %{}}}
  end

  @impl true
  def handle_call({:register, username, email, password_hash}, _from, state) do
    records = all_records()

    cond do
      Enum.any?(records, &(&1.username == username)) ->
        {:reply, {:error, :username_taken}, state}

      Enum.any?(records, &(&1.email == email)) ->
        {:reply, {:error, :email_taken}, state}

      true ->
        first? = records == []

        record = %{
          id: "usr_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
          username: username,
          email: email,
          password_hash: password_hash,
          status: if(first?, do: "active", else: "pending"),
          bootstrap_admin: first?,
          created_at: now(),
          approved_by: if(first?, do: "bootstrap", else: nil),
          last_sign_in_at: nil
        }

        :ets.insert(@table, {record.id, record})
        persist(state.path)
        {:reply, {:ok, public(record)}, state}
    end
  end

  def handle_call({:check_lock, id}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)

    case Map.get(state.failures, id) do
      {count, since} when count >= @max_failures and now_ms - since < @lockout_ms -> {:reply, {:error, :locked}, state}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:record_attempt, id, password_ok?}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    {count, since} = Map.get(state.failures, id, {0, now_ms})
    record = lookup(id)

    cond do
      is_nil(record) or not password_ok? ->
        count = if now_ms - since >= @lockout_ms, do: 1, else: count + 1
        {:reply, {:error, :invalid_credentials}, %{state | failures: Map.put(state.failures, id, {count, now_ms})}}

      record.status == "pending" ->
        {:reply, {:error, :pending}, state}

      record.status != "active" ->
        {:reply, {:error, :disabled}, state}

      true ->
        record = %{record | last_sign_in_at: now()}
        :ets.insert(@table, {id, record})
        persist(state.path)
        {:reply, {:ok, public(record)}, %{state | failures: Map.delete(state.failures, id)}}
    end
  end

  def handle_call({:set_status, id, status, by}, _from, state) do
    case lookup(id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      record ->
        record = %{record | status: status, approved_by: if(status == "active", do: by, else: record.approved_by)}
        :ets.insert(@table, {id, record})
        persist(state.path)
        {:reply, {:ok, public(record)}, state}
    end
  end

  def handle_call({:reject, id}, _from, state) do
    case lookup(id) do
      %{status: "pending"} ->
        :ets.delete(@table, id)
        persist(state.path)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :not_found}, state}

      _active ->
        {:reply, {:error, :not_pending}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | failures: %{}}}
  end

  # ------------------------------------------------------------------ validation

  defp validate_username(username) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9._-]{2,31}$/, username), do: :ok, else: {:error, :invalid_username}
  end

  defp validate_email(email) do
    if Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, email), do: :ok, else: {:error, :invalid_email}
  end

  defp validate_password(password, confirmation) do
    cond do
      String.length(password) < @min_password_length -> {:error, :password_too_short}
      password != confirmation -> {:error, :password_mismatch}
      true -> :ok
    end
  end

  defp skip_ok(:skip), do: :ok
  defp skip_ok(other), do: other

  # ------------------------------------------------------------------ passwords

  defp hash_password(password) do
    iterations = iterations()
    salt = :crypto.strong_rand_bytes(16)
    hash = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)
    Enum.join([@hash_scheme, iterations, Base.encode64(salt), Base.encode64(hash)], "$")
  end

  defp verify_password(password, encoded) do
    with [@hash_scheme, iterations, salt, hash] <- String.split(encoded, "$"),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.decode64(salt),
         {:ok, expected} <- Base.decode64(hash) do
      :crypto.hash_equals(:crypto.pbkdf2_hmac(:sha256, password, salt, iterations, byte_size(expected)), expected)
    else
      _ -> false
    end
  end

  defp dummy_hash do
    Enum.join([@hash_scheme, iterations(), Base.encode64(<<0::128>>), Base.encode64(<<0::256>>)], "$")
  end

  defp iterations, do: Application.get_env(:symphony_elixir, :password_iterations, @default_iterations)

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

  defp find_record(login) do
    if ready?(), do: Enum.find(all_records(), &(&1.username == login or &1.email == login))
  end

  defp public(record), do: Map.delete(record, :password_hash)

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
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> Logger.error("User accounts save failed path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp load(nil), do: :ok

  defp load(path) do
    with {:ok, body} <- File.read(path),
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
      email: raw["email"],
      password_hash: raw["password_hash"],
      status: raw["status"] || "pending",
      bootstrap_admin: raw["bootstrap_admin"] == true,
      created_at: raw["created_at"],
      approved_by: raw["approved_by"],
      last_sign_in_at: raw["last_sign_in_at"]
    }

    :ets.insert(@table, {id, record})
  end

  defp load_record(_raw), do: :ok
end
