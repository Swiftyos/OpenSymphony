# credo:disable-for-this-file Credo.Check.Readability.MaxLineLength
defmodule SymphonyElixir.GitHubApp.RunnerTokenTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubApp
  alias SymphonyElixir.GitHubApp.RunnerToken
  alias SymphonyElixir.RunnerTestSupport, as: Support
  alias SymphonyElixir.{RunSpec, RunToken}

  @first "ghs_" <> String.duplicate("a", 36)
  @second "ghs_" <> String.duplicate("b", 36)
  @now ~U[2030-01-01 00:00:00Z]

  setup do
    root = Support.temp_root!("runner-token")
    %{root: root, dir: Path.join(root, "github")}
  end

  # A controller stub: records each refresh request and answers with `responses`
  # in turn (the last one repeating).
  defp controller(parent, responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn conn ->
      send(parent, {:refresh_request, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})
      respond(conn, Agent.get_and_update(agent, &next_response/1))
    end
  end

  defp next_response([only]), do: {only, [only]}
  defp next_response([next | rest]), do: {next, rest}

  defp respond(conn, {:ok, token, expires_at}), do: Req.Test.json(conn, %{"token" => token, "expires_at" => expires_at, "host" => "github.com"})
  defp respond(conn, {status, body}), do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp start_keeper!(ctx, opts) do
    parent = self()

    defaults = [
      name: nil,
      run_id: "run-1",
      controller_url: "http://controller.test",
      run_token: "run-token-1",
      host: "github.com",
      dir: ctx.dir,
      clock: fn -> @now end,
      base_env: %{},
      apply_env: fn changes -> send(parent, {:env_applied, changes}) end,
      retry_base_ms: 60_000
    ]

    {:ok, pid} = RunnerToken.start_link(Keyword.merge(defaults, opts))
    on_exit(fn -> RunnerToken.stop(pid) end)
    pid
  end

  defp credentials(token, expires_at), do: %{token: token, expires_at: expires_at}

  test "refresh_delay_ms/3 waits until 15 minutes are left" do
    fifteen = 15 * 60_000
    assert RunnerToken.refresh_delay_ms(DateTime.add(@now, 60, :minute), @now, fifteen) == 45 * 60_000
    assert RunnerToken.refresh_delay_ms(DateTime.add(@now, 16, :minute), @now, fifteen) == 60_000
    assert RunnerToken.refresh_delay_ms(DateTime.add(@now, 10, :minute), @now, fifteen) == 0
    assert RunnerToken.refresh_delay_ms(DateTime.add(@now, -1, :minute), @now, fifteen) == 0
    assert RunnerToken.refresh_delay_ms(nil, @now, fifteen) == 0
  end

  test "a token with more than 15 minutes left is kept until then", ctx do
    pid =
      start_keeper!(ctx,
        initial: credentials(@first, DateTime.add(@now, 20, :minute)),
        req_options: [plug: fn _conn -> flunk("no refresh expected yet") end]
      )

    assert %{next_refresh_ms: 300_000, stopped: false} = RunnerToken.status(pid)
    assert File.read!(Path.join(ctx.dir, "token")) == @first
    refute_received {:refresh_request, _method, _path, _auth}
  end

  test "a token with less than 15 minutes left is refreshed at once, and the files change in place", ctx do
    expires = DateTime.add(@now, 60, :minute)

    log =
      capture_log(fn ->
        pid =
          start_keeper!(ctx,
            initial: credentials(@first, DateTime.add(@now, 10, :minute)),
            req_options: [plug: controller(self(), [{:ok, @second, DateTime.to_iso8601(expires)}])]
          )

        assert_receive {:refresh_request, "POST", "/runner/v1/runs/run-1/github-token", ["Bearer run-token-1"]}, 2_000
        assert eventually(fn -> RunnerToken.status(pid).expires_at == expires end) == :ok
        assert RunnerToken.status(pid).next_refresh_ms == 45 * 60_000
      end)

    assert File.read!(Path.join(ctx.dir, "token")) == @second
    assert File.read!(Path.join([ctx.dir, "gh", "hosts.yml"])) =~ ~s(oauth_token: "#{@second}")
    assert log =~ "GitHub App token refreshed run_id=run-1"
    refute log =~ "ghs_"
  end

  test "a runner that started without a token asks for one", ctx do
    pid = start_keeper!(ctx, initial: nil, req_options: [plug: controller(self(), [{:ok, @first, "2030-01-01T01:00:00Z"}])])

    assert_receive {:refresh_request, "POST", _path, _auth}, 2_000
    assert eventually(fn -> RunnerToken.status(pid).expires_at != nil end) == :ok
    assert File.read!(Path.join(ctx.dir, "token")) == @first
  end

  test "a fenced or finished run stops refreshing; other failures back off", ctx do
    capture_log(fn ->
      pid =
        start_keeper!(ctx,
          initial: credentials(@first, DateTime.add(@now, 30, :minute)),
          req_options: [plug: controller(self(), [{500, %{}}, {429, %{"error" => "rate_limited"}}, {:ok, @second, "2030-01-01T01:00:00Z"}])]
        )

      assert {:error, {:http_status, 500}} = RunnerToken.refresh_now(pid)
      assert RunnerToken.status(pid).next_refresh_ms == 60_000
      assert {:error, {:http_status, 429}} = RunnerToken.refresh_now(pid)
      assert RunnerToken.status(pid).next_refresh_ms == 120_000
      assert :ok = RunnerToken.refresh_now(pid)
      assert File.read!(Path.join(ctx.dir, "token")) == @second
    end)

    for {status, body, reason} <- [
          {409, %{"error" => "stale_epoch"}, :stale_epoch},
          {409, %{"error" => "finished"}, :finished},
          {404, %{"error" => "run_not_found"}, :run_not_found},
          {404, %{"error" => "github_app_not_configured"}, :github_app_not_configured}
        ] do
      ctx = %{ctx | dir: Path.join(ctx.root, "github-#{reason}")}

      capture_log(fn ->
        pid = start_keeper!(ctx, initial: credentials(@first, DateTime.add(@now, 30, :minute)), req_options: [plug: controller(self(), [{status, body}])])
        assert {:error, ^reason} = RunnerToken.refresh_now(pid)
        assert %{stopped: true, next_refresh_ms: nil} = RunnerToken.status(pid)
      end)
    end
  end

  test "malformed answers and unreachable controllers are retried", ctx do
    capture_log(fn ->
      pid = start_keeper!(ctx, initial: credentials(@first, DateTime.add(@now, 30, :minute)), req_options: [plug: controller(self(), [{200, %{"token" => "", "expires_at" => "soon"}}])])
      assert {:error, :invalid_token_response} = RunnerToken.refresh_now(pid)
      send(pid, :unrelated)

      ctx = %{ctx | dir: Path.join(ctx.root, "github-down")}
      pid = start_keeper!(ctx, initial: credentials(@first, DateTime.add(@now, 30, :minute)), controller_url: "http://127.0.0.1:1", req_options: [])
      assert {:error, _reason} = RunnerToken.refresh_now(pid)
      refute RunnerToken.status(pid).stopped
    end)
  end

  test "files are owner-only and the helper holds no secret", ctx do
    start_keeper!(ctx, initial: credentials(@first, DateTime.add(@now, 30, :minute)))

    assert mode(ctx.dir) == 0o700
    assert mode(Path.join(ctx.dir, "token")) == 0o600
    assert mode(Path.join([ctx.dir, "gh", "hosts.yml"])) == 0o600
    assert mode(Path.join(ctx.dir, "git-credential")) == 0o700
    refute File.read!(Path.join(ctx.dir, "git-credential")) =~ "ghs_"
  end

  test "the credential helper always answers with the current token", ctx do
    pid =
      start_keeper!(ctx,
        initial: credentials(@first, DateTime.add(@now, 30, :minute)),
        base_env: %{"GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraHeader", "GIT_CONFIG_VALUE_0" => "Authorization: Basic stale"},
        req_options: [plug: controller(self(), [{:ok, @second, "2030-01-01T02:00:00Z"}])]
      )

    assert_receive {:env_applied, changes}
    assert credential_fill(ctx, changes, "github.com") =~ "username=x-access-token\npassword=#{@first}\n"

    capture_log(fn -> assert :ok = RunnerToken.refresh_now(pid) end)
    assert credential_fill(ctx, changes, "github.com") =~ "password=#{@second}\n"

    # Only the GitHub host is configured; another host never sees the token.
    refute credential_fill(ctx, changes, "example.com") =~ "ghs_"
  end

  test "env_changes/3 swaps the static header for the helper and removes token variables" do
    base = %{
      "GIT_CONFIG_COUNT" => "3",
      "GIT_CONFIG_KEY_0" => "user.name",
      "GIT_CONFIG_VALUE_0" => "Runner",
      "GIT_CONFIG_KEY_1" => "http.https://github.com/.extraheader",
      "GIT_CONFIG_VALUE_1" => "Authorization: Basic stale",
      "GIT_CONFIG_KEY_2" => "core.hooksPath",
      "GIT_CONFIG_VALUE_2" => "/hooks",
      "GH_TOKEN" => "ghs_stale"
    }

    changes = RunnerToken.env_changes(base, "github.com", "/state/runs/r 1/github")
    env = Map.new(changes)

    assert env["GIT_CONFIG_COUNT"] == "4"
    assert {env["GIT_CONFIG_KEY_0"], env["GIT_CONFIG_VALUE_0"]} == {"user.name", "Runner"}
    assert {env["GIT_CONFIG_KEY_1"], env["GIT_CONFIG_VALUE_1"]} == {"core.hooksPath", "/hooks"}
    assert {env["GIT_CONFIG_KEY_2"], env["GIT_CONFIG_VALUE_2"]} == {"credential.https://github.com.helper", ""}
    assert {env["GIT_CONFIG_KEY_3"], env["GIT_CONFIG_VALUE_3"]} == {"credential.https://github.com.helper", "!'/state/runs/r 1/github/git-credential'"}
    assert env["GH_CONFIG_DIR"] == "/state/runs/r 1/github/gh"
    assert env["GIT_TERMINAL_PROMPT"] == "0"

    for name <- ~w(GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN SYMPHONY_GITHUB_TOKEN_EXPIRES_AT) do
      assert Map.fetch!(env, name) == nil
    end

    # A header-only environment shrinks and the stale entries are removed.
    env =
      Map.new(
        RunnerToken.env_changes(
          %{"GIT_CONFIG_COUNT" => "3", "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraHeader", "GIT_CONFIG_KEY_1" => "a.b", "GIT_CONFIG_VALUE_1" => "1"},
          "github.com",
          "/d"
        )
      )

    assert env["GIT_CONFIG_COUNT"] == "3"
    assert env["GIT_CONFIG_KEY_0"] == "a.b"

    env = Map.new(RunnerToken.env_changes(%{"GIT_CONFIG_COUNT" => "4", "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraHeader"}, "github.com", "/d"))
    assert env["GIT_CONFIG_COUNT"] == "2"
    assert Map.fetch!(env, "GIT_CONFIG_KEY_3") == nil
    assert Map.fetch!(env, "GIT_CONFIG_VALUE_2") == nil

    assert Map.new(RunnerToken.env_changes(%{"GIT_CONFIG_COUNT" => "junk"}, "ghe.example.com", "/d"))["GIT_CONFIG_KEY_0"] == "credential.https://ghe.example.com.helper"
  end

  test "everything the keeper writes or the agent might echo is redacted from logs and transcripts", ctx do
    start_keeper!(ctx, initial: credentials(@first, DateTime.add(@now, 30, :minute)))
    header = "Authorization: Basic " <> Base.encode64("x-access-token:" <> @first)

    for text <- [File.read!(Path.join([ctx.dir, "gh", "hosts.yml"])), File.read!(Path.join(ctx.dir, "token")), "GH_TOKEN=#{@first}", "GIT_CONFIG_VALUE_0=#{header}", "password=#{@first}"] do
      refute SymphonyElixir.Redaction.redact(text) =~ @first
      refute SymphonyElixir.Redaction.redact(text) =~ Base.encode64("x-access-token:" <> @first)
    end

    log =
      capture_log(fn ->
        require Logger
        Logger.warning("runner saw password=#{@first}")
      end)

    refute log =~ @first
    assert log =~ "[REDACTED]"
  end

  describe "initial_credentials/2" do
    test "reads and deletes a process runner's github-token.json", ctx do
      spec_path = Path.join(ctx.root, "spec.json")
      token_path = RunSpec.github_token_path(spec_path)
      File.write!(token_path, Jason.encode!(%{"token" => @first, "expires_at" => "2030-01-01T01:00:00Z", "host" => "github.com"}))

      assert %{token: @first, expires_at: ~U[2030-01-01 01:00:00Z]} = RunnerToken.initial_credentials(spec_path, %{"GH_TOKEN" => @second})
      refute File.exists?(token_path)
    end

    test "falls back to a pod's Secret environment, else nothing", ctx do
      spec_path = Path.join(ctx.root, "spec.json")
      env = %{"GH_TOKEN" => @second, "SYMPHONY_GITHUB_TOKEN_EXPIRES_AT" => "2030-01-01T01:00:00Z"}

      assert %{token: @second} = RunnerToken.initial_credentials(spec_path, env)
      # A host GH_TOKEN without the controller's expiry is not a run token.
      assert RunnerToken.initial_credentials(spec_path, %{"GH_TOKEN" => @second}) == nil
      assert RunnerToken.initial_credentials(spec_path, %{"GH_TOKEN" => @second, "SYMPHONY_GITHUB_TOKEN_EXPIRES_AT" => "later"}) == nil
      File.write!(RunSpec.github_token_path(spec_path), "not json")
      assert RunnerToken.initial_credentials(spec_path, %{}) == nil
    end
  end

  test "an unwritable directory stops the keeper", ctx do
    File.write!(Path.join(ctx.root, "file"), "")
    Process.flag(:trap_exit, true)

    assert {:error, {:github_token_files, _reason}} =
             RunnerToken.start_link(name: nil, run_id: "r", controller_url: "http://c", run_token: "t", host: "github.com", dir: Path.join([ctx.root, "file", "github"]), apply_env: fn _ -> :ok end)
  end

  test "GitHubApp.env_pairs leaves the agent to the keeper's environment", ctx do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    {:ok, settings} =
      Schema.parse(%{"tracker" => %{"kind" => "memory", "projects" => [%{"slug" => "p", "repo" => "octo/repo"}]}, "github_app" => %{"app_id" => 1, "private_key" => pem, "installation_id" => 1}})

    {:ok, pid} =
      RunnerToken.start(
        name: RunnerToken,
        run_id: "r",
        controller_url: "http://c",
        run_token: "t",
        host: "github.com",
        dir: ctx.dir,
        clock: fn -> @now end,
        initial: credentials(@first, DateTime.add(@now, 30, :minute)),
        apply_env: fn _ -> :ok end
      )

    assert RunnerToken.active?()
    assert GitHubApp.env_pairs(%{project_slug: "p"}, settings: settings) == []
    assert :ok = RunnerToken.stop()
    refute Process.alive?(pid)
    refute RunnerToken.active?()
    assert :ok = RunnerToken.stop()
  end

  describe "Runner.run" do
    setup ctx do
      Support.setup_runs!(ctx.root)
      endpoint = Support.start_endpoint!()

      names =
        ["GIT_CONFIG_COUNT", "GH_CONFIG_DIR", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GIT_TERMINAL_PROMPT", "SYMPHONY_GITHUB_TOKEN_EXPIRES_AT"] ++
          for(i <- 0..5, kind <- ["KEY", "VALUE"], do: "GIT_CONFIG_#{kind}_#{i}")

      previous_env = Map.new(names, &{&1, System.get_env(&1)})
      previous_state_root = Application.get_env(:symphony_elixir, :state_root)
      Application.put_env(:symphony_elixir, :state_root, Path.join(ctx.root, "state"))

      on_exit(fn ->
        Enum.each(previous_env, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)

        if previous_state_root, do: Application.put_env(:symphony_elixir, :state_root, previous_state_root), else: Application.delete_env(:symphony_elixir, :state_root)
        Application.delete_env(:symphony_elixir, :runner_github_token_options)
      end)

      %{endpoint: endpoint}
    end

    test "the agent's git and gh get the run's token from files, not a static environment", ctx do
      issue_id = "issue-runner-gh"
      run_id = "run-runner-gh"
      identifier = "MT-RUNNER-GH"
      issue = Support.issue_fixture(issue_id, identifier)
      credential_out = Path.join(ctx.root, "credential.out")
      env_out = Path.join(ctx.root, "env.out")
      fake = Support.write_fake_claude_launcher!(ctx.root)
      agent = Path.join(ctx.root, "agent.sh")

      File.write!(agent, """
      #!/bin/sh
      printf 'protocol=https\\nhost=github.com\\n\\n' | GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git credential fill > '#{credential_out}' 2>&1
      env > '#{env_out}'
      exec '#{fake}' "$@"
      """)

      File.chmod!(agent, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        agent_backend: "claude",
        workspace_root: Path.join(ctx.root, "workspaces"),
        claude_command: agent,
        # The wrapper runs git before the fake agent answers; a cold git can be slow.
        claude_read_timeout_ms: 30_000,
        max_turns: 1
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      record = Support.record_run!(issue_id, run_id, identifier: identifier, backend: "claude", epoch: 1)
      ExUnit.Callbacks.stop_supervised(SymphonyElixir.RunnerCommandPoller.registry())
      # A host credential the runner must not pass on.
      System.put_env("GH_TOKEN", "ghp_" <> String.duplicate("h", 36))

      spec = %RunSpec{
        run_id: run_id,
        epoch: record.epoch,
        attempt: 0,
        issue: issue,
        backend: "claude",
        controller_url: ctx.endpoint.url,
        token: RunToken.sign(run_id, record.epoch),
        github_host: "github.com"
      }

      assert {:ok, spec_path} = RunSpec.write(spec)
      File.write!(RunSpec.github_token_path(spec_path), Jason.encode!(%{"token" => @first, "expires_at" => "2999-01-01T00:00:00Z", "host" => "github.com"}))

      assert :ok = SymphonyElixir.Runner.run(spec_path)
      assert_receive {:orchestrator_message, {:run_finished, ^issue_id, ^run_id, "normal"}}, 5_000

      assert File.read!(credential_out) =~ "password=#{@first}"
      agent_env = File.read!(env_out)
      refute agent_env =~ "GH_TOKEN="
      refute agent_env =~ "ghs_"
      refute agent_env =~ "ghp_"
      assert agent_env =~ "GH_CONFIG_DIR=" <> Path.join(RunSpec.dir(run_id), "github/gh")
      refute File.exists?(RunSpec.github_token_path(spec_path))
      refute RunnerToken.active?()
      SymphonyElixir.RunnerCommands.reset()
    end
  end

  # Applied as shell exports: an empty value (the helper reset) must stay set,
  # which System.cmd's env option would drop.
  defp credential_fill(ctx, changes, host) do
    exports =
      Enum.map_join(changes, "\n", fn
        {name, nil} -> "unset #{name}"
        {name, value} -> "export #{name}=#{shell_quote(value)}"
      end)

    script = exports <> "\nprintf 'protocol=https\\nhost=#{host}\\n\\n' | git credential fill"
    env = [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}, {"HOME", ctx.root}, {"GIT_ASKPASS", nil}, {"SSH_ASKPASS", nil}]
    {output, _status} = System.cmd("sh", ["-c", script], env: env, stderr_to_stdout: true)
    output
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> Process.sleep(10) && do_wait(fun, deadline)
    end
  end
end
