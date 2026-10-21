defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    config_store =
      case Application.get_env(:symphony_elixir, :startup_mode, :legacy) do
        :global -> SymphonyElixir.SymphonyConfigStore
        _ -> SymphonyElixir.WorkflowStore
      end

    children =
      case Application.get_env(:symphony_elixir, :app_mode, :controller) do
        :runner -> runner_children(config_store)
        _ -> controller_children(config_store)
      end

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  # The controller: the orchestrator, dashboard, web endpoint and every store.
  defp controller_children(config_store) do
    [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      # Postgres (repo and migrations) when SYMPHONY_DATABASE_URL is set; before every store.
      SymphonyElixir.StateStore.Supervisor,
      config_store,
      SymphonyElixir.UsageLedger,
      SymphonyElixir.SessionStore,
      SymphonyElixir.Transcript,
      SymphonyElixir.SessionHistory,
      {Registry, keys: :unique, name: SymphonyElixir.AgentInbox.Registry},
      SymphonyElixir.AgentInbox,
      SymphonyElixir.Pricing,
      SymphonyElixir.Observability.Cache,
      SymphonyElixir.Factory.Store,
      SymphonyElixir.Users,
      SymphonyElixir.Auth,
      SymphonyElixir.McpTokens,
      SymphonyElixir.ProjectRoutes,
      # Creates any missing Linear labels the flows need, once, in the background.
      SymphonyElixir.LabelSync,
      # Serializes repo cache syncs; the refresher below uses the same lock.
      SymphonyElixir.RepoCacheLock,
      # Warms project repo caches so agent starts rarely fetch from GitHub.
      SymphonyElixir.RepoCacheRefresher,
      SymphonyElixir.RunnerCommands,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard,
      SymphonyElixir.ClaudeCode.RateLimitPoller
    ]
  end

  # A runner (docs/durable-runs.md, step 3): no orchestrator, HTTP server,
  # dashboard, ledger or controller-side stores. Only what AgentRunner.run/3
  # and its backends touch while the run talks to the controller over
  # RunHost.Remote:
  #
  #   * PubSub — kept because the rest of the codebase expects the name; a
  #     run does not publish, but a started backend may.
  #   * TaskSupervisor — the steering command poller (and workspace helpers)
  #     start tasks under it.
  #   * StateStore.Supervisor — the Postgres state backend and migrations,
  #     needed before any config or factory read when SYMPHONY_DATABASE_URL is
  #     set.
  #   * config store — AgentRunner -> IssueConfig.resolve/Config.settings!/
  #     AgentRoute needs the same symphony.yml/WORKFLOW.md as the controller.
  #   * Factory.Store — IssueStage/AgentRoute/StageResult resolve the issue's
  #     flow from it, so stages and routing match the controller's.
  #   * RunOutbox — the sender for the run's fire-and-forget events.
  #   * command poller Registry — lets inbox_register find and stop the poller
  #     for an issue.
  #
  # Deliberately absent: Orchestrator, HttpServer, StatusDashboard,
  # UsageLedger, SessionStore, Transcript, SessionHistory, AgentInbox and Pricing (their work
  # happens in the controller through RunHost.Remote), Users/Auth/McpTokens
  # (the runner authenticates with its run token), LabelSync and
  # RateLimitPoller.
  defp runner_children(config_store) do
    [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.StateStore.Supervisor,
      config_store,
      SymphonyElixir.Factory.Store,
      # The runner creates its workspace from the repo cache, under the cache lock.
      SymphonyElixir.RepoCacheLock,
      SymphonyElixir.RunOutbox,
      {Registry, keys: :unique, name: SymphonyElixir.RunnerCommandPoller.registry()}
    ]
  end

  @impl true
  def stop(_state) do
    if Application.get_env(:symphony_elixir, :app_mode, :controller) != :runner do
      SymphonyElixir.StatusDashboard.render_offline_status()
    end

    :ok
  end
end
