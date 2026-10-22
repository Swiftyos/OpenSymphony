defmodule SymphonyElixir.AuthTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Auth, FactoryControls, UsageLedger, Users}
  alias SymphonyElixirWeb.{RateLimit, UserAuth}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinear do
    @org %{"id" => "org-1", "urlKey" => "acme", "name" => "Acme"}

    def graphql(query, variables, _opts \\ []) do
      cond do
        query =~ "SymphonyMemberByEmail" -> member(variables[:email] |> String.downcase())
        query =~ "SymphonyStageLookup" -> notify({:stage_lookup, variables}) && stage_lookup(variables)
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
    defp member("lee@acme.test"), do: users([user("u-5", "Lee Guest", false, []) |> Map.put("guest", true)])
    defp member("gone@acme.test"), do: users([Map.put(user("u-4", "Gone", false, []), "active", false)])
    defp member(_email), do: users([])

    defp stage_lookup(variables) do
      ok(%{
        "issue" => %{
          "team" => %{"id" => "team-PAY", "states" => %{"nodes" => [%{"id" => "state-ip"}]}},
          "labels" => %{"nodes" => []}
        },
        "issueLabels" => %{"nodes" => [%{"id" => "lbl-merge", "name" => variables.stage, "parent" => %{"name" => "factory"}, "team" => %{"id" => "team-PAY"}}]}
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

  test "mode is local on loopback and IAP everywhere else; accounts is the old name for iap" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Auth.mode() == :local

    accounts_mode!()
    assert Auth.mode() == :iap
    assert Auth.mode(%{server: %{auth: "accounts", host: "127.0.0.1"}}) == :iap
    assert Auth.mode(%{server: %{auth: "iap", host: "127.0.0.1"}}) == :iap
  end

  test "an IAP-verified email gets an account on first visit; the first is the admin; Linear still decides" do
    accounts_mode!()

    assert {:ok, %Auth.User{username: "mia", admin: true}} = Auth.user_for_email("mia@acme.test")
    assert {:ok, %Auth.User{username: "ada", name: "Ada Admin", admin: true}} = Auth.user_for_email("ada@acme.test")
    assert %{"mia" => %{bootstrap_admin: true, status: "active"}, "ada" => %{bootstrap_admin: false}} = Map.new(Users.list(), &{&1.username, &1})

    # The same email is the same account.
    assert {:ok, %Auth.User{username: "mia"}} = Auth.user_for_email("mia@acme.test")
    assert length(Users.list()) == 2

    # Linear gates who may use Symphony, and no account is made for the rest.
    assert {:error, :not_in_workspace} = Auth.user_for_email("eve@evil.test")
    assert {:error, :inactive_user} = Auth.user_for_email("gone@acme.test")
    assert length(Users.list()) == 2
  end

  test "usernames come from the email and stay unique" do
    accounts_mode!(tracker_kind: "memory")

    assert %{username: "mia"} = iap_account!("mia@acme.test")
    assert %{username: "mia2"} = iap_account!("mia@other.test")
    assert %{username: "userjo"} = iap_account!("jo@acme.test")
    assert {:error, :invalid_email} = Users.ensure("not-an-email")
  end

  test "permissions come from the Linear user with the account's email" do
    accounts_mode!()
    mia = iap_account!("mia@acme.test")
    ada = iap_account!("ada@acme.test")

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

    test "the dashboard is for people IAP signed in; there is no sign-in of its own" do
      html = html_response(get(build_conn(), "/"), 401)
      assert html =~ "Sign in through Symphony"
      refute html =~ "password"

      assert html_response(get(iap_conn("mia@acme.test"), "/"), 200) =~ "Mia Member"
      assert %{username: "mia"} = hd(Users.list())

      for path <- ["/login", "/signup", "/reset/abc"], do: assert(get(iap_conn("mia@acme.test"), path).status == 404)
      assert post(iap_conn("mia@acme.test"), "/logout").status in [403, 404]

      # A session cookie alone isn't enough: every request needs IAP's header.
      session = build_conn() |> Plug.Test.init_test_session(%{"user_id" => hd(Users.list()).id, "session_version" => 1})
      assert html_response(get(session, "/"), 401)
    end

    test "Linear decides who gets in, and disabled accounts are refused" do
      assert html_response(get(iap_conn("eve@evil.test"), "/"), 403) =~ "no Linear user"
      assert html_response(get(iap_conn("gone@acme.test"), "/"), 403) =~ "deactivated"
      assert Users.list() == []

      _admin = iap_account!("ada@acme.test")
      mia = iap_account!("mia@acme.test")
      {:ok, _} = Users.disable(mia.id, "ada")
      assert html_response(get(iap_conn("mia@acme.test"), "/"), 403) =~ "disabled"
    end

    test "LiveView sockets mount from the session IAP's check set, for an hour" do
      iap_account!("ada@acme.test")
      mia = iap_account!("mia@acme.test")
      assert {:ok, _view, _html} = live(iap_conn(mia), "/")

      session = %{"user_id" => mia.id, "session_version" => Users.get(mia.id).session_version}
      socket = %Phoenix.LiveView.Socket{endpoint: @endpoint}
      now = System.system_time(:second)

      assert {:cont, _socket} = UserAuth.on_mount(:require_user, %{}, Map.put(session, "iap_verified_at", now - 60), socket)
      # An older session reloads the page, so IAP checks the person again.
      assert {:halt, %{redirected: {:redirect, %{to: "/"}}}} = UserAuth.on_mount(:require_user, %{}, Map.put(session, "iap_verified_at", now - 3_700), socket)
      assert {:halt, _socket} = UserAuth.on_mount(:require_user, %{}, session, socket)
    end

    test "the API needs IAP sign-in or server.api_token" do
      assert json_response(get(build_conn(), "/api/v1/state"), 401)["error"]["code"] == "unauthorized"
      assert get(iap_conn("mia@acme.test"), "/api/v1/state").status == 200

      token = String.duplicate("t", 32)
      accounts_mode!(server_api_token: token)

      conn = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer " <> token) |> get("/api/v1/state")
      assert conn.status == 200

      conn = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer wrong") |> get("/api/v1/state")
      assert conn.status == 401
    end

    test "members move their own team's issues and the move is attributed; only admins change controls" do
      _admin = iap_account!("ada@acme.test")
      mia = iap_account!("mia@acme.test")

      {:ok, view, _html} = live(iap_conn(mia), "/")

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
      admin = iap_account!("ada@acme.test")
      mia = iap_account!("mia@acme.test")
      %{admin: admin, mia: mia}
    end

    test "request logs never contain IAP assertions or other credentials", %{mia: mia} do
      previous = Logger.level()
      Logger.configure(level: :debug)
      conn = iap_conn(mia)
      [assertion] = Plug.Conn.get_req_header(conn, "x-goog-iap-jwt-assertion")

      log =
        try do
          capture_log([level: :debug], fn ->
            get(conn, "/")
            post(iap_conn(mia), "/account/mcp-token/rotate", %{"token" => "tok-secret-value"})
          end)
        after
          Logger.configure(level: previous)
        end

      refute log =~ assertion
      refute log =~ "tok-secret-value"
      assert log =~ "POST /account/mcp-token/rotate"
      assert log =~ ~s("token" => "[FILTERED]")
    end

    test "admins manage users; disabling signs the person out", %{admin: admin, mia: mia} do
      assert {:error, {:redirect, %{to: "/"}}} = live(iap_conn(mia), "/admin/users")

      {:ok, view, html} = live(iap_conn(admin), "/admin/users")
      assert html =~ "@mia"
      assert html =~ ~s(<span class="access-chip" title="Linear team membership">PAY</span>)
      refute html =~ "Reset password"

      view |> element(~s(button[phx-click="disable"][phx-value-id="#{mia.id}"])) |> render_click()
      assert Users.get(mia.id).status == "disabled"
      assert html_response(get(iap_conn(mia), "/"), 403) =~ "disabled"

      view |> element(~s(button[phx-click="enable"][phx-value-id="#{mia.id}"])) |> render_click()
      assert html_response(get(iap_conn(mia), "/"), 200)

      # The first admin can't be disabled, by anyone.
      assert {:error, :cannot_disable_bootstrap} = Users.disable(admin.id, "someone")
    end

    test "admins choose team admins, who give people access to their team and its projects", %{admin: admin, mia: mia} do
      accounts_mode!(tracker_project_slug: nil, tracker_projects: [%{slug: "configured"}])
      lee = iap_account!("lee@acme.test")
      Enum.each(["PAY-1", "WEB-1"], &UsageLedger.observe_issue(%SymphonyElixir.Linear.Issue{id: &1, identifier: &1, state: "Todo", project_slug: "checkout"}))
      UsageLedger.observe_issue(%SymphonyElixir.Linear.Issue{id: "OPS-1", identifier: "OPS-1", state: "Todo", project_slug: "ops-only"})

      # A plain member can't open the page; a Linear guest is read-only.
      assert {:error, {:redirect, %{to: "/"}}} = live(iap_conn(mia), "/admin/users")
      assert {:ok, %Auth.User{guest: true, teams: []}} = Auth.user_for_id(lee.id, 1)

      {:ok, admin_view, html} = live(iap_conn(admin), "/admin/users")
      assert html =~ ~s(value="admin:PAY")
      assert html =~ ~s(value="access:project:configured")
      render_change(element(admin_view, "#grant-#{mia.id}"), %{"account" => mia.id, "choice" => "admin:PAY"})
      assert render(admin_view) =~ "Now a PAY admin."
      assert %{team_admin: ["PAY"]} = Users.get(mia.id)

      # Mia, now a PAY admin, manages access but not accounts.
      {:ok, view, html} = live(iap_conn(mia), "/admin/users")
      refute html =~ ~s(phx-click="disable")
      refute html =~ "admin:PAY"
      assert html =~ ~s(value="access:PAY")
      assert html =~ ~s(value="access:project:checkout")
      refute html =~ ~s(value="access:project:ops-only")
      refute html =~ ~s(value="access:WEB")

      render_change(element(view, "#grant-#{lee.id}"), %{"account" => lee.id, "choice" => "access:project:checkout"})
      assert render(view) =~ "Given access to the checkout project."
      render_hook(view, "grant", %{"account" => lee.id, "choice" => "access:PAY"})
      assert render(view) =~ "Added to PAY."

      # Grants lift guest status and count like membership.
      assert {:ok, %Auth.User{guest: false, projects: ["checkout"], teams: [%{key: "PAY"}]} = lee_user} = Auth.user_for_id(lee.id, Users.get(lee.id).session_version)
      assert Auth.can_move_issue?(lee_user, "WEB-1", "checkout")
      refute Auth.can_move_issue?(lee_user, "WEB-1", "web")
      assert Auth.can_edit_factory?(lee_user, "project:checkout")
      assert Auth.movable_projects(lee_user) == ["checkout"]

      # What a team admin can't do.
      render_hook(view, "grant", %{"account" => lee.id, "choice" => "access:WEB"})
      assert render(view) =~ "You can only give access to teams you administer"
      render_hook(view, "grant", %{"account" => lee.id, "choice" => "admin:PAY"})
      assert render(view) =~ "Only admins can choose team admins."
      render_hook(view, "grant", %{"account" => lee.id, "choice" => "bogus"})
      assert render(view) =~ "Pick a team or project."
      render_hook(view, "grant", %{"account" => lee.id, "choice" => ""})
      render_hook(view, "disable", %{"id" => lee.id})
      assert render(view) =~ "Only admins can manage accounts."

      view |> element(~s(button[phx-click="revoke"][phx-value-choice="access:PAY"])) |> render_click()
      assert render(view) =~ "Removed from PAY."
      render_hook(view, "revoke", %{"id" => lee.id, "choice" => "access:project:checkout"})
      assert render(view) =~ "Removed from the checkout project."
      assert %{access: []} = Users.get(lee.id)

      admin_view |> element(~s(button[phx-click="revoke"][phx-value-choice="admin:PAY"])) |> render_click()
      assert render(admin_view) =~ "No longer a PAY admin."

      # No one signed in, no rights; a session that ended reloads the page through IAP.
      assert Auth.movable_projects(nil) == []
      refute Auth.can_grant?(nil, "PAY")
      {:ok, _} = Users.disable(mia.id, "ada")
      assert {:error, {:redirect, %{to: "/"}}} = render_hook(view, "grant", %{"account" => lee.id, "choice" => "access:PAY"})
    end
  end
end
