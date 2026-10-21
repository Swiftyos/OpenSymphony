defmodule SymphonyElixir.Capacity.Sampler do
  @moduledoc """
  Periodically measures the CPU and memory of running agent runs.

  With `sandbox.kind: docker`, one `<sandbox.command> stats` call covers every
  Symphony container; otherwise one `ps` call covers the process trees of the
  local agent app servers. Commands run with a deadline so a wedged container
  runtime cannot block the sampler. Failures are logged once per kind of error
  and never take the sampler (or the application) down.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Capacity.Metrics
  alias SymphonyElixir.{Config, Orchestrator, Sandbox}

  @run_metric_names [
    "symphony_run_cpu_percent",
    "symphony_run_memory_bytes"
  ]
  @sample_error_counter "symphony_capacity_sample_errors_total"
  @ps_columns ["-e", "-o", "pid=,ppid=,rss=,time="]
  @command_timeout_ms 10_000
  @memory_units %{
    "" => 1,
    "b" => 1,
    "kb" => 1_000,
    "kib" => 1024,
    "mb" => 1_000_000,
    "mib" => 1024 * 1024,
    "gb" => 1_000_000_000,
    "gib" => 1024 * 1024 * 1024,
    "tb" => 1_000_000_000_000,
    "tib" => 1024 * 1024 * 1024 * 1024
  }

  defstruct [
    :interval_ms,
    :settings,
    :command_runner,
    :snapshot_fun,
    :command_timeout_ms,
    :clock,
    :proc_reader,
    previous_cpu: %{},
    logged_errors: MapSet.new()
  ]

  @type command_runner :: (String.t(), [String.t()], keyword() -> {String.t(), integer()})
  @type container_sample :: %{
          name: String.t(),
          cpu_percent: float(),
          memory_bytes: non_neg_integer(),
          cpu_seconds: float() | nil
        }
  @type process_sample :: %{
          ppid: integer(),
          rss_kb: number(),
          cpu_seconds: number()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = build_state(opts)
    if sampling_enabled?(state.interval_ms), do: schedule_sample(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:sample, state) do
    state = safe_sample(state)
    if sampling_enabled?(state.interval_ms), do: schedule_sample(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec sample(keyword()) :: :ok
  def sample(opts) do
    state = build_state(opts)
    _result = do_sample(state)
    :ok
  end

  @doc false
  @spec parse_container_stats(String.t()) :: {:ok, [container_sample()]} | {:error, term()}
  def parse_container_stats(output) when is_binary(output) do
    # Rootless podman prints warnings (WARN[0000] ...) on stderr, which the
    # runner merges into the output; only JSON lines are stats.
    output =
      output
      |> String.split(~r/\r?\n/)
      |> Enum.filter(&json_line?/1)
      |> Enum.join("\n")
      |> String.trim()

    cond do
      output == "" ->
        {:ok, []}

      String.starts_with?(output, "[") ->
        decode_json_array(output)

      true ->
        decode_json_lines(output)
    end
  end

  def parse_container_stats(_output), do: {:error, :invalid_container_stats}

  # Log lines podman/docker print on stderr: logrus (WARN[0000] ...) and
  # key=value (time="..." level=warning ...) formats.
  defp json_line?(line) do
    trimmed = String.trim_leading(line)
    not Regex.match?(~r/^(?:(?:WARN|ERRO|INFO|DEBU|FATA)\[|time=|level=)/, trimmed)
  end

  @doc false
  @spec parse_ps(String.t()) :: {:ok, %{integer() => process_sample()}} | {:error, term()}
  def parse_ps(output) when is_binary(output) do
    output
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, processes} ->
      case parse_ps_line(line) do
        {:ok, pid, sample} -> {:cont, {:ok, Map.put(processes, pid, sample)}}
        :error -> {:cont, {:ok, processes}}
      end
    end)
  end

  def parse_ps(_output), do: {:error, :invalid_ps_output}

  @doc false
  @spec aggregate_processes(%{integer() => process_sample()}, [integer()]) ::
          %{integer() => %{cpu_seconds: number(), memory_bytes: non_neg_integer()}}
  def aggregate_processes(processes, root_pids) when is_map(processes) and is_list(root_pids) do
    children_by_parent =
      Enum.reduce(processes, %{}, fn {pid, sample}, acc ->
        Map.update(acc, sample.ppid, [pid], &[pid | &1])
      end)

    root_pids
    |> Enum.filter(&Map.has_key?(processes, &1))
    |> Map.new(fn root_pid ->
      {root_pid, sum_process_tree(processes, children_by_parent, root_pid)}
    end)
  end

  @doc false
  @spec token_rate_per_minute(map()) :: float() | nil
  def token_rate_per_minute(entry) when is_map(entry) do
    tokens = numeric_value(Map.get(entry, :agent_total_tokens) || Map.get(entry, "agent_total_tokens"))
    seconds = run_seconds(entry)

    if is_number(tokens) and tokens >= 0 and is_number(seconds) and seconds > 0 do
      tokens * 60 / seconds
    end
  end

  @doc false
  @spec parse_cpu_time(String.t()) :: {:ok, float()} | :error
  def parse_cpu_time(value) when is_binary(value) do
    {days, rest} = split_days(value)

    with {days, ""} <- Integer.parse(days),
         {:ok, parts} <- parse_cpu_time_parts(rest) do
      {:ok, days * 86_400 + parts}
    else
      _ -> :error
    end
  end

  def parse_cpu_time(_value), do: :error

  @doc false
  @spec stats_args(String.t()) :: [String.t()]
  def stats_args(command) when is_binary(command) do
    if String.contains?(Path.basename(command), "podman") do
      ["stats", "--no-stream", "--format", "json"]
    else
      ["stats", "--no-stream", "--format", "{{json .}}"]
    end
  end

  defp build_state(opts) do
    settings = Keyword.get(opts, :settings) || Config.settings!()

    %__MODULE__{
      interval_ms: normalize_interval(sample_interval_ms(opts, settings)),
      settings: settings,
      command_runner:
        Keyword.get(opts, :command_runner) ||
          Application.get_env(:symphony_elixir, :capacity_command_runner, &system_command/3),
      snapshot_fun:
        Keyword.get(opts, :snapshot_fun) ||
          Application.get_env(:symphony_elixir, :capacity_snapshot_fun, &Orchestrator.snapshot/0),
      proc_reader:
        Keyword.get(opts, :proc_reader) ||
          Application.get_env(:symphony_elixir, :capacity_proc_reader, &read_proc_stat/1),
      command_timeout_ms:
        Keyword.get(opts, :command_timeout_ms) ||
          Application.get_env(:symphony_elixir, :capacity_command_timeout_ms, @command_timeout_ms),
      clock: Keyword.get(opts, :clock) || fn -> System.monotonic_time(:millisecond) end,
      previous_cpu: %{},
      logged_errors: MapSet.new()
    }
  end

  defp sample_interval_ms(opts, settings) do
    Keyword.get(opts, :sample_interval_ms) ||
      Application.get_env(:symphony_elixir, :capacity_sample_interval_ms) ||
      settings.capacity.sample_interval_ms
  end

  defp normalize_interval(0), do: 0
  defp normalize_interval(interval) when is_integer(interval) and interval >= 1_000, do: interval
  defp normalize_interval(_interval), do: 0

  defp sampling_enabled?(interval_ms), do: is_integer(interval_ms) and interval_ms > 0

  defp schedule_sample(interval_ms), do: Process.send_after(self(), :sample, interval_ms)

  defp safe_sample(state) do
    do_sample(state) |> elem(0)
  rescue
    error ->
      record_sample_error({:exception, Exception.message(error)})
      log_once(state, {:exception, Exception.message(error)})
  end

  defp do_sample(state) do
    case snapshot_running(state) do
      {:ok, running} ->
        {result, state} =
          if Sandbox.enabled?(state.settings) do
            sample_containers(state, running)
          else
            sample_processes(state, running)
          end

        case result do
          {:ok, samples} ->
            Metrics.delete_gauges(["symphony_run_tokens_per_minute" | @run_metric_names])
            record_token_rates(running)
            Enum.each(samples, &record_run_sample/1)
            Metrics.set_gauge("symphony_runs_sampled", [], length(samples))
            {%{state | logged_errors: MapSet.new()}, length(samples)}

          {:error, reason} ->
            Metrics.set_gauge("symphony_runs_sampled", [], 0)
            record_sample_error(reason)
            {log_once(state, reason), 0}
        end

      {:error, reason} ->
        Metrics.set_gauge("symphony_runs_sampled", [], 0)
        record_sample_error(reason)
        {log_once(state, reason), 0}
    end
  end

  defp snapshot_running(state) do
    case state.snapshot_fun.() do
      %{running: running} when is_list(running) -> {:ok, running}
      %{"running" => running} when is_list(running) -> {:ok, running}
      running when is_list(running) -> {:ok, running}
      :unavailable -> {:error, {:snapshot_unavailable, "orchestrator not available"}}
      :timeout -> {:error, {:snapshot_timeout, "orchestrator snapshot timed out"}}
      other -> {:error, {:invalid_snapshot, inspect(other)}}
    end
  rescue
    error -> {:error, {:snapshot_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:snapshot_exception, inspect({kind, reason})}}
  end

  defp record_token_rates(running) do
    Enum.each(running, fn entry ->
      case token_rate_per_minute(entry) do
        nil ->
          :ok

        rate ->
          Metrics.set_gauge(
            "symphony_run_tokens_per_minute",
            [issue: issue_label(entry), backend: backend_label(entry)],
            rate
          )
      end
    end)
  end

  defp sample_containers(state, running) do
    expected = expected_containers(running)

    if expected == %{} do
      {{:ok, []}, %{state | previous_cpu: %{}}}
    else
      command = state.settings.sandbox.command

      case run_command(state, command, stats_args(command)) do
        {{:ok, {output, 0}}, state} ->
          container_output(state, output, expected)

        {{:ok, {output, 124}}, state} ->
          {{:error, {:command_timeout, truncate(output)}}, state}

        {{:ok, {output, status}}, state} ->
          {{:error, {:container_stats_failed, "#{status}: #{truncate(output)}"}}, state}

        {{:error, reason}, state} ->
          {{:error, reason}, state}
      end
    end
  end

  defp container_output(state, output, expected) do
    case parse_container_stats(output) do
      {:ok, samples} -> container_samples(samples, expected, state)
      {:error, reason} -> {{:error, {:container_stats_parse_error, inspect(reason)}}, state}
    end
  end

  defp expected_containers(running) do
    running
    |> Enum.flat_map(fn entry ->
      case container_for_entry(entry) do
        nil -> []
        name -> [{name, entry}]
      end
    end)
    |> Map.new()
  end

  defp container_samples(samples, expected, state) do
    now = state.clock.()

    {rows, previous_cpu} =
      Enum.reduce(samples, {[], %{}}, fn sample, {rows, previous} ->
        case Map.get(expected, sample.name) do
          nil ->
            {rows, previous}

          entry ->
            key = {entry_key(entry), sample.name}

            {row, previous} =
              run_sample_row(
                key,
                entry,
                sample.cpu_seconds,
                sample.cpu_percent,
                sample.memory_bytes,
                state.previous_cpu,
                previous,
                now
              )

            {[row | rows], previous}
        end
      end)

    {{:ok, Enum.reverse(rows)}, %{state | previous_cpu: previous_cpu}}
  end

  defp sample_processes(state, running) do
    roots = process_roots(running)

    if roots == [] do
      {{:ok, []}, %{state | previous_cpu: %{}}}
    else
      case run_command(state, "ps", @ps_columns) do
        {{:ok, {output, 0}}, state} ->
          process_output(state, output, roots)

        {{:ok, {output, 124}}, state} ->
          {{:error, {:command_timeout, truncate(output)}}, state}

        {{:ok, {output, status}}, state} ->
          {{:error, {:ps_failed, "#{status}: #{truncate(output)}"}}, state}

        {{:error, reason}, state} ->
          {{:error, reason}, state}
      end
    end
  end

  defp process_output(state, output, roots) do
    case parse_ps(output) do
      {:ok, processes} -> process_samples(with_proc_cpu(processes, state.proc_reader), roots, state)
      {:error, reason} -> {{:error, {:ps_parse_error, inspect(reason)}}, state}
    end
  end

  # `ps` time is a process's own CPU and drops the CPU of children it already
  # reaped (test runs, builds), so a tree's total falls whenever a child exits.
  # On Linux /proc/<pid>/stat also has cutime/cstime (reaped children), which
  # keeps the tree total monotonic. Elsewhere (macOS) ps time is all there is.
  defp with_proc_cpu(processes, reader) do
    Map.new(processes, fn {pid, sample} ->
      case reader.(pid) do
        {:ok, seconds} -> {pid, %{sample | cpu_seconds: seconds}}
        _ -> {pid, sample}
      end
    end)
  end

  @clock_ticks_per_second 100

  @doc false
  @spec read_proc_stat(pos_integer(), Path.t()) :: {:ok, float()} | :error
  def read_proc_stat(pid, proc_root \\ "/proc") when is_integer(pid) do
    case File.read(Path.join([proc_root, Integer.to_string(pid), "stat"])) do
      {:ok, contents} -> parse_proc_stat(contents)
      {:error, _reason} -> :error
    end
  end

  @doc false
  @spec parse_proc_stat(String.t()) :: {:ok, float()} | :error
  def parse_proc_stat(contents) when is_binary(contents) do
    # Fields after "(comm)": state is field 3, so utime..cstime (14..17) are
    # at 11..14. comm may contain spaces and parens, hence the last ")".
    with [_, rest] <- :binary.split(contents, ") ", [:global]) |> then(&split_after_comm(&1)),
         fields = String.split(rest),
         [utime, stime, cutime, cstime] <- Enum.slice(fields, 11, 4),
         {:ok, ticks} <- sum_integers([utime, stime, cutime, cstime]) do
      {:ok, ticks / @clock_ticks_per_second}
    else
      _ -> :error
    end
  end

  defp split_after_comm(parts) when length(parts) >= 2 do
    {comm_parts, [rest]} = Enum.split(parts, -1)
    [Enum.join(comm_parts, ") "), rest]
  end

  defp split_after_comm(_parts), do: :error

  defp sum_integers(values) do
    Enum.reduce_while(values, {:ok, 0}, fn value, {:ok, total} ->
      case Integer.parse(value) do
        {number, ""} -> {:cont, {:ok, total + number}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp process_roots(running) do
    Enum.flat_map(running, fn entry ->
      with nil <- worker_host(entry),
           pid when is_integer(pid) <- os_pid(entry) do
        [{pid, entry}]
      else
        _ -> []
      end
    end)
  end

  defp process_samples(processes, roots, state) do
    usage = aggregate_processes(processes, Enum.map(roots, &elem(&1, 0)))
    now = state.clock.()

    {rows, previous_cpu} =
      Enum.reduce(roots, {[], %{}}, fn {pid, entry}, {rows, previous} ->
        case Map.get(usage, pid) do
          nil ->
            {rows, previous}

          %{cpu_seconds: cpu_seconds, memory_bytes: memory_bytes} ->
            {row, previous} =
              run_sample_row(
                {entry_key(entry), pid},
                entry,
                cpu_seconds,
                0.0,
                memory_bytes,
                state.previous_cpu,
                previous,
                now
              )

            {[row | rows], previous}
        end
      end)

    {{:ok, Enum.reverse(rows)}, %{state | previous_cpu: previous_cpu}}
  end

  # Baselines are keyed by run and process (or container) and rebuilt every
  # tick from the runs sampled in it (`baselines` is last tick's, `next` this
  # tick's), so an ended run's baseline never leaks into a later run.
  defp run_sample_row(key, entry, cpu_seconds, fallback_percent, memory_bytes, baselines, next, now) do
    case cpu_seconds do
      seconds when is_number(seconds) ->
        case Map.get(baselines, key) do
          {previous_seconds, previous_at}
          when is_number(previous_seconds) and now > previous_at and seconds >= previous_seconds ->
            cpu_percent = (seconds - previous_seconds) * 100_000 / (now - previous_at)
            {{entry, cpu_percent, memory_bytes}, Map.put(next, key, {seconds, now})}

          _ ->
            {{entry, nil, memory_bytes}, Map.put(next, key, {seconds, now})}
        end

      _ ->
        {{entry, fallback_percent, memory_bytes}, next}
    end
  end

  defp run_command(state, command, args) do
    opts = [stderr_to_stdout: true, timeout_ms: state.command_timeout_ms]

    task =
      Task.async(fn ->
        try do
          {:ok, state.command_runner.(command, args, opts)}
        rescue
          error -> {:raised, Exception.message(error)}
        catch
          kind, reason -> {:thrown, inspect({kind, reason})}
        end
      end)

    # The runner enforces the deadline itself (and kills the OS process); this
    # outer deadline only guards a custom runner that ignores it.
    outer_timeout_ms = state.command_timeout_ms + 1_000

    result =
      case Task.yield(task, outer_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, {output, status}}} -> {:ok, {output, status}}
        {:ok, {:raised, message}} -> {:error, {:command_exception, message}}
        {:ok, {:thrown, detail}} -> {:error, {:command_exception, detail}}
        nil -> {:error, {:command_timeout, "command deadline exceeded"}}
        other -> {:error, {:command_exception, inspect(other)}}
      end

    {result, state}
  end

  defp system_command(command, args, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @command_timeout_ms)

    case System.find_executable(command) do
      nil ->
        {"command not found: #{command}", 127}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :use_stdio,
            args: args
          ])

        collect_port(port, "", System.monotonic_time(:millisecond) + timeout_ms)
    end
  end

  defp collect_port(port, output, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect_port(port, output <> data, deadline_ms)
      {^port, {:exit_status, status}} -> {output, status}
    after
      remaining_ms ->
        kill_os_process(port)
        {output, 124}
    end
  end

  # The command may exit right at the deadline, closing the port first; then
  # there is nothing left to kill and it still counts as a timeout.
  @doc false
  @spec kill_os_process(port()) :: :ok
  def kill_os_process(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      _closed -> :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp record_run_sample({entry, nil, memory_bytes}) do
    labels = run_labels(entry)
    Metrics.set_gauge("symphony_run_memory_bytes", labels, memory_bytes)
    Metrics.record_histogram("symphony_run_memory_bytes_distribution", [], memory_bytes)
  end

  defp record_run_sample({entry, cpu_percent, memory_bytes}) do
    labels = run_labels(entry)

    Metrics.set_gauge("symphony_run_cpu_percent", labels, cpu_percent)
    Metrics.set_gauge("symphony_run_memory_bytes", labels, memory_bytes)
    Metrics.record_histogram("symphony_run_cpu_percent_distribution", [], cpu_percent)
    Metrics.record_histogram("symphony_run_memory_bytes_distribution", [], memory_bytes)
  end

  defp run_labels(entry) do
    [
      issue: issue_label(entry),
      backend: backend_label(entry),
      stage: stage_label(entry)
    ]
  end

  defp record_sample_error({kind, _detail}), do: record_sample_error(kind)

  defp record_sample_error(kind) do
    Metrics.record_counter(@sample_error_counter, reason: error_reason_label(kind))
  end

  defp error_reason_label(:command_timeout), do: "timeout"
  defp error_reason_label(:container_stats_failed), do: "container_stats_failed"
  defp error_reason_label(:container_stats_parse_error), do: "container_stats_parse_error"
  defp error_reason_label(:ps_failed), do: "ps_failed"
  defp error_reason_label(:ps_parse_error), do: "ps_parse_error"
  defp error_reason_label(:snapshot_unavailable), do: "snapshot_unavailable"
  defp error_reason_label(:snapshot_timeout), do: "snapshot_timeout"
  defp error_reason_label(:invalid_snapshot), do: "invalid_snapshot"
  defp error_reason_label(:snapshot_exception), do: "snapshot_exception"
  defp error_reason_label(:command_exception), do: "command_exception"
  defp error_reason_label(:exception), do: "sampler_exception"

  defp container_for_entry(entry) do
    case workspace_path(entry) do
      path when is_binary(path) and path != "" -> Sandbox.container_name(path)
      _ -> nil
    end
  end

  defp workspace_path(entry), do: Map.get(entry, :workspace_path) || Map.get(entry, "workspace_path")
  defp worker_host(entry), do: Map.get(entry, :worker_host) || Map.get(entry, "worker_host")
  defp backend_label(entry), do: string_value(Map.get(entry, :backend) || Map.get(entry, "backend")) || "unknown"
  defp stage_label(entry), do: string_value(Map.get(entry, :stage) || Map.get(entry, "stage")) || ""
  defp issue_label(entry), do: string_value(Map.get(entry, :identifier) || Map.get(entry, "identifier") || Map.get(entry, :issue_id) || Map.get(entry, "issue_id")) || ""

  defp entry_key(entry) do
    Map.get(entry, :issue_id) || Map.get(entry, "issue_id") ||
      Map.get(entry, :identifier) || Map.get(entry, "identifier") ||
      issue_label(entry)
  end

  defp os_pid(entry) do
    case Map.get(entry, :agent_server_pid) || Map.get(entry, "agent_server_pid") do
      pid when is_integer(pid) ->
        pid

      pid when is_binary(pid) ->
        case Integer.parse(String.trim(pid)) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp log_once(state, {kind, _detail} = reason) do
    if MapSet.member?(state.logged_errors, kind) do
      state
    else
      Logger.warning("Capacity sampler failed: #{inspect(reason)}")
      %{state | logged_errors: MapSet.put(state.logged_errors, kind)}
    end
  end

  defp truncate(output) when is_binary(output), do: String.slice(output, 0, 512)
  defp truncate(output), do: inspect(output, limit: 20)

  defp decode_json_array(output) do
    case Jason.decode(output) do
      {:ok, samples} when is_list(samples) ->
        if Enum.all?(samples, &is_map/1) do
          {:ok, Enum.map(samples, &normalize_container_sample/1)}
        else
          {:error, :unexpected_container_stats_shape}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_json_lines(output) do
    output
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, samples} ->
      case Jason.decode(line) do
        {:ok, sample} when is_map(sample) -> {:cont, {:ok, [normalize_container_sample(sample) | samples]}}
        {:ok, _other} -> {:halt, {:error, :unexpected_container_stats_shape}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, samples} -> {:ok, Enum.reverse(samples)}
      error -> error
    end
  end

  defp normalize_container_sample(sample) when is_map(sample) do
    %{
      name: container_name(sample),
      cpu_percent: cpu_percent(sample),
      memory_bytes: memory_bytes(sample),
      cpu_seconds: container_cpu_seconds(sample)
    }
  end

  defp container_name(sample) do
    string_value(
      Map.get(sample, "Name") ||
        Map.get(sample, "name") ||
        Map.get(sample, "Names") ||
        Map.get(sample, "names") ||
        Map.get(sample, "Container") ||
        Map.get(sample, "container")
    ) || ""
  end

  defp cpu_percent(sample) do
    sample
    |> first_value(["CPUPerc", "cpu_perc", "cpu_percent", "cpu", "CPU"])
    |> percent_value()
  end

  defp container_cpu_seconds(sample) do
    cond do
      value = first_value(sample, ["cpu_seconds", "CPUSeconds", "cpu_time_seconds"]) ->
        numeric_seconds(value)

      value = first_value(sample, ["CPUNano", "cpu_nano", "cpu_time_ns", "cpu_time_nano", "cpu_usage_total_usage"]) ->
        numeric_nanoseconds(value)

      value = first_value(sample, ["cpu_time", "CPUTime"]) ->
        parse_cpu_time_field(value)

      true ->
        nil
    end
  end

  defp numeric_seconds(value) when is_number(value), do: value * 1.0
  defp numeric_seconds(value) when is_binary(value), do: parse_float(value)
  defp numeric_seconds(_value), do: nil

  defp numeric_nanoseconds(value) when is_number(value), do: value / 1_000_000_000

  defp numeric_nanoseconds(value) when is_binary(value) do
    case parse_float(value) do
      nil -> nil
      nanoseconds -> nanoseconds / 1_000_000_000
    end
  end

  defp numeric_nanoseconds(_value), do: nil

  defp parse_cpu_time_field(value) when is_number(value), do: value / 1_000_000_000

  defp parse_cpu_time_field(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      go_duration?(value) ->
        go_duration_seconds(value)

      String.contains?(value, ":") ->
        case parse_cpu_time(value) do
          {:ok, seconds} -> seconds
          :error -> nil
        end

      true ->
        nil
    end
  end

  defp parse_cpu_time_field(_value), do: nil

  # Podman reports cpu_time as a Go duration: "6s", "1m12.27s", "1h2m3.5s", "850ms".
  @go_duration ~r/^(?:\d+(?:\.\d+)?(?:h|ms|us|µs|ns|m|s))+$/u
  @go_duration_part ~r/(\d+(?:\.\d+)?)(h|ms|us|µs|ns|m|s)/u

  defp go_duration?(value), do: Regex.match?(@go_duration, value)

  defp go_duration_seconds(value) do
    @go_duration_part
    |> Regex.scan(value, capture: :all_but_first)
    |> Enum.reduce(0.0, fn [number, unit], total ->
      {amount, ""} = Float.parse(number)
      total + amount * go_duration_unit(unit)
    end)
  end

  defp go_duration_unit("h"), do: 3600.0
  defp go_duration_unit("m"), do: 60.0
  defp go_duration_unit("s"), do: 1.0
  defp go_duration_unit("ms"), do: 1.0e-3
  defp go_duration_unit(unit) when unit in ["us", "µs"], do: 1.0e-6
  defp go_duration_unit("ns"), do: 1.0e-9

  defp parse_float(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp memory_bytes(sample) do
    case first_value(sample, ["MemUsageBytes", "mem_usage_bytes", "memory_bytes", "mem_bytes"]) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> parse_memory(value)
      _ -> sample |> first_value(["MemUsage", "mem_usage", "memory", "mem"]) |> parse_memory()
    end
  end

  defp first_value(sample, keys), do: Enum.find_value(keys, &Map.get(sample, &1))

  defp percent_value(value) when is_number(value), do: value * 1.0

  defp percent_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing("%")
    |> Float.parse()
    |> case do
      {percent, _rest} -> percent
      :error -> 0.0
    end
  end

  defp percent_value(_value), do: 0.0

  defp parse_memory(value) when is_number(value), do: round(value)

  defp parse_memory(value) when is_binary(value) do
    amount =
      value
      |> String.split("/", parts: 2)
      |> hd()
      |> String.trim()

    case Regex.run(~r/^([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]*)$/, amount) do
      [_, number, unit] ->
        {quantity, _rest} = Float.parse(number)
        round(quantity * memory_unit_multiplier(unit))

      _ ->
        0
    end
  end

  defp parse_memory(_value), do: 0

  defp memory_unit_multiplier(unit) do
    Map.get(@memory_units, String.downcase(unit), 1)
  end

  defp parse_ps_line(line) do
    case String.split(line) do
      [pid, ppid, rss, time | _rest] ->
        with {pid, ""} <- Integer.parse(pid),
             {ppid, ""} <- Integer.parse(ppid),
             {rss, ""} <- number_parse(rss),
             {:ok, cpu_seconds} <- parse_cpu_time(time) do
          {:ok, pid, %{ppid: ppid, rss_kb: rss, cpu_seconds: cpu_seconds}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp number_parse(value) do
    case Float.parse(value) do
      {number, rest} -> {number, rest}
      :error -> :error
    end
  end

  defp split_days(value) do
    case String.split(value, "-", parts: 2) do
      [days, rest] -> {days, rest}
      [rest] -> {"0", rest}
    end
  end

  defp parse_cpu_time_parts(value) do
    parts = String.split(value, ":")

    with true <- length(parts) in 2..3,
         {:ok, numbers} <- parse_float_parts(parts) do
      case numbers do
        [minutes, seconds] -> {:ok, minutes * 60 + seconds}
        [hours, minutes, seconds] -> {:ok, hours * 3_600 + minutes * 60 + seconds}
      end
    else
      _ -> :error
    end
  end

  defp parse_float_parts(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case Float.parse(part) do
        {number, ""} -> {:cont, {:ok, [number | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp sum_process_tree(processes, children_by_parent, root_pid) do
    do_sum_process_tree(processes, children_by_parent, [root_pid], MapSet.new())
  end

  defp do_sum_process_tree(_processes, _children_by_parent, [], _seen) do
    %{cpu_seconds: 0.0, memory_bytes: 0}
  end

  defp do_sum_process_tree(processes, children_by_parent, [pid | rest], seen) do
    if MapSet.member?(seen, pid) do
      do_sum_process_tree(processes, children_by_parent, rest, seen)
    else
      children = Map.get(children_by_parent, pid, [])
      acc = do_sum_process_tree(processes, children_by_parent, rest ++ children, MapSet.put(seen, pid))

      sample = Map.fetch!(processes, pid)

      %{
        cpu_seconds: acc.cpu_seconds + sample.cpu_seconds,
        memory_bytes: acc.memory_bytes + round(sample.rss_kb * 1024)
      }
    end
  end

  defp run_seconds(entry) do
    case Map.get(entry, :runtime_seconds) || Map.get(entry, "runtime_seconds") do
      seconds when is_number(seconds) and seconds > 0 ->
        seconds

      _ ->
        started_at_seconds(entry)
    end
  end

  defp started_at_seconds(entry) do
    case Map.get(entry, :started_at) || Map.get(entry, "started_at") do
      %DateTime{} = started_at -> max(DateTime.diff(DateTime.utc_now(), started_at, :second), 0)
      value when is_binary(value) -> started_at_string_seconds(value)
      _ -> 0
    end
  end

  defp started_at_string_seconds(value) do
    case DateTime.from_iso8601(value) do
      {:ok, started_at, _offset} -> max(DateTime.diff(DateTime.utc_now(), started_at, :second), 0)
      _ -> 0
    end
  end

  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(value) when is_binary(value), do: parse_memory_number(value)
  defp numeric_value(_value), do: nil

  defp parse_memory_number(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp string_value(nil), do: nil
  defp string_value(value), do: to_string(value)
end
