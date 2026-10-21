defmodule SymphonyElixir.RunLauncher do
  @moduledoc """
  How the orchestrator starts and stops an agent run.

  A launcher starts the run's function and returns both the pid the
  orchestrator monitors and a string reference that names the run across
  controller restarts. `alive?/1` answers whether a reference from a previous
  boot still has a live run, and `stop/1` ends it.

  Today runs are in-process: `SymphonyElixir.RunLauncher.Local` starts each run
  as a task under `SymphonyElixir.TaskSupervisor`, so a controller restart
  kills the run and its reference stops being alive. A later step adds a
  launcher that starts runs as separate OS processes, whose `alive?/1` lets a
  restarted controller adopt them; see `docs/durable-runs.md`.
  """

  @doc """
  Starts a run. Returns the pid to monitor and the run's reference, or an
  error when it could not be started.
  """
  @callback start(fun :: (-> any()), keyword()) :: {:ok, pid(), ref :: String.t()} | {:error, term()}

  @doc "Whether the run a reference names is still alive."
  @callback alive?(ref :: String.t()) :: boolean()

  @doc "Stops the run a reference names."
  @callback stop(ref :: String.t()) :: :ok

  @doc "The configured launcher; `SymphonyElixir.RunLauncher.Local` unless set."
  @spec launcher() :: module()
  def launcher, do: Application.get_env(:symphony_elixir, :run_launcher, SymphonyElixir.RunLauncher.Local)
end
