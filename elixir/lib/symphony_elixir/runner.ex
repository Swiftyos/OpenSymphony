defmodule SymphonyElixir.Runner do
  @moduledoc """
  The `symphony runner <spec.json>` entrypoint, without the CLI around it.

  It reads the run spec, starts the reduced runner application (see
  `SymphonyElixir.Application`), runs the issue through `AgentRunner.run/3`
  with `SymphonyElixir.RunHost.Remote`, then posts a `finished` event and
  flushes the outbox before returning: it waits (up to
  `agent.runner_finish_flush_ms`, an hour by default) until the controller has
  acknowledged the event or fenced the run. The CLI maps `:ok` to exit status 0 and
  an error to 1. Everything the run does reaches the controller through the
  runner protocol; see `docs/durable-runs.md`.
  """

  require Logger

  alias SymphonyElixir.Accounts
  alias SymphonyElixir.AgentRoute
  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Capacity.UsageReporter
  alias SymphonyElixir.Config
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixir.GitHubApp.RunnerToken
  alias SymphonyElixir.IssueConfig
  alias SymphonyElixir.RunHost.Remote
  alias SymphonyElixir.RunnerCommandPoller
  alias SymphonyElixir.RunOutbox
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.RunTrace
  alias SymphonyElixir.Sandbox
  alias SymphonyElixir.Telemetry
  alias SymphonyElixir.TraceExporter

  @doc "Runs the spec, returning `:ok` or an error; never raises for a failed run."
  @spec run(Path.t()) :: :ok | {:error, term()}
  def run(spec_path) do
    spec_path = Path.expand(spec_path)

    with {:ok, spec} <- RunSpec.read(spec_path),
         :ok <- start_application() do
      started = ensure_runner_processes()
      # A pod's collector replaces the configured endpoints for this node.
      :ok = Telemetry.put_otlp_override(RunTrace.spec_otlp_override(spec.telemetry))

      try do
        with_github_token(spec, spec_path, fn -> run_spec(spec) end)
      after
        Telemetry.put_otlp_override(nil)
        stop_started(started)
      end
    end
  end

  # With `github_app` on the controller, the run's installation token is kept
  # fresh for the whole run, and git and `gh` read it from files (see
  # `SymphonyElixir.GitHubApp.RunnerToken`). Without it nothing changes.
  defp with_github_token(%RunSpec{github_host: host} = spec, spec_path, fun) when is_binary(host) and host != "" do
    opts = [
      run_id: spec.run_id,
      controller_url: spec.controller_url,
      run_token: spec.token,
      host: host,
      initial: RunnerToken.initial_credentials(spec_path)
    ]

    case RunnerToken.start(Keyword.merge(opts, Application.get_env(:symphony_elixir, :runner_github_token_options, []))) do
      {:ok, pid} ->
        try do
          fun.()
        after
          RunnerToken.stop(pid)
        end

      {:error, reason} ->
        Logger.warning("GitHub App token keeper did not start run_id=#{spec.run_id} reason=#{inspect(reason, limit: 5)}")
        fun.()
    end
  end

  defp with_github_token(_spec, _spec_path, fun), do: fun.()

  defp start_application do
    Application.put_env(:symphony_elixir, :app_mode, :runner)

    case Application.ensure_all_started(:symphony_elixir) do
      {:ok, _apps} -> :ok
      {:error, {_app, reason}} -> {:error, reason}
    end
  end

  # In a real runner these are children of the runner application. A test (or
  # any caller giving the app a different start mode first) may not have them,
  # so start the missing ones and stop only those here.
  defp ensure_runner_processes do
    [
      start_missing(Task.Supervisor, fn -> Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor) end),
      start_missing(RunOutbox, fn -> RunOutbox.start_link([]) end),
      start_missing(TraceExporter, fn -> TraceExporter.start_link([]) end),
      start_missing(RunnerCommandPoller.registry(), fn ->
        Registry.start_link(keys: :unique, name: RunnerCommandPoller.registry())
      end)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp start_missing(name, starter) do
    if Process.whereis(name) do
      nil
    else
      case starter.() do
        {:ok, pid} -> pid
        _error -> nil
      end
    end
  end

  defp stop_started(started) do
    Enum.each(started, fn pid ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _reason -> :ok
        end
      end
    end)
  end

  # A runner pod can't read the controller's flows, so the run brings its own.
  defp seed_flow(%RunSpec{flow: %{"scope" => scope, "definition" => %{} = definition}, run_id: run_id}) do
    case Store.seed(scope, definition) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Run flow not seeded run_id=#{run_id} scope=#{scope} reason=#{inspect(reason, limit: 5)}")
    end
  end

  defp seed_flow(_spec), do: :ok

  defp run_spec(%RunSpec{} = spec) do
    :ok =
      RunOutbox.configure(
        run_id: spec.run_id,
        base_url: spec.controller_url,
        token: spec.token,
        dir: RunSpec.dir(spec.run_id)
      )

    host = %Remote{
      base_url: spec.controller_url,
      run_id: spec.run_id,
      token: spec.token,
      outbox: Process.whereis(RunOutbox)
    }

    reporter = start_usage_reporter(host)

    try do
      run_with_host(spec, host)
    after
      UsageReporter.stop(reporter)
    end
  end

  defp run_with_host(%RunSpec{} = spec, %Remote{} = host) do
    seed_flow(spec)
    issue = RunSpec.to_issue(spec)
    account = resolve_account(spec.account)
    trace = RunTrace.from_spec(spec)

    case runner_issue_config(spec, issue) do
      {:ok, issue_config} ->
        route = runner_route(spec, issue, issue_config)

        # The run gets its own process: the agent CLIs are ports linked to it, and
        # a port that dies (an agent that exits at once gives :epipe) would otherwise
        # take the runner down before it could report the run's end.
        task =
          Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
            AgentRunner.run(issue, nil,
              run_host: host,
              attempt: spec.attempt,
              worker_host: spec.worker_host,
              account: account,
              route: route,
              issue_config: issue_config,
              workspace_root: spec.workspace_root,
              trace: trace,
              # A runner without the repo cache (a pod) clones from the controller's mirror.
              git_mirror: spec
            )
          end)

        try do
          case Task.yield(task, :infinity) do
            {:ok, :ok} ->
              finish(host, "normal")
              :ok

            {:exit, reason} ->
              message = exit_message(reason)
              finish(host, message)
              {:error, message}
          end
        after
          flush_finished()
          flush_spans()
        end

      {:error, reason} ->
        message = "runner config failed: #{inspect(reason, limit: 10)}"
        finish(host, message)
        flush_finished()
        flush_spans()
        {:error, message}
    end
  end

  # The run's agent_run span is queued as the run ends; the process exits soon
  # after, so it is exported now (bounded by the exporter's own timeouts).
  defp flush_spans, do: TraceExporter.flush(Config.settings!().telemetry.span_export_timeout_ms * 2)

  # The run must not end with its `finished` event unacknowledged: a lost
  # finished turns a completed run into an interrupted one. The outbox keeps
  # retrying with backoff while the controller is down; the wait ends when
  # everything is acked, when the outbox is fenced (409/404 stop it), or after
  # `agent.runner_finish_flush_ms`.
  defp flush_finished, do: RunOutbox.flush(finish_flush_ms())

  defp finish_flush_ms, do: Config.agent_runner_finish_flush_ms()

  # The spec carries everything the controller resolved at dispatch: the
  # project route, its workspace root and the backend/effort. The runner uses
  # those instead of looking the route up again, so a route added through MCP
  # or a dashboard stage control still works when this process is a fresh BEAM.
  defp runner_issue_config(%RunSpec{} = spec, issue) do
    IssueConfig.resolve(issue,
      project_route: spec.project_route,
      workspace_root: spec.workspace_root
    )
  end

  defp runner_route(%RunSpec{route: %{} = route}, _issue, issue_config) do
    %AgentRoute{
      backend: route_value(route, :backend) || issue_config.settings.agent.backend,
      effort: route_value(route, :effort),
      warnings: route_value(route, :warnings) || []
    }
  end

  defp runner_route(%RunSpec{}, issue, issue_config), do: AgentRoute.resolve(issue, issue_config.settings)

  defp route_value(route, key), do: Map.get(route, key) || Map.get(route, Atom.to_string(key))

  defp exit_message({%{__exception__: true} = exception, _stacktrace}), do: Exception.message(exception)
  defp exit_message(reason), do: inspect(reason, limit: 10)

  # The spec names an account by id; the runner reloads the credential from the
  # same config so tokens refreshed on the controller are picked up.
  defp resolve_account(nil), do: nil

  defp resolve_account(%{backend: backend, id: id}) when is_binary(backend) and is_binary(id) do
    case Accounts.get(backend, id) do
      {:ok, account} ->
        account

      {:error, reason} ->
        Logger.warning("Runner could not reload account backend=#{backend} id=#{id} reason=#{inspect(reason, limit: 5)}")
        nil
    end
  rescue
    error ->
      Logger.warning("Runner could not reload account backend=#{backend} id=#{id} reason=#{inspect(error, limit: 5)}")
      nil
  end

  # The runner measures itself for the controller's per-run CPU and memory
  # series. In a docker sandbox the agent runs in a container outside the
  # runner's cgroup and process tree, and the controller's `stats` call
  # already sees it, so the runner does not report.
  defp start_usage_reporter(%Remote{} = host) do
    settings = Config.settings!()
    reporting? = is_pid(host.outbox) and not Sandbox.enabled?(settings)
    interval_ms = if reporting?, do: settings.capacity.sample_interval_ms, else: 0
    UsageReporter.start(outbox: host.outbox, run_id: host.run_id, interval_ms: interval_ms)
  end

  defp finish(%Remote{} = host, reason) when is_binary(reason) do
    RunOutbox.append(host.outbox, "finished", %{run_id: host.run_id, reason: reason})
    :ok
  end
end
