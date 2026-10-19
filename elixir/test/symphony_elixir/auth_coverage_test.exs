defmodule SymphonyElixir.AuthCoverageTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Auth, Users}
  alias SymphonyElixirWeb.{RateLimit, RequestGuards, UserAuth, Visibility}

  @endpoint SymphonyElixirWeb.Endpoint
  @password "correct horse battery"

  defmodule FakeLinear do
    @pay %{"id" => "t", "key" => "PAY", "name" => "PAY"}

    def graphql(query, variables, _opts \\ []) do
      if query =~ "SymphonyMemberByEmail", do: member(String.downcase(variables[:email])), else: {:ok, %{"data" => %{}}}
    end

    defp member("ada@acme.test"), do: users([user("u-ada", "Ada Admin", true, [])])
    defp member("lin@acme.test"), do: users([user("u-lin", "Lin Admin", true, [])])
    defp member("mia@acme.test"), do: users([user("u-mia", "Mia Member", false, [@pay])])
    defp member("gone@acme.test"), do: users([Map.put(user("u-gone", "Gone", false, []), "active", false)])
    defp member(_email), do: users([])

    defp users(nodes), do: {:ok, %{"data" => %{"users" => %{"nodes" => nodes}}}}

    defp user(id, name, admin, teams) do
      %{"id" => id, "displayName" => name, "admin" => admin, "guest" => false, "active" => true}
      |> Map.put("teams", %{"nodes" => teams})
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
    saved = Application.get_env(:symphony_elixir, :linear_client_module)
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)

    on_exit(fn ->
      Auth.clear_cache()
      Users.reset()
      RateLimit.reset()

      if saved,
        do: Application.put_env(:symphony_elixir, :linear_client_module, saved),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)

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
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(orchestrator: name, snapshot_timeout_ms: 200)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  # Registers without the Linear gate so accounts with Linear problems can exist.
  defp register!(username, email, extra \\ %{}) do
    base = %{"username" => username, "email" => email, "password" => @password, "setup_code" => Users.setup_code()}
    params = Map.merge(base, extra)
    {:ok, account} = Users.register(params, fn _email -> :ok end)
    account
  end

  defp active!(username, email) do
    account = register!(username, email)
    if account.status == "pending", do: elem(Users.approve(account.id, "test"), 1), else: account
  end

  defp session_for(account) do
    session = %{"user_id" => account.id, "session_version" => Users.get(account.id).session_version}
    Plug.Test.init_test_session(build_conn(), session)
  end

  # Clicks the rendered button, so the test fails if the button isn't shown.
  defp click(view, action, id) do
    view |> element(~s(button[phx-click="#{action}"][phx-value-id="#{id}"])) |> render_click()
  end

  describe "auth controller" do
    setup do
      accounts_mode!()
      start_endpoint!()
      %{mia: active!("mia", "mia@acme.test")}
    end

    test "the sign-in page renders once accounts exist; a malformed sign-in is a 400" do
      assert html_response(get(build_conn(), "/login"), 200) =~ "Sign in to"
      assert html_response(post(build_conn(), "/login", %{}), 400) =~ "username or password"
    end

    test "signed-in people are sent from sign-up to the dashboard", %{mia: mia} do
      assert redirected_to(get(session_for(mia), "/signup")) == "/"
    end

    test "reset form errors: unknown tokens 404, weak passwords re-render the form", %{mia: mia} do
      new_password = "reset passphrase 123"
      params = %{"password" => new_password, "password_confirmation" => new_password}
      conn = post(build_conn(), "/reset/not-a-token", params)
      assert html_response(conn, 404) =~ "invalid or has expired"

      {:ok, token} = Users.create_reset_token(mia.id)
      html = build_conn() |> post("/reset/#{token}", %{"password" => "short"}) |> html_response(422)
      assert html =~ "@mia"
      assert html =~ "at least 12 characters"
      # The link still works after a failed attempt.
      assert Users.reset_account_for_token(token).id == mia.id
    end

    test "local mode has no account page" do
      write_workflow_file!(Workflow.workflow_file_path())
      assert Auth.mode() == :local

      assert redirected_to(get(build_conn(), "/account")) == "/"
      assert redirected_to(post(build_conn(), "/account/password", %{"current_password" => "x"})) == "/"
    end
  end

  describe "user auth" do
    setup do
      accounts_mode!()
      :ok
    end

    test "sign_in stores version 0 for an id without an account" do
      ghost = %Auth.User{id: "usr_ghost", name: "Ghost"}
      conn = build_conn() |> Plug.Test.init_test_session(%{}) |> UserAuth.sign_in(ghost)
      assert Plug.Conn.get_session(conn, "user_id") == "usr_ghost"
      assert Plug.Conn.get_session(conn, "session_version") == 0
    end

    test "the LiveView hook redirects sessions that no longer resolve to a user" do
      socket = %Phoenix.LiveView.Socket{endpoint: @endpoint}
      assert {:halt, halted} = UserAuth.on_mount(:require_user, %{}, %{"user_id" => "usr_ghost"}, socket)
      assert halted.redirected == {:redirect, %{to: "/login", status: 302}}
    end
  end

  describe "users admin page" do
    setup do
      accounts_mode!()
      start_endpoint!()
      admin = active!("ada", "ada@acme.test")
      lin = active!("lin", "lin@acme.test")
      mia = active!("mia", "mia@acme.test")
      {:ok, mia} = Users.disable(mia.id, "ada")
      gone = active!("gone", "gone@acme.test")
      pat = register!("pat", "pat@outside.test", %{"requested_from" => "10.0.0.7"})
      rex = register!("rex", "rex@outside.test")
      %{admin: admin, lin: lin, mia: mia, gone: gone, pat: pat, rex: rex}
    end

    test "admins approve, reject, re-enable and reset; bad requests show a message", ctx do
      {:ok, view, html} = live(session_for(ctx.admin), "/admin/users")

      assert html =~ "requested"
      assert html =~ "from 10.0.0.7"
      assert html =~ "Not in Linear workspace"
      assert html =~ "Deactivated in Linear"
      assert html =~ "Reject @pat&#39;s request?"

      # Unrelated messages are ignored.
      send(view.pid, :unrelated)
      assert render(view) =~ "@pat"

      assert click(view, "approve", ctx.pat.id) =~ "Approved."
      assert Users.get(ctx.pat.id).status == "active"

      assert click(view, "reject", ctx.rex.id) =~ "Request rejected."
      assert Users.get(ctx.rex.id) == nil

      assert click(view, "enable", ctx.mia.id) =~ "Re-enabled."
      assert Users.get(ctx.mia.id).status == "active"

      assert render_click(view, "disable", %{"id" => ctx.admin.id}) =~ "You can&#39;t disable your own account."
      assert Users.get(ctx.admin.id).status == "active"

      assert render_click(view, "reset", %{"id" => "usr_missing"}) =~ "Couldn&#39;t create a reset link: :not_found"
      assert render_click(view, "approve", %{"id" => "usr_missing"}) =~ "That didn&#39;t work: :not_found"

      assert click(view, "reset", ctx.mia.id) =~ "/reset/"
      refute view |> element(~s(button[phx-click="dismiss_reset"])) |> render_click() =~ "/reset/"
    end

    test "the first admin can't be disabled, and a stale admin session is sent to sign in", ctx do
      {:ok, view, _html} = live(session_for(ctx.lin), "/admin/users")

      assert render_click(view, "disable", %{"id" => ctx.admin.id}) =~ "The first admin account can&#39;t be disabled."
      assert Users.get(ctx.admin.id).status == "active"

      {:ok, _} = Users.disable(ctx.lin.id, "ada")
      assert {:error, {:redirect, %{to: "/login"}}} = render_click(view, "approve", %{"id" => ctx.pat.id})
      assert Users.get(ctx.pat.id).status == "pending"
    end
  end

  describe "rate limit" do
    test "only POSTs are counted and init accepts known actions" do
      assert RateLimit.init(:login) == :login
      conn = build_conn(:get, "/login")
      assert RateLimit.call(conn, :login) == conn
    end

    test "old windows are pruned" do
      table = :symphony_rate_limit
      stale_window = div(System.monotonic_time(:millisecond), 15 * 60_000) - 1
      stale_key = {:login, {192, 0, 2, 1}, stale_window}
      :ets.insert(table, {stale_key, 3})

      # Pick a seed whose first draw triggers the 1-in-200 prune.
      seed = Enum.find(1..100_000, fn seed -> :rand.seed(:exsss, seed) && :rand.uniform(200) == 1 end)
      :rand.seed(:exsss, seed)

      conn = RateLimit.call(build_conn(:post, "/login"), :login)
      refute conn.halted
      assert :ets.lookup(table, stale_key) == []
    end
  end

  describe "request guards" do
    test "trusted proxy headers fall back when values are unusable" do
      write_workflow_file!(Workflow.workflow_file_path(), server_trust_proxy: true)

      conn =
        %{build_conn() | scheme: :https}
        |> Plug.Conn.put_req_header("x-forwarded-for", "not-an-ip")
        |> Plug.Conn.put_req_header("x-forwarded-proto", "http")
        |> RequestGuards.proxy_headers([])

      assert conn.remote_ip == {127, 0, 0, 1}
      assert conn.scheme == :http

      untouched = RequestGuards.proxy_headers(%{build_conn() | scheme: :https}, [])
      assert untouched.scheme == :https
    end
  end

  describe "visibility" do
    test "members lose other teams' entries, unknown identifiers and host fields" do
      member = %Auth.User{id: "m", name: "M", teams: [%{id: "t", key: "PAY", name: "PAY"}]}

      payload = %{
        running: [%{issue_identifier: "PAY-1", workspace_path: "/x"}, %{issue_identifier: "NOPE"}],
        retrying: [],
        projects: [%{issues: [%{issue_identifier: "PAY-2"}, %{title: "no identifier"}]}],
        accounts: [%{id: "acct"}],
        factory: nil
      }

      filtered = Visibility.filter_payload(payload, member)
      assert filtered.running == [%{issue_identifier: "PAY-1"}]
      assert filtered.projects == [%{issues: [%{issue_identifier: "PAY-2"}]}]
      assert filtered.factory == nil
      assert filtered.accounts == []
      assert filtered.counts == %{running: 1, retrying: 0}

      assert Visibility.filter_issue(%{workspace_path: "/x"}, member, "NOPE") == :hidden
      assert Visibility.filter_issue(%{workspace_path: "/x", title: "t"}, member, "PAY-3") == {:ok, %{title: "t"}}
    end
  end
end
