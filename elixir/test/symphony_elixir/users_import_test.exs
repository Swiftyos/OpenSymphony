defmodule SymphonyElixir.UsersImportTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{Auth, McpTokens, Policy, Users}
  alias SymphonyElixir.Users.Import
  alias SymphonyElixirWeb.RateLimit

  @endpoint SymphonyElixirWeb.Endpoint
  @teams %{"t-pay" => "PAY", "t-web" => "WEB", "t-ops" => "OPS"}

  defmodule FakeLinear do
    def graphql(query, variables, _opts \\ []) do
      cond do
        query =~ "SymphonyTeamKeys" -> {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "t-pay", "key" => "PAY"}, %{"id" => "t-web", "key" => "WEB"}]}}}}
        query =~ "SymphonyMemberByEmail" -> {:ok, %{"data" => %{"users" => %{"nodes" => member(variables[:email])}}}}
        true -> {:ok, %{"data" => %{}}}
      end
    end

    # Only the bootstrap admin is in Linear; everyone else signs in as provisioned.
    defp member("boss@acme.test"), do: [%{"id" => "u-boss", "displayName" => "Boss", "admin" => false, "guest" => false, "active" => true, "teams" => %{"nodes" => []}}]
    defp member(_email), do: []
  end

  @csv """
  email,linear_team_name,linear_team_id,role
  Pia@Acme.test,Payments,t-pay,member
  pia@acme.test,Web,t-web,admin
  "quinn@acme.test","Payments, the team",t-pay,admin
  quinn@acme.test,Payments,t-pay,member
  ops@acme.test,Ops,t-ops,member
  viewer@acme.test,,,global_viewer
  boss@acme.test,,,global_viewer
  """

  setup do
    Auth.clear_cache()
    Users.reset()
    RateLimit.reset()
    McpTokens.reset()
    saved = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)

    on_exit(fn ->
      Auth.clear_cache()
      Users.reset()
      McpTokens.reset()

      if saved,
        do: Application.put_env(:symphony_elixir, :linear_client_module, saved),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0", tracker_kind: "linear", tracker_api_token: "server-key")
    # The first account is the bootstrap admin; the CSV lists it as a viewer.
    boss = iap_account!("boss@acme.test")
    %{boss: boss}
  end

  test "creates accounts with a role per team, keeps the admin, and is idempotent", %{boss: boss} do
    {:ok, other} = Users.ensure("other@acme.test")
    {:ok, _} = Users.set_access(other.id, "OPS", true, "boss")

    assert {:ok, report} = Import.from_csv(@csv, teams: @teams)
    assert %{dry_run: false, written: true, rows: 7, accounts: 5, teams: 3} = report
    assert %{created: 4, updated: 0, unchanged: 1, admins_kept: 1, errors: []} = report
    assert report.not_in_csv == ["other@acme.test"]

    pia = Users.get_by_email("pia@acme.test")
    assert %{status: "active", access: ["PAY"], team_admin: ["WEB"], role: nil, imported_at: at, last_sign_in_at: nil} = pia
    assert is_binary(at)

    # Listed as admin and member of one team: admin wins.
    assert %{team_admin: ["PAY"], access: []} = Users.get_by_email("quinn@acme.test")
    assert %{role: "global_viewer", team_admin: [], access: []} = Users.get_by_email("viewer@acme.test")

    # The bootstrap admin stays an admin; the account not in the CSV is untouched.
    assert %{bootstrap_admin: true, role: nil} = Users.get(boss.id)
    assert Users.get(other.id).access == ["OPS"]

    # Again: nothing to do.
    assert {:ok, again} = Import.from_csv(@csv, teams: @teams)
    assert %{created: 0, updated: 0, unchanged: 5, written: false, changes: []} = again

    # They get it all on first sign-in, even without a Linear user.
    {:ok, user} = Auth.user_for_email("pia@acme.test")
    assert Enum.map(user.teams, & &1.key) |> Enum.sort() == ["PAY", "WEB"]
    assert Policy.can?(user, {:grant, "WEB"})
    refute Policy.can?(user, {:grant, "PAY"})
    {:ok, viewer} = Auth.user_for_email("viewer@acme.test")
    assert Policy.role(viewer) == :global_viewer
    assert Users.get_by_email("pia@acme.test").id == pia.id
  end

  test "the CSV decides each listed team's role; other grants stay" do
    {:ok, pia} = Users.ensure("pia@acme.test")
    {:ok, _} = Users.set_team_admin(pia.id, "PAY", true, "boss")
    {:ok, _} = Users.set_access(pia.id, "project:checkout", true, "boss")

    assert {:ok, %{updated: 1, changes: changes}} = Import.from_csv(@csv, teams: @teams)
    assert %{action: :updated, team_admin_added: ["WEB"], team_admin_removed: ["PAY"], access_added: ["PAY"]} = Enum.find(changes, &(&1.email == "pia@acme.test"))
    assert %{team_admin: ["WEB"], access: ["PAY", "project:checkout"], imported_at: nil} = Users.get(pia.id)
  end

  test "a dry run reports without writing" do
    assert {:ok, %{dry_run: true, written: false, created: 4}} = Import.from_csv(@csv, teams: @teams, dry_run: true)
    assert Users.get_by_email("pia@acme.test") == nil
  end

  test "bad rows are reported, and nothing is written unless told to skip them" do
    csv = @csv <> "not-an-email,Pay,t-pay,member\nzed@acme.test,Nope,t-nope,member\nzed@acme.test,Pay,t-pay,owner\nzed@acme.test,,,member\n"

    assert {:ok, %{written: false, errors: errors}} = Import.from_csv(csv, teams: @teams)
    assert Enum.map(errors, & &1.line) == [9, 10, 11, 12]
    assert Enum.map(errors, & &1.reason) == ["invalid email", "unknown Linear team id t-nope", ~s(unknown role "owner"), "member needs a linear_team_id"]
    assert Users.get_by_email("pia@acme.test") == nil

    assert {:ok, %{written: true, created: 4}} = Import.from_csv(csv, teams: @teams, skip_invalid: true)
    assert Users.get_by_email("zed@acme.test") == nil
  end

  test "team ids are looked up in Linear; a path works too; bad input is refused" do
    path = Path.join(System.tmp_dir!(), "import-#{System.unique_integer([:positive])}.csv")
    File.write!(path, "﻿email,role,linear_team_id,linear_team_name\r\npia@acme.test,member,t-pay,Payments\r\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{created: 1, errors: []}} = Import.from_csv(path)
    assert Users.get_by_email("pia@acme.test").access == ["PAY"]

    assert {:error, {:missing_columns, ["role"]}} = Import.from_csv("email,linear_team_name,linear_team_id\nx@y.z,a,b\n", teams: @teams)
    assert {:error, {:unreadable, :enoent}} = Import.from_csv("/nonexistent.csv")
  end

  test "refuses to run before there's an admin account" do
    Users.reset()
    assert {:error, :no_admin_account} = Import.from_csv(@csv, teams: @teams)
  end

  test "the counts-only summary has no emails" do
    {:ok, report} = Import.from_csv(@csv, teams: @teams, dry_run: true)
    summary = Import.summary(report)
    refute inspect(summary) =~ "@"
    assert %{created: 4, errors: 0, not_in_csv: 0} = summary
  end

  describe "over HTTP" do
    setup do
      endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config) end)

      path = Workflow.workflow_file_path()
      File.write!(path, String.replace(File.read!(path), "\nserver:\n", "\nserver:\n  mcp:\n    enabled: true\n", global: false))
      WorkflowStore.force_reload()

      config = Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64))
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
      start_supervised!({SymphonyElixirWeb.Endpoint, []})
      :ok
    end

    test "an admin's MCP token imports; a global viewer's or member's is refused", %{boss: boss} do
      csv = String.replace(@csv, "t-ops", "t-web")
      {:ok, admin_token, _} = McpTokens.current(boss.id)

      dry = post_csv(admin_token, "/admin/users/import?dry_run=true", csv)
      assert %{"dry_run" => true, "written" => false, "created" => 4, "errors" => []} = json_response(dry, 200)
      assert Users.get_by_email("pia@acme.test") == nil

      assert %{"written" => true, "created" => 4} = json_response(post_csv(admin_token, "/admin/users/import", csv), 200)
      assert %{"written" => false, "unchanged" => 5} = json_response(post_csv(admin_token, "/admin/users/import", csv), 200)

      for email <- ["viewer@acme.test", "pia@acme.test"] do
        {:ok, token, _} = McpTokens.current(Users.get_by_email(email).id)
        assert %{"error" => %{"code" => "forbidden"}} = json_response(post_csv(token, "/admin/users/import", csv), 403)
      end

      assert json_response(post_csv("symp_nope", "/admin/users/import", csv), 401)
      assert %{"error" => %{"code" => "invalid_import"}} = json_response(post_csv(admin_token, "/admin/users/import", "email,role\n"), 422)
    end
  end

  defp post_csv(token, path, body) do
    build_conn()
    |> put_req_header("content-type", "text/csv")
    |> put_req_header("authorization", "Bearer " <> token)
    |> post(path, body)
  end
end
