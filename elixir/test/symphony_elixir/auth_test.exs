defmodule SymphonyElixir.AuthTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Auth, FactoryControls, UsageLedger, Users}
  alias SymphonyElixirWeb.RateLimit

  @endpoint SymphonyElixirWeb.Endpoint
  @password "correct horse battery"

  defmodule FakeLinear do
    @org %{"id" => "org-1", "urlKey" => "acme", "name" => "Acme"}

    def graphql(query, variables, _opts \\ []) do
      cond do
        query =~ "SymphonyMemberByEmail" -> member(variables[:email] |> String.downcase())
        query =~ "SymphonyStageLookup" -> notify({:stage_lookup, variables}) && stage_lookup()
        query =~ "SymphonySetStage" -> notify({:set_stage, variables}) && ok(%{"issueUpdate" => %{"success" => true}})
        query =~ "SymphonyCreateComment" -> notify({:comment, variables}) && ok(%{"commentCreate" => %{"success" => true}})
        query =~ "SymphonyOrganization" -> ok(%{"organization" => @org})
      end
    end

    def fetch_issue_states_by_ids(ids) do
      issues =
        for id <- ids, issue = known_issue(id), issue != nil, do: issue

      {:ok, issues}
    end

    defp known_issue("id-PAY-1"),
      do: %SymphonyElixir.Linear.Issue{
        id: "id-PAY-1",
        identifier: "PAY-1",
        title: "Refunds",
        state: "In Review",
        labels: [],
        project_slug: "project",
        url: "https://linear.app/acme/issue/PAY-1"
      }

    defp known_issue("id-WEB-1"),
      do: %SymphonyElixir.Linear.Issue{id: "id-WEB-1", identifier: "WEB-1", title: "Cart", state: "In Review", labels: [], project_slug: "project"}

    defp known_issue(_id), do: nil

    defp member("mia@acme.test"), do: users([user("u-1", "Mia Member", false, [team("PAY")])])
    defp member("ada@acme.test"), do: users([user("u-2", "Ada Admin", true, [])])
    defp member("gone@acme.test"), do: users([Map.put(user("u-4", "Gone", false, []), "active", false)])
    defp member(_email), do: users([])

    defp stage_lookup do
      ok(%{
        "issue" => %{
          "team" => %{"id" => "team-PAY", "states" => %{"nodes" => [%{"id" => "state-ip"}]}},
          "labels" => %{"nodes" => []}
        },
        "issueLabels" => %{"nodes" => [%{"id" => "lbl-merge", "team" => %{"id" => "team-PAY"}}]}
      })
    end

    defp notify(message) do
      case Application.get_env(:symphony_elixir, :fake_linear_recipient) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end

      true
    end

    defp ok(data), do: {:ok, %{"data" => data}}
    defp users(nodes), do: ok(%{"users" => %{"nodes" => nodes}})
    defp team(key), do: %{"id" => "team-" <> key, "key" => key, "name" => key <> " team"}

    defp user(id, name, admin, teams) do
      %{
        "id" => id,
        "name" => name,
        "displayName" => name,
        "admin" => admin,
        "guest" => false,
        "active" => true,
        "teams" => %{"nodes" => teams}
      }
    end
  end

  defmodule StubOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      totals = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      {:reply, %{running: [], retrying: [], agent_totals: totals, rate_limits: nil}, state}
    end

    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true}, state}
  end

  setup do
    Auth.clear_cache()
    Users.reset()
    RateLimit.reset()
    FactoryControls.reset()
    UsageLedger.reset()
    saved = Map.new([:linear_client_module, :fake_linear_recipient], &{&1, Application.get_env(:symphony_elixir, &1)})
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)
    Application.put_env(:symphony_elixir, :fake_linear_recipient, self())

    on_exit(fn ->
      Auth.clear_cache()
      Users.reset()
      FactoryControls.reset()
      UsageLedger.reset()

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  defp accounts_mode!(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge([server_host: "0.0.0.0", tracker_kind: "linear", tracker_api_token: "server-key"], overrides)
    )
  end

  defp register!(username, email) do
    Users.register(
      %{
        "username" => username,
        "email" => email,
        "password" => @password,
        "password_confirmation" => @password,
        # Only consulted (and only non-nil) while no accounts exist.
        "setup_code" => Users.setup_code()
      },
      &Auth.check_linear_member/1
    )
  end

  defp start_endpoint! do
    name = Module.concat(__MODULE__, :Orchestrator)
    {:ok, _pid} = StubOrchestrator.start_link(name: name)

    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: name, snapshot_timeout_ms: 200)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp session_for(account) do
    build_conn() |> Plug.Test.init_test_session(%{"user_id" => account.id, "session_version" => Users.get(account.id).session_version})
  end

  test "mode is local on loopback and accounts everywhere else" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Auth.mode() == :local

    accounts_mode!()
    assert Auth.mode() == :accounts
  end

  test "the first account is the admin; later sign-ups need a Linear email and approval" do
    accounts_mode!()

    assert {:ok, %{status: "active", bootstrap_admin: true}} = register!("mia", "mia@acme.test")
    assert {:ok, %{status: "pending", bootstrap_admin: false} = ada} = register!("ada", "Ada@Acme.test")

    assert {:error, :not_in_workspace} = register!("eve", "eve@evil.test")
    assert {:error, :inactive_user} = register!("gone", "gone@acme.test")
    # Uniqueness is checked after the Linear gate, so use an always-ok gate here.
    any_member = fn _email -> :ok end
    params = fn username, email -> %{"username" => username, "email" => email, "password" => @password} end
    assert {:error, :username_taken} = Users.register(params.("mia", "other@acme.test"), any_member)
    assert {:error, :email_taken} = Users.register(params.("ada2", "ada@acme.test"), any_member)

    assert {:error, :password_too_short} =
             Users.register(%{"username" => "bob", "email" => "bob@acme.test", "password" => "short"}, fn _ -> :ok end)

    assert {:error, :password_mismatch} =
             Users.register(
               %{"username" => "bob", "email" => "bob@acme.test", "password" => @password, "password_confirmation" => "nope nope nope"},
               fn _ -> :ok end
             )

    assert {:error, :pending} = Auth.sign_in("ada", @password)
    assert {:ok, _} = Users.approve(ada.id, "mia")
    assert {:ok, %Auth.User{name: "Ada Admin", admin: true}} = Auth.sign_in("ada@acme.test", @password)
  end

  test "passwords are checked, hashed, and repeated failures lock the account" do
    accounts_mode!()
    {:ok, _} = register!("mia", "mia@acme.test")

    refute File.exists?("users.json")
    assert {:error, :invalid_credentials} = Auth.sign_in("nobody", @password)

    for _ <- 1..5, do: assert({:error, :invalid_credentials} = Auth.sign_in("mia", "wrong password!!"))
    assert {:error, :locked} = Auth.sign_in("mia", @password)
  end

  test "permissions come from the Linear user with the account's email" do
    accounts_mode!()
    {:ok, mia} = register!("mia", "mia@acme.test")
    {:ok, ada} = register!("ada", "ada@acme.test")
    {:ok, ada} = Users.approve(ada.id, "mia")

    # Mia is the bootstrap admin even though Linear says she is a regular member.
    {:ok, mia_user} = Auth.user_for_account(mia)
    assert mia_user.admin
    assert Enum.map(mia_user.teams, & &1.key) == ["PAY"]

    {:ok, ada_user} = Auth.user_for_account(ada)
    assert Auth.can_control?(ada_user)
    assert Auth.movable_teams(ada_user) == :all

    member = %{mia_user | admin: false}
    assert Auth.can_move?(member, "PAY-12")
    refute Auth.can_move?(member, "WEB-3")
    refute Auth.can_control?(member)
  end

  describe "web" do
    setup do
      accounts_mode!()
      start_endpoint!()
      :ok
    end

    test "a fresh install goes to setup; the first account signs straight in" do
      assert redirected_to(get(build_conn(), "/")) == "/login"
      assert redirected_to(get(build_conn(), "/login")) == "/signup"
      assert html_response(get(build_conn(), "/signup"), 200) =~ "this account will be the admin"

      signup = %{"username" => "mia", "email" => "mia@acme.test", "password" => @password, "password_confirmation" => @password}

      # The first account needs the setup code from the server log.
      assert html_response(post(build_conn(), "/signup", signup), 422) =~ "setup code"
      assert html_response(post(build_conn(), "/signup", Map.put(signup, "setup_code", "AAAA-BBBB")), 422) =~ "setup code"

      conn = post(build_conn(), "/signup", Map.put(signup, "setup_code", Users.setup_code()))
      assert redirected_to(conn) == "/"
      assert html_response(conn |> recycle() |> get("/"), 200) =~ "Mia Member"

      conn = conn |> recycle() |> post("/logout")
      assert redirected_to(conn) == "/login"
      assert redirected_to(conn |> recycle() |> get("/")) == "/login"
    end

    test "sign-in rejects bad passwords and pending accounts; admins approve from the rail" do
      {:ok, mia} = register!("mia", "mia@acme.test")

      conn =
        post(build_conn(), "/signup", %{"username" => "ada", "email" => "ada@acme.test", "password" => @password, "password_confirmation" => @password})

      assert html_response(conn, 200) =~ "Request sent"

      assert html_response(post(build_conn(), "/login", %{"login" => "ada", "password" => @password}), 401) =~ "waiting for an admin"
      assert html_response(post(build_conn(), "/login", %{"login" => "mia", "password" => "nope nope nope"}), 401) =~ "username or password"

      {:ok, view, html} = live(session_for(mia), "/")
      assert html =~ "Pending accounts"
      [%{id: ada_id}] = Users.list("pending")

      view |> element(~s(button[phx-value-id="#{ada_id}"]), "Approve") |> render_click()
      assert Users.get(ada_id).status == "active"

      conn = post(build_conn(), "/login", %{"login" => "ada", "password" => @password})
      assert redirected_to(conn) == "/"
    end

    test "the API needs a session or server.api_token" do
      assert json_response(get(build_conn(), "/api/v1/state"), 401)["error"]["code"] == "unauthorized"

      token = String.duplicate("t", 32)
      accounts_mode!(server_api_token: token)

      conn = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer " <> token) |> get("/api/v1/state")
      assert conn.status == 200

      conn = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer wrong") |> get("/api/v1/state")
      assert conn.status == 401
    end

    test "members move their own team's issues and the move is attributed; only admins change controls" do
      {:ok, _admin} = register!("ada", "ada@acme.test")
      {:ok, mia} = register!("mia", "mia@acme.test")
      {:ok, mia} = Users.approve(mia.id, "ada")

      {:ok, view, _html} = live(session_for(mia), "/")

      render_hook(view, "factory_move", %{"id" => "id-WEB-1", "issue" => "WEB-1", "to" => "merge"})
      assert_reply(view, %{ok: false, error: "You can only move issues from teams you belong to" <> _})

      # Lying about the identifier doesn't help: the team comes from the tracker.
      render_hook(view, "factory_move", %{"id" => "id-WEB-1", "issue" => "PAY-1", "to" => "merge"})
      assert_reply(view, %{ok: false, error: "You can only move issues from teams you belong to" <> _})
      refute_received {:set_stage, %{issueId: "id-WEB-1"}}

      render_hook(view, "factory_move", %{"id" => "id-NOPE-9", "to" => "merge"})
      assert_reply(view, %{ok: false})

      render_hook(view, "factory_move", %{"id" => "id-PAY-1", "issue" => "PAY-1", "to" => "merge"})
      assert_reply(view, %{ok: true})
      assert_receive {:set_stage, %{issueId: "id-PAY-1", labelIds: ["lbl-merge"]}}
      assert_receive {:comment, %{issueId: "id-PAY-1", body: body}}
      assert body =~ ~S"Mia Member (@mia) moved this to **Merge \(In Progress · factory/merge\)**"

      # Mia is in PAY, not WEB: she can't change WEB's flow.
      render_hook(view, "factory_control", %{"team" => "WEB", "stage" => "merge", "field" => "paused", "value" => true})
      assert_reply(view, %{ok: false, error: "Only this team's members and Linear admins" <> _})
      refute FactoryControls.paused?({"WEB", "merge"})
    end
  end

  describe "account management" do
    setup do
      accounts_mode!()
      start_endpoint!()
      {:ok, admin} = register!("ada", "ada@acme.test")
      {:ok, mia} = register!("mia", "mia@acme.test")
      {:ok, mia} = Users.approve(mia.id, "ada")
      %{admin: admin, mia: mia}
    end

    test "changing a password signs out other sessions", %{mia: mia} do
      old_session = session_for(mia)
      assert html_response(get(old_session, "/account"), 200) =~ "@mia"

      new_password = "a brand new passphrase"

      conn =
        post(session_for(mia), "/account/password", %{
          "current_password" => @password,
          "password" => new_password,
          "password_confirmation" => new_password
        })

      assert html_response(conn, 200) =~ "Password changed"
      # The session that made the change stays signed in.
      assert html_response(conn |> recycle() |> get("/"), 200) =~ "Mia Member"
      # Every older session is signed out.
      assert redirected_to(get(old_session, "/")) == "/login"
      assert {:ok, _} = Auth.sign_in("mia", new_password)
      assert {:error, :invalid_credentials} = Auth.sign_in("mia", @password)

      conn = post(session_for(mia), "/account/password", %{"current_password" => "wrong password!!", "password" => new_password, "password_confirmation" => new_password})
      assert html_response(conn, 422) =~ "isn&#39;t right"
    end

    test "reset links set a new password once and then stop working", %{mia: mia} do
      {:ok, token} = Users.create_reset_token(mia.id)
      assert html_response(get(build_conn(), "/reset/#{token}"), 200) =~ "@mia"

      new_password = "reset passphrase 123"
      conn = post(build_conn(), "/reset/#{token}", %{"password" => new_password, "password_confirmation" => new_password})
      assert html_response(conn, 200) =~ "Password set"
      assert {:ok, _} = Auth.sign_in("mia", new_password)

      assert html_response(get(build_conn(), "/reset/#{token}"), 404) =~ "invalid or has expired"
      assert html_response(get(build_conn(), "/reset/not-a-token"), 404) =~ "invalid or has expired"
    end

    test "admins manage users; disabling signs the person out", %{admin: admin, mia: mia} do
      assert {:error, {:redirect, %{to: "/"}}} = live(session_for(mia), "/admin/users")

      mia_session = session_for(mia)
      {:ok, view, html} = live(session_for(admin), "/admin/users")
      assert html =~ "@mia"
      assert html =~ "Member · PAY"

      view |> element(~s(button[phx-click="reset"][phx-value-id="#{mia.id}"])) |> render_click()
      assert render(view) =~ "/reset/"

      view |> element(~s(button[phx-click="disable"][phx-value-id="#{mia.id}"])) |> render_click()
      assert Users.get(mia.id).status == "disabled"
      assert redirected_to(get(mia_session, "/")) == "/login"
      assert {:error, :disabled} = Auth.sign_in("mia", @password)

      # The first admin can't be disabled, by anyone.
      assert {:error, :cannot_disable_bootstrap} = Users.disable(admin.id, "someone")
    end

    test "repeated sign-in attempts from one address are rate limited" do
      statuses = for _ <- 1..21, do: post(build_conn(), "/login", %{"login" => "mia", "password" => "nope nope nope"}).status
      assert List.last(statuses) == 429
      assert Enum.count(statuses, &(&1 == 401)) == 20
    end
  end
end
