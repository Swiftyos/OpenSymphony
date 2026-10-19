defmodule SymphonyElixir.UsersCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Auth, PrivateFile, Users}

  @password "correct horse battery"

  defmodule FakeLinear do
    def graphql(query, variables, _opts \\ []) do
      if query =~ "SymphonyMemberByEmail", do: member(String.downcase(variables[:email])), else: {:ok, %{"data" => %{}}}
    end

    defp member("mia@acme.test"), do: users([user("u-1", false, false, [team("PAY")])])
    defp member("gus@acme.test"), do: users([user("u-3", false, true, [team("PAY")])])
    defp member("gone@acme.test"), do: users([Map.put(user("u-4", false, false, []), "active", false)])
    defp member("down@acme.test"), do: {:error, :timeout}
    defp member(_email), do: users([])

    defp users(nodes), do: {:ok, %{"data" => %{"users" => %{"nodes" => nodes}}}}
    defp team(key), do: %{"id" => "team-" <> key, "key" => key, "name" => key}

    defp user(id, admin, guest, teams) do
      %{"id" => id, "name" => id, "admin" => admin, "guest" => guest, "active" => true, "teams" => %{"nodes" => teams}}
    end
  end

  setup do
    Auth.clear_cache()
    Users.reset()
    saved = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)

    on_exit(fn ->
      Auth.clear_cache()
      Users.reset()
      restore_app_env(:linear_client_module, saved)
    end)

    :ok
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "symphony-users-cov-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp ok_check(_email), do: :ok

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp register!(username, email, extra \\ %{}) do
    base = %{"username" => username, "email" => email, "password" => @password, "setup_code" => Users.setup_code()}
    params = Map.merge(base, extra)
    {:ok, account} = Users.register(params, &ok_check/1)
    account
  end

  # Swaps the application's Users server for one with the given options.
  defp isolated_users!(opts) do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Users)

    on_exit(fn ->
      if pid = Process.whereis(Users), do: GenServer.stop(pid)
      Supervisor.restart_child(SymphonyElixir.Supervisor, Users)
    end)

    {:ok, pid} = Users.start_link(opts)
    Process.unlink(pid)
    pid
  end

  describe "Users API" do
    test "start_link refuses a second server under the same name" do
      assert {:error, {:already_started, pid}} = Users.start_link()
      assert pid == Process.whereis(Users)
    end

    test "lookups with missing or invalid input return nothing" do
      assert Users.authenticate(nil, nil) == {:error, :invalid_credentials}
      assert Users.get("usr_missing") == nil
      assert Users.reset_account_for_token(nil) == nil
      assert Users.create_reset_token("usr_missing") == {:error, :not_found}
      assert Users.approve("usr_missing", "ada") == {:error, :not_found}
      assert GenServer.call(Users, {:set_password, "usr_missing", "hash"}) == {:error, :not_found}
    end

    test "a :skip Linear check counts as allowed" do
      params = %{"username" => "solo", "email" => "solo@acme.test", "password" => @password}
      params = Map.put(params, "setup_code", Users.setup_code())
      assert {:ok, %{username: "solo", status: "active"}} = Users.register(params, fn _ -> :skip end)
    end

    test "reject only deletes pending requests; enable reactivates disabled accounts" do
      admin = register!("ada", "ada@acme.test")
      pending = register!("pat", "pat@acme.test")
      active = register!("mia", "mia@acme.test")
      {:ok, _} = Users.approve(active.id, "ada")

      assert Users.reject("usr_missing") == {:error, :not_found}
      assert Users.reject(admin.id) == {:error, :not_pending}
      assert Users.reject(pending.id) == :ok
      assert Users.get(pending.id) == nil

      {:ok, disabled} = Users.disable(active.id, "ada")
      assert disabled.status == "disabled"
      assert {:ok, %{status: "active", approved_by: "ada"}} = Users.enable(active.id, "ada")
    end
  end

  describe "Users storage" do
    test "accounts persist to a private file and load back on restart" do
      dir = tmp_dir!()
      path = Path.join([dir, "state", "users.json"])
      pid = isolated_users!(path: path)

      account = register!("ada", "ada@acme.test", %{"requested_from" => "10.0.0.1"})
      {:ok, token} = Users.create_reset_token(account.id)

      assert {:ok, %{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      saved = path |> File.read!() |> Jason.decode!()
      assert %{"users" => [%{"username" => "ada", "requested_from" => "10.0.0.1"}]} = saved

      GenServer.stop(pid)
      {:ok, pid} = Users.start_link(path: path)
      Process.unlink(pid)

      assert %{username: "ada", status: "active", bootstrap_admin: true} = Users.get(account.id)
      assert Users.reset_account_for_token(token).id == account.id
      assert {:ok, _} = Users.authenticate("ada", @password)
    end

    test "loading fills defaults and skips malformed records" do
      dir = tmp_dir!()
      path = Path.join(dir, "users.json")
      expires = System.system_time(:millisecond) + 60_000

      users = [
        %{
          "id" => "usr_full",
          "username" => "zed",
          "email" => "zed@acme.test",
          "status" => "disabled",
          "bootstrap_admin" => true,
          "session_version" => 3,
          "reset" => %{"hash" => Base.encode64(:crypto.hash(:sha256, "tok")), "expires_ms" => expires}
        },
        %{"id" => "usr_min", "username" => "min", "reset" => "garbage"},
        %{"username" => "no-id"},
        "junk"
      ]

      File.write!(path, Jason.encode!(%{version: 1, users: users}))
      isolated_users!(path: path)

      assert %{status: "disabled", session_version: 3, bootstrap_admin: true} = Users.get("usr_full")
      assert %{status: "pending", session_version: 1, bootstrap_admin: false} = Users.get("usr_min")
      assert Enum.map(Users.list(), & &1.id) |> Enum.sort() == ["usr_full", "usr_min"]
      assert Users.reset_account_for_token("tok").id == "usr_full"
    end

    test "a missing file starts empty and an unreadable one is logged" do
      dir = tmp_dir!()
      pid = isolated_users!(path: Path.join(dir, "missing.json"))
      assert Users.list() == []
      GenServer.stop(pid)

      bad = Path.join(dir, "bad.json")
      File.write!(bad, "{not json")

      log =
        capture_log(fn ->
          {:ok, pid} = Users.start_link(path: bad)
          Process.unlink(pid)
        end)

      assert log =~ "User accounts load failed"
      assert Users.list() == []
    end

    test "save failures are logged and the account still exists in memory" do
      dir = tmp_dir!()
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "not a directory")
      path = Path.join(blocker, "users.json")

      log = capture_log(fn -> isolated_users!(path: path) end)
      assert log =~ "User accounts load failed"

      log = capture_log(fn -> register!("ada", "ada@acme.test") end)
      assert log =~ "User accounts save failed"
      assert [%{username: "ada"}] = Users.list()
    end

    test "the default path is ~/.symphony/users.json when not configured" do
      saved = Application.get_env(:symphony_elixir, :users_path)
      Application.put_env(:symphony_elixir, :users_path, :default)
      on_exit(fn -> restore_app_env(:users_path, saved) end)

      # The explicit path wins, but the default is still computed eagerly.
      path = Path.join(tmp_dir!(), "users.json")
      pid = isolated_users!(path: path)
      assert :sys.get_state(pid).path == path
    end
  end

  describe "PrivateFile" do
    test "write cleans up and returns the error when the directory can't be created" do
      dir = tmp_dir!()
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "x")
      path = Path.join([blocker, "sub", "file.json"])

      assert {:error, _reason} = PrivateFile.write(path, "{}")
      refute File.exists?(path)
      assert Path.wildcard(Path.join(dir, "**/*.tmp-*")) == []
    end

    test "create_once returns open errors other than an existing file" do
      dir = tmp_dir!()
      path = Path.join(dir, String.duplicate("n", 300))
      assert {:error, reason} = PrivateFile.create_once(path, "content")
      assert reason in [:enametoolong, :einval]
    end
  end

  describe "Auth" do
    test "start_link refuses a second server under the same name" do
      assert {:error, {:already_started, _pid}} = Auth.start_link()
    end

    test "mode honours server.auth and treats any 127.x address as loopback" do
      assert Auth.mode(%{server: %{auth: "accounts", host: "127.0.0.1"}}) == :accounts
      assert Auth.mode(%{server: %{auth: "local", host: "0.0.0.0"}}) == :local
      assert Auth.mode(%{server: %{auth: nil, host: "127.0.0.42"}}) == :local
      assert Auth.mode(%{server: %{auth: nil, host: "10.0.0.1"}}) == :accounts
    end

    test "user_for_id reports pending and defaults the session version" do
      admin = register!("ada", "ada@acme.test")
      pending = register!("mia", "mia@acme.test")

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      assert {:ok, %Auth.User{id: id, teams: []}} = Auth.user_for_id(admin.id)
      assert id == admin.id
      assert Auth.user_for_id(pending.id) == {:error, :pending}
    end

    test "user_for_account maps every Linear lookup result" do
      account = fn email -> %{id: "usr_x", username: "x", email: email, bootstrap_admin: false} end

      assert Auth.user_for_account(account.("gone@acme.test")) == {:error, :inactive_user}
      assert Auth.user_for_account(account.("eve@evil.test")) == {:error, :not_in_workspace}

      log =
        capture_log(fn ->
          assert {:ok, %Auth.User{teams: [], admin: false}} = Auth.user_for_account(account.("down@acme.test"))
        end)

      assert log =~ "Linear member lookup failed"
      # The failure is cached briefly, so Linear isn't asked again.
      assert {:ok, %Auth.User{teams: []}} = Auth.user_for_account(account.("down@acme.test"))

      {:ok, guest} = Auth.user_for_account(account.("gus@acme.test"))
      assert guest.guest
      refute Auth.can_move?(guest, "PAY-1")
      assert Auth.movable_teams(guest) == []

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      assert {:ok, %Auth.User{email: "mia@acme.test", teams: []}} = Auth.user_for_account(account.("mia@acme.test"))
    end

    test "check_linear_member rejects non-string emails" do
      assert Auth.check_linear_member(nil) == {:error, :not_in_workspace}
    end

    test "permission helpers cover admins, malformed identifiers and anonymous users" do
      admin = %Auth.User{id: "a", name: "A", admin: true}
      member = %Auth.User{id: "m", name: "M", teams: [%{id: "t", key: "PAY", name: "PAY"}]}

      assert Auth.can_move?(admin, "WEB-1")
      refute Auth.can_move?(member, "PAY")
      refute Auth.can_move?(member, nil)
      refute Auth.can_move?(nil, "PAY-1")
      assert Auth.movable_teams(member) == ["PAY"]
      assert Auth.movable_teams(nil) == []
    end
  end
end
