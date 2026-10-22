defmodule SymphonyElixir.AgentMessagesApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{AgentInbox, Auth, Transcript, Users}
  alias SymphonyElixirWeb.RateLimit

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinear do
    def graphql(query, variables, _opts \\ []) do
      if query =~ "SymphonyMemberByEmail",
        do: member(String.downcase(variables[:email])),
        else: {:ok, %{"data" => %{}}}
    end

    defp member("mia@acme.test"), do: users("Mia", false, false, ["PAY"])
    defp member("ada@acme.test"), do: users("Ada", true, false, [])
    defp member("gus@acme.test"), do: users("Gus", false, true, ["PAY"])
    defp member(_email), do: {:ok, %{"data" => %{"users" => %{"nodes" => []}}}}

    defp users(name, admin, guest, teams) do
      nodes = Enum.map(teams, &%{"id" => "t-" <> &1, "key" => &1, "name" => &1})
      user = %{"id" => "u-" <> name, "displayName" => name, "admin" => admin, "guest" => guest, "active" => true, "teams" => %{"nodes" => nodes}}
      {:ok, %{"data" => %{"users" => %{"nodes" => [user]}}}}
    end
  end

  setup do
    Auth.clear_cache()
    Users.reset()
    RateLimit.reset()
    AgentInbox.reset()
    Transcript.reset()
    saved_client = Application.get_env(:symphony_elixir, :linear_client_module)
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)

    on_exit(fn ->
      Auth.clear_cache()
      Users.reset()
      AgentInbox.reset()
      Transcript.reset()

      if saved_client,
        do: Application.put_env(:symphony_elixir, :linear_client_module, saved_client),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      server_host: "0.0.0.0",
      server_api_token: "api-secret-token-0123456789abcdef",
      tracker_kind: "linear",
      tracker_api_token: "server-key"
    )

    config = Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64))
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    %{admin: register!("ada", "ada@acme.test"), mia: register!("mia", "mia@acme.test"), gus: register!("gus", "gus@acme.test")}
  end

  test "team members send and list messages on their team's issues", %{mia: mia} do
    conn = session_for(mia) |> json_post("/api/v1/issues/PAY-1/messages", %{"text" => "Use the v2 endpoint"})
    assert %{"message" => %{"id" => id, "author" => "Mia", "status" => "queued", "text" => "Use the v2 endpoint"}} = json_response(conn, 201)

    assert %{"issue_identifier" => "PAY-1", "messages" => [%{"id" => ^id}]} =
             session_for(mia) |> get("/api/v1/issues/PAY-1/messages") |> json_response(200)

    assert [%{kind: "user", author: "Mia"}] = Transcript.entries("PAY-1")

    assert %{"error" => %{"code" => "empty_message"}} =
             session_for(mia) |> json_post("/api/v1/issues/PAY-1/messages", %{"text" => " "}) |> json_response(422)

    assert %{"error" => %{"code" => "message_too_long"}} =
             session_for(mia) |> json_post("/api/v1/issues/PAY-1/messages", %{"text" => String.duplicate("a", 8_001)}) |> json_response(422)
  end

  test "issues outside the viewer's teams are not found; guests can read but not send", %{mia: mia, gus: gus, admin: admin} do
    assert json_response(session_for(mia) |> get("/api/v1/issues/WEB-1/messages"), 404)
    assert json_response(session_for(mia) |> json_post("/api/v1/issues/WEB-1/messages", %{"text" => "hi"}), 404)
    assert AgentInbox.messages("WEB-1") == []

    assert json_response(session_for(gus) |> get("/api/v1/issues/PAY-1/messages"), 200)
    assert %{"error" => %{"code" => "forbidden"}} = json_response(session_for(gus) |> json_post("/api/v1/issues/PAY-1/messages", %{"text" => "hi"}), 403)

    assert json_response(session_for(admin) |> json_post("/api/v1/issues/WEB-1/messages", %{"text" => "hi"}), 201)
  end

  test "posts must be JSON, signed in or with the API token", %{mia: mia} do
    form = session_for(mia) |> post("/api/v1/issues/PAY-1/messages", %{"text" => "from a form"})
    assert %{"error" => %{"code" => "unsupported_media_type"}} = json_response(form, 415)

    assert json_response(build_conn() |> json_post("/api/v1/issues/PAY-1/messages", %{"text" => "hi"}), 401)

    token_conn = build_conn() |> put_req_header("authorization", "Bearer api-secret-token-0123456789abcdef") |> json_post("/api/v1/issues/PAY-1/messages", %{"text" => "hi"})
    assert %{"message" => %{"author" => "API client"}} = json_response(token_conn, 201)

    assert json_response(build_conn() |> put("/api/v1/issues/PAY-1/messages", %{}), 405)
  end

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  # Usernames come from the email, so `username` documents the expected one.
  defp register!(username, email) do
    account = iap_account!(email)
    ^username = account.username
    account
  end

  defp session_for(account), do: iap_conn(account)
end
