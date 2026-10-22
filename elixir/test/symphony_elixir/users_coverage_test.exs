defmodule SymphonyElixir.UsersCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Auth, Policy, PrivateFile, Users}

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

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp restore_fetched_env(key, {:ok, value}), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_fetched_env(key, :error), do: Application.delete_env(:symphony_elixir, key)

  defp account!(email) do
    {:ok, account} = Users.ensure(email)
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
      assert Users.get("usr_missing") == nil
      assert Users.get(nil) == nil
      assert Users.mark_mcp_welcomed("usr_missing") == {:error, :not_found}
      assert Users.disable("usr_missing", "ada") == {:error, :not_found}
    end

    test "ensure finds an email case-insensitively and leaves disabled accounts disabled" do
      admin = account!("ada@acme.test")
      assert {:ok, %{id: id}} = Users.ensure("  ADA@acme.test ")
      assert id == admin.id

      active = account!("mia@acme.test")
      {:ok, disabled} = Users.disable(active.id, "ada")
      assert disabled.status == "disabled"
      assert {:ok, %{status: "disabled"}} = Users.ensure("mia@acme.test")
      assert {:ok, %{status: "active", approved_by: "iap"}} = Users.enable(active.id, "ada")
    end

    test "the MCP welcome is recorded once" do
      account = account!("ada@acme.test")
      assert account.mcp_welcomed_at == nil
      assert {:ok, %{mcp_welcomed_at: at}} = Users.mark_mcp_welcomed(account.id)
      assert is_binary(at)
      assert {:ok, %{mcp_welcomed_at: ^at}} = Users.mark_mcp_welcomed(account.id)
    end
  end

  describe "team admins and access" do
    test "admin and access lists are validated, deduplicated, and only for active accounts" do
      admin = account!("ada@acme.test")
      disabled = account!("pat@acme.test")
      {:ok, _} = Users.disable(disabled.id, "ada")

      assert {:ok, %{team_admin: ["PAY"]}} = Users.set_team_admin(admin.id, " pay ", true, "ada")
      assert {:ok, %{team_admin: ["PAY"]}} = Users.set_team_admin(admin.id, "PAY", true, "ada")
      assert {:ok, %{access: ["project:Checkout"]}} = Users.set_access(admin.id, "project:Checkout", true, "ada")
      assert {:ok, %{access: ["WEB", "project:Checkout"]}} = Users.set_access(admin.id, "web", true, "ada")
      assert {:ok, %{access: ["WEB"]}} = Users.set_access(admin.id, "project:Checkout", false, "ada")
      assert {:ok, %{team_admin: []}} = Users.set_team_admin(admin.id, "PAY", false, "ada")

      assert Users.set_team_admin(admin.id, "project:x", true, "ada") == {:error, :invalid_scope}
      assert Users.set_access(admin.id, "project:bad slug", true, "ada") == {:error, :invalid_scope}
      assert Users.set_access(admin.id, nil, true, "ada") == {:error, :invalid_scope}
      assert Users.set_access("usr_missing", "PAY", true, "ada") == {:error, :not_found}
      assert Users.set_access(disabled.id, "PAY", true, "ada") == {:error, :not_active}
    end
  end

  describe "Users storage" do
    test "accounts persist to a private file and load back on restart" do
      dir = tmp_dir!()
      path = Path.join([dir, "state", "users.json"])
      pid = isolated_users!(path: path)

      account = account!("ada@acme.test")
      {:ok, _} = Users.mark_mcp_welcomed(account.id)
      {:ok, _} = Users.set_team_admin(account.id, "PAY", true, "ada")
      {:ok, _} = Users.set_access(account.id, "project:web", true, "ada")

      assert {:ok, %{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      saved = path |> File.read!() |> Jason.decode!()
      assert %{"users" => [%{"username" => "ada", "email" => "ada@acme.test"}]} = saved

      GenServer.stop(pid)
      {:ok, pid} = Users.start_link(path: path)
      Process.unlink(pid)

      assert %{username: "ada", status: "active", bootstrap_admin: true, team_admin: ["PAY"], access: ["project:web"], mcp_welcomed_at: at} = Users.get(account.id)
      assert is_binary(at)

      # Global roles and provisioned accounts survive a restart too.
      {:ok, _} = Users.set_role(account.id, "global_viewer", "ada")
      assert {:error, :invalid_role} = Users.set_role(account.id, "owner", "ada")
      {:ok, [_]} = Users.provision([{"bo@acme.test", %{role: :keep, team_admin: ["web"], access: ["PAY", "bad team!"]}}], "import")
      GenServer.stop(pid)
      {:ok, pid} = Users.start_link(path: path)
      Process.unlink(pid)

      assert %{role: "global_viewer"} = Users.get(account.id)
      bo = Users.get_by_email("BO@acme.test")
      assert %{role: nil, team_admin: ["WEB"], access: ["PAY"], status: "active", bootstrap_admin: false} = bo
      imported = bo.imported_at
      assert is_binary(imported)
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
          "team_admin" => ["pay", "bad team!", "PAY"],
          "access" => ["project:ok", "nope nope", "web"],
          # Password-era fields are ignored and dropped on the next save.
          "password_hash" => "pbkdf2-sha256$1$c2FsdA==$aGFzaA==",
          "reset" => %{"hash" => Base.encode64(:crypto.hash(:sha256, "tok")), "expires_ms" => expires}
        },
        %{"id" => "usr_min", "username" => "min", "email" => "Min@Acme.test", "reset" => "garbage"},
        %{"username" => "no-id"},
        "junk"
      ]

      File.write!(path, Jason.encode!(%{version: 1, users: users}))
      isolated_users!(path: path)

      assert %{status: "disabled", session_version: 3, bootstrap_admin: true, team_admin: ["PAY"], access: ["project:ok", "WEB"]} = Users.get("usr_full")
      assert %{status: "pending", session_version: 1, bootstrap_admin: false, team_admin: [], access: []} = Users.get("usr_min")
      assert Enum.map(Users.list(), & &1.id) |> Enum.sort() == ["usr_full", "usr_min"]
      refute Map.has_key?(Users.get("usr_full"), :password_hash)

      # A pending password-era request becomes active on its first IAP visit, keeping its id.
      assert {:ok, %{id: "usr_min", status: "active", approved_by: "iap"}} = Users.ensure("min@acme.test")
      refute File.read!(path) =~ "password_hash"
      refute File.read!(path) =~ "reset"
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

      log = capture_log(fn -> account!("ada@acme.test") end)
      assert log =~ "User accounts save failed"
      assert [%{username: "ada"}] = Users.list()
    end

    test "the default path is ~/.symphony/users.json when not configured" do
      # config/test.exs sets users_path: nil; deleting the key instead would make the
      # app's Users server fall back to the real ~/.symphony/users.json.
      saved = Application.fetch_env(:symphony_elixir, :users_path)
      path = Path.join(tmp_dir!(), "users.json")
      Application.put_env(:symphony_elixir, :users_path, :default)

      # The explicit path wins, but the default is still computed eagerly.
      pid = isolated_users!(path: path)
      # Registered after isolated_users!/1 so it runs first: the app's Users server
      # must restart with the test config, never with the real ~/.symphony path.
      on_exit(fn -> restore_fetched_env(:users_path, saved) end)
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
      assert Auth.mode(%{server: %{auth: "accounts", host: "127.0.0.1"}}) == :iap
      assert Auth.mode(%{server: %{auth: "local", host: "0.0.0.0"}}) == :local
      assert Auth.mode(%{server: %{auth: nil, host: "127.0.0.42"}}) == :local
      assert Auth.mode(%{server: %{auth: nil, host: "10.0.0.1"}}) == :iap
    end

    test "user_for_id reports disabled accounts and defaults the session version" do
      admin = account!("ada@acme.test")
      mia = account!("mia@acme.test")
      {:ok, _} = Users.disable(mia.id, "ada")

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      assert {:ok, %Auth.User{id: id, teams: []}} = Auth.user_for_id(admin.id)
      assert id == admin.id
      assert Auth.user_for_id(mia.id) == {:error, :disabled}
      assert Auth.user_for_id(nil) == {:error, :signed_out}
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
      refute Policy.can?(guest, {:move_issue, "PAY-1", nil})
      assert Policy.movable_teams(guest) == []

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      assert {:ok, %Auth.User{email: "mia@acme.test", teams: []}} = Auth.user_for_account(account.("mia@acme.test"))
    end

    test "user_for_email lets people in with Symphony's grants while Linear is unreachable" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: "server-key")

      capture_log(fn ->
        assert {:ok, %Auth.User{email: "down@acme.test", teams: []}} = Auth.user_for_email("down@acme.test")
      end)
    end

    test "dev_user only applies while no IAP audience is configured" do
      saved = System.get_env("SYMPHONY_DEV_USER")
      on_exit(fn -> restore_env("SYMPHONY_DEV_USER", saved) end)
      System.put_env("SYMPHONY_DEV_USER", " Dev@Acme.test ")

      write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0", server_iap_audiences: [])
      assert Auth.dev_user() == "dev@acme.test"

      write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0")
      assert Auth.dev_user() == nil
    end

    test "permission helpers cover admins, malformed identifiers and anonymous users" do
      admin = %Auth.User{id: "a", name: "A", admin: true}
      member = %Auth.User{id: "m", name: "M", teams: [%{id: "t", key: "PAY", name: "PAY"}]}

      assert Policy.can?(admin, {:move_issue, "WEB-1", nil})
      refute Policy.can?(member, {:move_issue, "PAY", nil})
      refute Policy.can?(member, {:move_issue, nil, nil})
      refute Policy.can?(nil, {:move_issue, "PAY-1", nil})
      assert Policy.movable_teams(member) == ["PAY"]
      assert Policy.movable_teams(nil) == []
    end
  end
end
