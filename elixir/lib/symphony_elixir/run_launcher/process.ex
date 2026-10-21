defmodule SymphonyElixir.RunLauncher.Process do
  @moduledoc """
  Starts each run as a separate OS process: `symphony runner <spec.json>`.

  The spec is written to the run's directory, then the configured command
  template is run detached. The command must return at once: the default
  `setsid` template backgrounds the runner and prints its pid, while the VM's
  `systemd-run --user --unit=...` template returns after starting the unit.
  The reference records how to check and stop the run:

    * `process:<os pid>` — `kill -0`, and a process-group `TERM` then `KILL`.
    * `systemd:<unit>` — `systemctl --user is-active`, and `systemctl --user stop`.

  A `SymphonyElixir.RunWatcher` is started for the run; the orchestrator
  monitors that watcher. See `docs/durable-runs.md`.
  """

  @behaviour SymphonyElixir.RunLauncher

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.RunWatcher

  @kill_grace_ms 10_000
  @poll_ms 100

  @impl true
  def start(%RunSpec{} = spec, opts), do: start_process(spec, opts)

  def start(%{spec: %RunSpec{} = spec} = request, opts) do
    start_process(spec, Keyword.put_new(opts, :fun, Map.get(request, :fun)))
  end

  def start(fun, _opts) when is_function(fun, 0), do: {:error, :missing_run_spec}
  def start(_other, _opts), do: {:error, :missing_run_spec}

  @impl true
  def start_process(%RunSpec{} = spec, opts \\ []) do
    with {:ok, spec_path} <- RunSpec.write(spec),
         {:ok, command} <- render_command(command_template(opts), spec, spec_path, opts),
         {:ok, ref} <- spawn_process(command, spec.run_id),
         {:ok, watcher_pid} <-
           RunWatcher.start(
             %{run_id: spec.run_id, issue_id: Map.get(spec.issue || %{}, :id)},
             ref,
             Keyword.merge(
               [launcher: __MODULE__],
               Keyword.take(opts, [:poll_interval_ms, :lost_grace_ms])
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

  @impl true
  def alive?("process:" <> pid) when pid != "" do
    case Integer.parse(pid) do
      {pid_number, ""} when pid_number > 0 ->
        process_alive?(pid_number)

      _ ->
        false
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
  def stop("process:" <> pid, timeout_ms) when pid != "" do
    case Integer.parse(pid) do
      {pid_number, ""} when pid_number > 0 ->
        stop_process_group(pid_number, timeout_ms)

      _ ->
        :ok
    end

    :ok
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
      "{run_id}" => spec.run_id,
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

  defp spawn_process(command, run_id) do
    if systemd_command?(command) do
      spawn_systemd(command)
    else
      spawn_background(command, run_id)
    end
  end

  defp systemd_command?(command), do: Regex.match?(~r/(^|\s)systemd-run(\s|$)/, command)

  defp spawn_systemd(command) do
    case systemd_unit(command) do
      nil ->
        {:error, :missing_systemd_unit}

      unit ->
        case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
          {_output, 0} -> {:ok, "systemd:" <> unit}
          {output, status} -> {:error, {:launch_failed, status, String.slice(output, 0, 1_000)}}
        end
    end
  end

  defp spawn_background(command, run_id) do
    # One shell backgrounds the runner and prints the started pid, so the
    # controller does not wait for (or own) the run process.
    wrapper = command <> " >/dev/null 2>&1 & echo $!"

    case System.cmd("sh", ["-c", wrapper], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {pid, ""} when pid > 0 -> {:ok, "process:" <> Integer.to_string(pid)}
          _ -> {:error, {:invalid_pid_output, run_id, output}}
        end

      {output, status} ->
        {:error, {:launch_failed, status, String.slice(output, 0, 1_000)}}
    end
  end

  defp systemd_unit(command) do
    regex = ~r/--unit(?:=|\s+)(?:'(?<single>[^']+)'|"(?<double>[^"]+)"|(?<plain>\S+))/

    case Regex.named_captures(regex, command) do
      %{"single" => single, "double" => double, "plain" => plain} ->
        Enum.find([single, double, plain], &(&1 not in [nil, ""]))

      nil ->
        nil
    end
  end

  defp process_alive?(pid) do
    with {_output, 0} <- System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true),
         {stat, 0} <- System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      not String.starts_with?(String.trim(stat), "Z")
    else
      _ -> false
    end
  end

  defp stop_process_group(pid, timeout_ms) when is_integer(pid) and pid > 0 do
    if alive?("process:" <> Integer.to_string(pid)) do
      # Always signal the process itself as well as its group: the default
      # template makes the runner a group leader, while a custom command may
      # not have created its own group.
      signal_group(pid, "TERM")
      signal_pid(pid, "TERM")

      unless wait_dead(pid, timeout_ms) do
        signal_group(pid, "KILL")
        signal_pid(pid, "KILL")
        wait_dead(pid, timeout_ms)
      end
    end

    :ok
  end

  defp signal_group(pid, signal) do
    System.cmd("kill", ["-#{signal}", "-#{pid}"], stderr_to_stdout: true)
  end

  defp signal_pid(pid, signal) do
    System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp wait_dead(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_dead(pid, deadline)
  end

  defp do_wait_dead(pid, deadline) do
    cond do
      not alive?("process:" <> Integer.to_string(pid)) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        do_wait_dead(pid, deadline)
    end
  end

  defp shell_escape(nil), do: nil
  defp shell_escape(value) when is_binary(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
