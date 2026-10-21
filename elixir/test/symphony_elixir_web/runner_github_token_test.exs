# credo:disable-for-this-file Credo.Check.Readability.MaxLineLength
defmodule SymphonyElixirWeb.RunnerGitHubTokenTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.RunnerTestSupport, as: Support
  alias SymphonyElixir.{RunRegistry, RunToken}
  alias SymphonyElixirWeb.RateLimit

  @endpoint SymphonyElixirWeb.Endpoint
  @token "ghs_" <> String.duplicate("e", 36)
  @path "/runner/v1/runs/run-1/github-token"

  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:ok, pem: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])}
  end

  setup do
    root = Support.temp_root!("runner-github-token")
    Support.setup_runs!(root)
    previous_endpoint = Application.get_env(:symphony_elixir, @endpoint)
    Support.start_endpoint!()
    previous_key = System.get_env("GITHUB_APP_PRIVATE_KEY")
    previous_req = Application.get_env(:symphony_elixir, :github_app_req_options)
    RateLimit.reset()

    on_exit(fn ->
      Application.put_env(:symphony_elixir, @endpoint, previous_endpoint)
      if previous_key, do: System.put_env("GITHUB_APP_PRIVATE_KEY", previous_key), else: System.delete_env("GITHUB_APP_PRIVATE_KEY")
      if previous_req, do: Application.put_env(:symphony_elixir, :github_app_req_options, previous_req), else: Application.delete_env(:symphony_elixir, :github_app_req_options)
      RateLimit.reset()
    end)

    :ok
  end

  # A workflow with github_app (a fresh app id, so no cached token is reused)
  # whose GitHub API is the test process.
  defp configure_github_app!(pem, status \\ 201) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_projects: [%{slug: "p", repo: "octo/home", repos: [%{name: "docs", repo: "octo/docs"}]}]
    )

    path = Workflow.workflow_file_path()
    app_id = System.unique_integer([:positive])
    "---\n" <> rest = File.read!(path)
    File.write!(path, "---\ngithub_app:\n  app_id: #{app_id}\n  installation_id: 7\n  private_key: $GITHUB_APP_PRIVATE_KEY\n" <> rest)
    SymphonyElixir.WorkflowStore.force_reload()
    System.put_env("GITHUB_APP_PRIVATE_KEY", pem)

    parent = self()

    Application.put_env(:symphony_elixir, :github_app_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:github_request, conn.request_path, Jason.decode!(body)})

        if status in 200..299,
          do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"token" => @token, "expires_at" => "2030-01-01T01:00:00Z"}),
          else: Plug.Conn.send_resp(conn, status, "{}")
      end
    )
  end

  defp record_run!(issue_id, run_id, epoch, issue) do
    :ok =
      RunRegistry.record(issue_id, %{
        run_id: run_id,
        attempt: 0,
        epoch: epoch,
        launcher: SymphonyElixir.RunLauncher.Local,
        ref: "test:#{run_id}",
        started_at_unix_ms: System.system_time(:millisecond),
        metadata: %{identifier: issue && issue.identifier, backend: "claude", project_slug: "p", labels: [], issue: issue}
      })
  end

  defp post_token(path, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post(path, "{}")
    |> then(&%{&1 | resp_body: Jason.decode!(&1.resp_body)})
  end

  defp issue(labels \\ []), do: %Issue{id: "issue-1", identifier: "MT-GH-1", project_slug: "p", labels: labels}

  test "returns a token for the run's home repository only", %{pem: pem} do
    configure_github_app!(pem)
    record_run!("issue-1", "run-1", 1, issue())

    assert %{status: 200, resp_body: body} = post_token(@path, RunToken.sign("run-1", 1))
    assert body == %{"token" => @token, "expires_at" => "2030-01-01T01:00:00Z", "host" => "github.com"}

    assert_receive {:github_request, "/app/installations/7/access_tokens", request}
    assert request["repositories"] == ["home"]
    assert request["permissions"] == %{"contents" => "write", "pull_requests" => "write", "metadata" => "read"}
  end

  test "the registry's issue labels pick the home repo; reference repos never get a token", %{pem: pem} do
    configure_github_app!(pem)
    record_run!("issue-1", "run-1", 1, issue(["repo/docs"]))

    assert %{status: 200} = post_token(@path, RunToken.sign("run-1", 1))
    assert_receive {:github_request, _path, %{"repositories" => ["docs"]}}
  end

  test "a run without its issue in the registry falls back to the project", %{pem: pem} do
    configure_github_app!(pem)
    record_run!("issue-1", "run-1", 1, nil)

    assert %{status: 200} = post_token(@path, RunToken.sign("run-1", 1))
    assert_receive {:github_request, _path, %{"repositories" => ["home"]}}
  end

  test "bad tokens, stale epochs and other runs' tokens are refused before GitHub is asked", %{pem: pem} do
    configure_github_app!(pem)
    record_run!("issue-1", "run-1", 1, issue())
    record_run!("issue-2", "run-2", 1, %{issue() | id: "issue-2", identifier: "MT-GH-2"})

    assert %{status: 401} = post_token(@path, "not-a-token")
    assert %{status: 401} = post_token(@path, RunToken.sign("run-1", 1) <> "x")
    # Run 2's genuine token does not open run 1's endpoint.
    assert %{status: 401} = post_token(@path, RunToken.sign("run-2", 1))
    assert %{status: 404, resp_body: %{"error" => "run_not_found"}} = post_token("/runner/v1/runs/missing/github-token", RunToken.sign("missing", 1))

    stale = RunToken.sign("run-1", 1)
    record_run!("issue-1", "run-1", 2, issue())
    assert %{status: 409, resp_body: %{"error" => "stale_epoch"}} = post_token(@path, stale)

    refute_received {:github_request, _path, _body}
    assert %{status: 200} = post_token(@path, RunToken.sign("run-1", 2))
  end

  test "is rate limited per run", %{pem: pem} do
    configure_github_app!(pem)
    record_run!("issue-1", "run-1", 1, issue())
    record_run!("issue-2", "run-2", 1, %{issue() | id: "issue-2", identifier: "MT-GH-2"})

    for _ <- 1..10, do: assert(%{status: 200} = post_token(@path, RunToken.sign("run-1", 1)))

    assert %{status: 429, resp_body: %{"error" => "rate_limited"}} = conn = post_token(@path, RunToken.sign("run-1", 1))
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["600"]
    # Another run has its own budget.
    assert %{status: 200} = post_token("/runner/v1/runs/run-2/github-token", RunToken.sign("run-2", 1))
  end

  test "404 without github_app, 502 when GitHub refuses, and the token is never logged", %{pem: pem} do
    record_run!("issue-1", "run-1", 1, issue())
    assert %{status: 404, resp_body: %{"error" => "github_app_not_configured"}} = post_token(@path, RunToken.sign("run-1", 1))

    configure_github_app!(pem, 403)

    log =
      capture_log(fn ->
        assert %{status: 502, resp_body: %{"error" => "token_unavailable"}} = post_token(@path, RunToken.sign("run-1", 1))
      end)

    assert log =~ "GitHub App token refresh failed run_id=run-1 reason=:forbidden"
    refute log =~ "ghs_"
  end
end
