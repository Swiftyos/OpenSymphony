defmodule SymphonyElixir.RunLauncher do
  @moduledoc """
  How the orchestrator starts and stops an agent run.

  A launcher starts the run's function and returns both the pid the
  orchestrator monitors and a string reference that names the run across
  controller restarts. `alive?/1` answers whether a reference from a previous
  boot still has a live run, and `stop/1` ends it.

  `SymphonyElixir.RunLauncher.Local` (the default) starts each run as a task
  under `SymphonyElixir.TaskSupervisor`, so a controller restart kills the
  run. `SymphonyElixir.RunLauncher.Process` starts it as a separate OS process,
  whose `alive?/1` lets a restarted controller adopt it; see
  `docs/durable-runs.md`.
  """

  @doc """
  Starts a run. Returns the pid to monitor and the run's reference, or an
  error when it could not be started.
  """
  @callback start(fun :: (-> any()), keyword()) :: {:ok, pid(), ref :: String.t()} | {:error, term()}

  @doc """
  Starts a run from its spec, for launchers that own a separate OS process.
  Optional: the local launcher keeps implementing only `start/2`.
  """
  @callback start_process(spec :: SymphonyElixir.RunSpec.t(), keyword()) ::
              {:ok, pid(), ref :: String.t()} | {:error, term()}

  @optional_callbacks start_process: 2

  @doc "Whether the run a reference names is still alive."
  @callback alive?(ref :: String.t()) :: boolean()

  @doc "Stops the run a reference names."
  @callback stop(ref :: String.t()) :: :ok

  @doc """
  Starts a run through the given launcher. A launcher that implements
  `start_process/2` receives the run spec; every other launcher receives the
  run function exactly as before.
  """
  @spec start(module(), (-> any()) | map(), keyword()) ::
          {:ok, pid(), ref :: String.t()} | {:error, term()}
  def start(launcher, fun_or_request, opts \\ []) when is_atom(launcher) do
    if Code.ensure_loaded?(launcher) and function_exported?(launcher, :start_process, 2) do
      launcher.start_process(extract_spec(fun_or_request), Keyword.put(opts, :fun, extract_fun(fun_or_request)))
    else
      launcher.start(extract_fun(fun_or_request), opts)
    end
  end

  @doc "The configured launcher; `SymphonyElixir.RunLauncher.Local` unless set."
  @spec launcher() :: module()
  def launcher do
    case Application.get_env(:symphony_elixir, :run_launcher) do
      launcher when is_atom(launcher) and not is_nil(launcher) ->
        launcher

      _ ->
        try do
          case SymphonyElixir.Config.agent_launcher() do
            :process -> SymphonyElixir.RunLauncher.Process
            _ -> SymphonyElixir.RunLauncher.Local
          end
        rescue
          _error -> SymphonyElixir.RunLauncher.Local
        end
    end
  end

  defp extract_spec(%{spec: %SymphonyElixir.RunSpec{} = spec}), do: spec
  defp extract_spec(%SymphonyElixir.RunSpec{} = spec), do: spec
  defp extract_spec(spec), do: spec

  defp extract_fun(%{fun: fun}) when is_function(fun, 0), do: fun
  defp extract_fun(fun) when is_function(fun, 0), do: fun
  defp extract_fun(_fun_or_request), do: fn -> :ok end
end
