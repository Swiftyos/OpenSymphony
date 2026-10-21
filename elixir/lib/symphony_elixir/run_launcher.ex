defmodule SymphonyElixir.RunLauncher do
  @moduledoc """
  How the orchestrator starts and stops an agent run.

  A launcher starts the run's function and returns both the pid the
  orchestrator monitors and a string reference that names the run across
  controller restarts. `alive?/1` answers whether a reference from a previous
  boot still has a live run, and `stop/1` ends it.

  `SymphonyElixir.RunLauncher.Local` (the default) starts each run as a task
  under `SymphonyElixir.TaskSupervisor`, so a controller restart kills the
  run. `SymphonyElixir.RunLauncher.Process` starts it as a separate OS process
  and `SymphonyElixir.RunLauncher.Kubernetes` as a runner pod; their `alive?/1`
  (or `status/1`) lets a restarted controller adopt the run. See
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

  @typedoc """
  What a launcher can tell about a run beyond `alive?/1`:

    * `:alive` — the run is still going.
    * `{:gone, reason}` — it has ended; `reason` (or nil) is what to exit with
      when no `finished` event arrives, such as `{:pod_failed, "OOMKilled"}`.
    * `{:unknown, reason}` — it could not be checked (a transient API error).
    * `{:unauthorized, reason}` — the check was refused (401/403).
  """
  @type status :: :alive | {:gone, term()} | {:unknown, term()} | {:unauthorized, term()}

  @doc "The run's status. Optional: a launcher without it is checked with `alive?/1`."
  @callback status(ref :: String.t()) :: status()

  @doc """
  Frees what an ended run no longer needs (its credentials) while keeping what
  is kept for debugging (a pod's logs). Optional.
  """
  @callback release(ref :: String.t()) :: :ok

  @doc """
  The controller URL a run started by this launcher reaches the controller at.
  Optional: the default is the controller's bound loopback address.
  """
  @callback controller_url(settings :: SymphonyElixir.Config.Schema.t()) :: String.t() | nil

  @doc """
  The OTLP endpoint and protocol runs started by this launcher export to
  instead of the configured telemetry endpoints (a runner pod cannot reach the
  controller host's collector), or nil to use those. Optional.
  """
  @callback otlp_override(settings :: SymphonyElixir.Config.Schema.t()) ::
              %{endpoint: String.t(), protocol: String.t()} | nil

  @optional_callbacks status: 1, release: 1, controller_url: 1, otlp_override: 1

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

  @doc """
  A run's status through its launcher: `status/1` when the launcher has it,
  else `:alive` or `{:gone, nil}` from `alive?/1`. A launcher that raises (or
  is not loaded) reports the run gone.
  """
  @spec status(module(), String.t()) :: status()
  def status(launcher, ref) when is_atom(launcher) do
    cond do
      not Code.ensure_loaded?(launcher) -> {:gone, nil}
      function_exported?(launcher, :status, 1) -> launcher.status(ref)
      function_exported?(launcher, :alive?, 1) and launcher.alive?(ref) -> :alive
      true -> {:gone, nil}
    end
  rescue
    _error -> {:gone, nil}
  end

  @doc "Releases an ended run's resources through its launcher, when it has `release/1`."
  @spec release(module(), String.t()) :: :ok
  def release(launcher, ref) when is_atom(launcher) do
    if Code.ensure_loaded?(launcher) and function_exported?(launcher, :release, 1) do
      launcher.release(ref)
    end

    :ok
  end

  @doc "The controller URL for runs this launcher starts (see `c:controller_url/1`)."
  @spec controller_url(module(), SymphonyElixir.Config.Schema.t()) :: String.t() | nil
  def controller_url(launcher, settings) when is_atom(launcher) do
    if Code.ensure_loaded?(launcher) and function_exported?(launcher, :controller_url, 1) do
      launcher.controller_url(settings)
    else
      SymphonyElixir.RunSpec.controller_url()
    end
  end

  @doc "The OTLP override for runs this launcher starts (see `c:otlp_override/1`)."
  @spec otlp_override(module(), SymphonyElixir.Config.Schema.t()) :: %{endpoint: String.t(), protocol: String.t()} | nil
  def otlp_override(launcher, settings) when is_atom(launcher) do
    if Code.ensure_loaded?(launcher) and function_exported?(launcher, :otlp_override, 1),
      do: launcher.otlp_override(settings)
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
            :kubernetes -> SymphonyElixir.RunLauncher.Kubernetes
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
