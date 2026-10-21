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

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      # Postgres (repo and migrations) when SYMPHONY_DATABASE_URL is set; before every store.
      SymphonyElixir.StateStore.Supervisor,
      config_store,
      SymphonyElixir.UsageLedger,
      SymphonyElixir.SessionStore,
      SymphonyElixir.Transcript,
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
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard,
      SymphonyElixir.ClaudeCode.RateLimitPoller
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
