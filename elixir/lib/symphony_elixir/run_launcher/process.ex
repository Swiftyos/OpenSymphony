defmodule SymphonyElixir.RunLauncher.Process do
  @moduledoc """
  Starts each run as a separate OS process: `symphony runner <spec.json>`.

  The spec is written to the run's directory, then the configured command
  template is run detached. The command must return at once: the default
  `setsid` template backgrounds the runner and prints its pid, while the VM's
  `systemd-run --user --unit=...` template returns after starting the unit.

  A backgrounded runner gets stdin from `/dev/null` and its stdout and stderr
  appended to `<run dir>/runner.log`. A template that starts with `setsid` runs
  through `perl -e 'setpgrp; exec @ARGV'` instead on a host without `setsid`
  (macOS), so the runner still leads its own process group. If the runner is
  gone at its watcher's startup check (1s), the watcher exits
  `{:launch_failed, log_tail}`; `start_process/2` itself returns as soon as the
  runner is spawned.

  The reference records how to check and stop the run:

    * `process:<os pid>:<start time>` — `kill -0` and `ps -o lstart=`, so a
      reused pid is not mistaken for the run, and a process-group `TERM` then
      `KILL`.
    * `systemd:<unit>` — `systemctl --user is-active`, and `systemctl --user stop`.

  `stop/1` waits up to 20s for the process to exit; callers that must not block
  (the orchestrator) run it in a task.

  With `github_app`, the run's installation token (home repo only) is minted
  before the runner starts and written owner-only to `github-token.json` next
  to the spec (`SymphonyElixir.GitHubApp.RunCredentials`); the runner takes it
  from there and refreshes it through the controller. The runner is started
  without `GITHUB_APP_PRIVATE_KEY` in its environment.

  A `SymphonyElixir.RunWatcher` is started for the run; the orchestrator
  monitors that watcher. See `docs/durable-runs.md`.
  """

  @behaviour SymphonyElixir.RunLauncher

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubApp.RunCredentials
  alias SymphonyElixir.RunLauncher.Process.ProcessTable
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.RunWatcher

  @kill_grace_ms 10_000
  @poll_ms 100
  # The start time of a runner already gone when its pid was read.
  @gone_start "gone"
  @setsid_fallback "perl -e 'setpgrp; exec @ARGV'"
  # The runner never gets the App private key, even on the controller's host.
  @runner_env [{"GITHUB_APP_PRIVATE_KEY", nil}]

  @impl true
  def start(%RunSpec{} = spec, opts), do: start_process(spec, opts)

  def start(%{spec: %RunSpec{} = spec} = request, opts) do
    start_process(spec, Keyword.put_new(opts, :fun, Map.get(request, :fun)))
  end

  def start(fun, _opts) when is_function(fun, 0), do: {:error, :missing_run_spec}
  def start(_other, _opts), do: {:error, :missing_run_spec}

  @impl true
  def start_process(%RunSpec{} = spec, opts \\ []) do
    {spec, github} = github_credentials(spec, opts)

    with {:ok, spec_path} <- RunSpec.write(spec),
         :ok <- RunCredentials.write_file(spec_path, github),
         {:ok, command} <- render_command(command_template(opts), spec, spec_path, opts),
         {:ok, ref} <- spawn_process(detach_command(command, opts), spec.run_id),
         {:ok, watcher_pid} <-
           RunWatcher.start(
             %{run_id: spec.run_id, issue_id: Map.get(spec.issue || %{}, :id)},
             ref,
             Keyword.merge(
               [launcher: __MODULE__] ++ startup_check(ref, spec.run_id),
               Keyword.take(opts, [:poll_interval_ms, :lost_grace_ms, :startup_check_ms])
             )
           ) do
      Logger.info("Started process run run_id=#{spec.run_id} ref=#{ref} watcher=#{inspect(watcher_pid)}")
      {:ok, watcher_pid, ref}
    else
      {:error, reason} = error ->
        Logger.error("Unable to start process run run_id=#{Map.get(spec, :run_id)} reason=#{inspect(reason)}")
        error
    end
  end

  # Watchers check every run every few seconds: the shared `ps` snapshot
  # (`ProcessTable`) answers for a runner it shows alive, and only the rest
  # are checked with their own `kill -0` and `ps`.
  @impl true
  def alive?("process:" <> rest) do
    case parse_process_ref(rest) do
      {:ok, pid, start} -> ProcessTable.alive?(pid, start) == true or process_alive?(pid, start)
      :error -> false
    end
  end

  def alive?("systemd:" <> unit) when unit != "" do
    case System.cmd("systemctl", ["--user", "is-active", unit], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) == "active"
      _ -> false
    end
  end

  def alive?(_ref), do: false

  @impl true
  def stop(ref), do: stop(ref, @kill_grace_ms)

  @doc "Stops a reference, waiting at most `timeout_ms` before sending KILL."
  @spec stop(String.t(), non_neg_integer()) :: :ok
  def stop("process:" <> rest, timeout_ms) do
    case parse_process_ref(rest) do
      {:ok, pid, start} -> stop_process_group(pid, start, timeout_ms)
      :error -> :ok
    end
  end

  def stop("systemd:" <> unit, _timeout_ms) when unit != "" do
    System.cmd("systemctl", ["--user", "stop", unit], stderr_to_stdout: true)
    :ok
  end

  def stop(_ref, _timeout_ms), do: :ok

  @doc "The command template this launcher will use, with placeholders unexpanded."
  @spec command_template(keyword()) :: String.t()
  def command_template(opts \\ []) do
    Keyword.get(opts, :command) ||
      Application.get_env(:symphony_elixir, :run_runner_command) ||
      safe_configured_command()
  end

  @doc "Finds the running `symphony` binary: the escript itself, or `SYMPHONY_BIN`."
  @spec symphony_binary(keyword()) :: String.t() | nil
  def symphony_binary(opts \\ []) do
    case Keyword.fetch(opts, :symphony) do
      {:ok, symphony} -> symphony
      :error -> escript_name() || System.get_env("SYMPHONY_BIN")
    end
  end

  defp github_credentials(spec, opts) do
    settings =
      case Keyword.get_lazy(opts, :settings, &Config.settings/0) do
        %Schema{} = settings -> settings
        {:ok, %Schema{} = settings} -> settings
        _other -> nil
      end

    if settings, do: RunCredentials.attach(spec, settings, Keyword.get(opts, :github_app, [])), else: {spec, nil}
  end

  defp safe_configured_command do
    Config.agent_runner_command()
  rescue
    _error -> Config.default_runner_command()
  end

  defp escript_name do
    name = :escript.script_name() |> to_string()

    if File.regular?(Path.expand(name)), do: name
  end

  defp render_command(template, %RunSpec{} = spec, spec_path, opts) when is_binary(template) do
    symphony = symphony_binary(opts)

    values = %{
      "{run_id}" => shell_escape(spec.run_id),
      "{spec}" => shell_escape(spec_path),
      "{symphony}" => shell_escape(symphony)
    }

    if String.contains?(template, "{symphony}") and is_nil(symphony) do
      {:error, :missing_symphony_binary}
    else
      command =
        Enum.reduce(values, template, fn
          {_placeholder, nil}, command -> command
          {placeholder, value}, command -> String.replace(command, placeholder, value)
        end)

      {:ok, command}
    end
  end

  defp render_command(_template, _spec, _spec_path, _opts), do: {:error, :invalid_runner_command}

  # The default template's `setsid` is Linux (util-linux); where it is missing
  # the same group-leader detach is done with perl, which macOS ships. `setsid`
  # may follow `NAME=value` assignments.
  @setsid_prefix ~r/^(\s*(?:\w+=\S*\s+)*)setsid\s+/

  defp detach_command(command, opts) do
    if Regex.match?(@setsid_prefix, command) and not setsid_available?(opts) do
      Regex.replace(@setsid_prefix, command, "\\1" <> @setsid_fallback <> " ")
    else
      command
    end
  end

  defp setsid_available?(opts) do
    Keyword.get_lazy(opts, :setsid_available, fn -> System.find_executable("setsid") != nil end)
  end

  defp spawn_process(command, run_id) do
    if systemd_command?(command) do
      spawn_systemd(command)
    else
      spawn_background(command, run_id)
    end
  end

  # A backgrounded runner is checked by its watcher shortly after start; a
  # systemd unit is started (and its failures reported) by systemd-run itself.
  defp startup_check("process:" <> _rest, run_id), do: [log: runner_log(run_id)]
  defp startup_check(_ref, _run_id), do: []

  defp runner_log(run_id), do: Path.join(RunSpec.dir(run_id), "runner.log")

  defp systemd_command?(command), do: Regex.match?(~r/(^|\s)systemd-run(\s|$)/, command)

  defp spawn_systemd(command) do
    case systemd_unit(command) do
      nil ->
        {:error, :missing_systemd_unit}

      unit ->
        case System.cmd("sh", ["-c", command], stderr_to_stdout: true, env: @runner_env) do
          {_output, 0} -> {:ok, "systemd:" <> unit}
          {output, status} -> {:error, {:launch_failed, status, String.slice(output, 0, 1_000)}}
        end
    end
  end

  defp spawn_background(command, run_id) do
    log = runner_log(run_id)

    # One shell backgrounds the runner and prints the started pid, so the
    # controller does not wait for (or own) the run process. The runner's
    # output goes to its log, so a runner that fails at once can be explained.
    wrapper = command <> " </dev/null >>" <> shell_escape(log) <> " 2>&1 & echo $!"

    case System.cmd("sh", ["-c", wrapper], stderr_to_stdout: true, env: @runner_env) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {pid, ""} when pid > 0 -> started_ref(pid)
          _ -> {:error, {:invalid_pid_output, run_id, output}}
        end

      {output, status} ->
        {:error, {:launch_failed, status, String.slice(output, 0, 1_000)}}
    end
  end

  # The reference carries the process start time, read now, so a later
  # `alive?/1` or `stop/1` never acts on another process that reused the pid.
  # A runner already gone gets a start time that never matches. Whether the
  # runner really started is the watcher's startup check, so this returns at
  # once instead of blocking the caller (the orchestrator).
  defp started_ref(pid) do
    case process_info(pid) do
      {:ok, _stat, start} -> {:ok, "process:#{pid}:#{start}"}
      :error -> {:ok, "process:#{pid}:#{@gone_start}"}
    end
  end

  defp systemd_unit(command) do
    regex = ~r/--unit(?:=|\s+)(?:'(?<single>[^']+)'|"(?<double>[^"]+)"|(?<plain>\S+))/

    case Regex.named_captures(regex, command) do
      %{"single" => single, "double" => double, "plain" => plain} ->
        # A rendered `{run_id}` is shell-quoted inside the plain form.
        Enum.find([single, double, String.replace(plain, ["'", "\""], "")], &(&1 not in [nil, ""]))

      nil ->
        nil
    end
  end

  # `process:<pid>:<start>`; a bare `process:<pid>` (no start time) is still
  # accepted and checked by pid only.
  defp parse_process_ref(rest) do
    {pid, start} =
      case String.split(rest, ":", parts: 2) do
        [pid, start] -> {pid, start}
        [pid] -> {pid, nil}
      end

    case Integer.parse(pid) do
      {pid_number, ""} when pid_number > 0 -> {:ok, pid_number, start}
      _ -> :error
    end
  end

  defp process_alive?(pid, start) do
    with {_output, 0} <- System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true),
         {:ok, stat, actual_start} <- process_info(pid) do
      not String.starts_with?(stat, "Z") and (is_nil(start) or start == actual_start)
    else
      _ -> false
    end
  end

  # The process state and its start time (`ps -o lstart=`, in the C locale,
  # with spaces as underscores so it fits in a reference).
  defp process_info(pid) do
    case System.cmd("ps", ["-o", "stat=", "-o", "lstart=", "-p", Integer.to_string(pid)], stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
      {output, 0} ->
        case String.split(output) do
          [stat | [_ | _] = start] -> {:ok, stat, Enum.join(start, "_")}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # Stopping checks the process itself, never the shared snapshot, which can
  # be up to its TTL old.
  defp stop_process_group(pid, start, timeout_ms) do
    if process_alive?(pid, start) do
      # Always signal the process itself as well as its group: the default
      # template makes the runner a group leader, while a custom command may
      # not have created its own group.
      signal_group(pid, "TERM")
      signal_pid(pid, "TERM")

      unless wait_dead(pid, start, timeout_ms) do
        signal_group(pid, "KILL")
        signal_pid(pid, "KILL")
        wait_dead(pid, start, timeout_ms)
      end
    end

    ProcessTable.forget(pid)
    :ok
  end

  defp signal_group(pid, signal) do
    System.cmd("kill", ["-#{signal}", "-#{pid}"], stderr_to_stdout: true)
  end

  defp signal_pid(pid, signal) do
    System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp wait_dead(pid, start, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_dead(pid, start, deadline)
  end

  defp do_wait_dead(pid, start, deadline) do
    cond do
      not process_alive?(pid, start) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        do_wait_dead(pid, start, deadline)
    end
  end

  defp shell_escape(nil), do: nil
  defp shell_escape(value) when is_binary(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
