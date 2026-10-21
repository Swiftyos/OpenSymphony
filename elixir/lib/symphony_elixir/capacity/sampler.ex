defmodule SymphonyElixir.Capacity.Sampler do
  @moduledoc """
  Periodically measures the CPU and memory of running agent runs.

  With `sandbox.kind: docker`, one `<sandbox.command> stats` call covers every
  Symphony container; otherwise one `ps` call covers the process trees of the
  local agent app servers. Failures are logged once per distinct error and never
  take the sampler (or the application) down.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Capacity.Metrics
  alias SymphonyElixir.{Config, Orchestrator, Sandbox}

  @run_metric_names [
    "symphony_run_cpu_percent",
    "symphony_run_memory_bytes"
  ]
  @ps_columns ["-o", "pid,ppid,rss,%cpu", "-ax"]
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
    logged_errors: MapSet.new()
  ]

  @type command_runner :: (String.t(), [String.t()], keyword() -> {String.t(), integer()})
  @type container_sample :: %{
          name: String.t(),
          cpu_percent: float(),
          memory_bytes: non_neg_integer()
        }
  @type process_sample :: %{
          ppid: integer(),
          rss_kb: number(),
          cpu_percent: number()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = build_state(opts)
    if state.interval_ms > 0, do: schedule_sample(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:sample, state) do
    state = safe_sample(state)
    if state.interval_ms > 0, do: schedule_sample(state.interval_ms)
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
    output = String.trim(output)

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

  @doc false
  @spec parse_ps(String.t()) :: {:ok, %{integer() => process_sample()}} | {:error, term()}
  def parse_ps(output) when is_binary(output) do
    output
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.drop(1)
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
          %{integer() => %{cpu_percent: number(), memory_bytes: non_neg_integer()}}
  def aggregate_processes(processes, root_pids) when is_map(processes) and is_list(root_pids) do
    children_by_parent =
      Enum.reduce(processes, %{}, fn {pid, sample}, acc ->
        Map.update(acc, sample.ppid, [pid], &[pid | &1])
      end)

    Map.new(root_pids, fn root_pid ->
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
      interval_ms:
        Keyword.get(opts, :sample_interval_ms) ||
          Application.get_env(:symphony_elixir, :capacity_sample_interval_ms) ||
          settings.capacity.sample_interval_ms,
      settings: settings,
      command_runner:
        Keyword.get(opts, :command_runner) ||
          Application.get_env(:symphony_elixir, :capacity_command_runner, &System.cmd/3),
      snapshot_fun:
        Keyword.get(opts, :snapshot_fun) ||
          Application.get_env(:symphony_elixir, :capacity_snapshot_fun, &Orchestrator.snapshot/0),
      logged_errors: MapSet.new()
    }
  end

  defp schedule_sample(interval_ms), do: Process.send_after(self(), :sample, interval_ms)

  defp safe_sample(state) do
    do_sample(state) |> elem(0)
  rescue
    error -> log_once(state, {:exception, Exception.message(error)})
  end

  defp do_sample(state) do
    case snapshot_running(state) do
      {:ok, running} ->
        record_token_rates(running)

        {state, sampled} =
          if Sandbox.enabled?(state.settings) do
            sample_containers(state, running)
          else
            sample_processes(state, running)
          end

        Metrics.set_gauge("symphony_runs_sampled", [], sampled)
        {state, sampled}

      {:error, reason} ->
        {log_once(state, reason), 0}
    end
  end

  defp snapshot_running(state) do
    case state.snapshot_fun.() do
      %{running: running} when is_list(running) -> {:ok, running}
      %{"running" => running} when is_list(running) -> {:ok, running}
      running when is_list(running) -> {:ok, running}
      :unavailable -> {:error, :orchestrator_unavailable}
      :timeout -> {:error, :orchestrator_timeout}
      other -> {:error, {:invalid_snapshot, inspect(other)}}
    end
  rescue
    error -> {:error, {:snapshot_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, inspect(reason)}}
  end

  defp record_token_rates(running) do
    Metrics.delete_gauges(["symphony_run_tokens_per_minute"])

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
    Metrics.delete_gauges(@run_metric_names)

    if expected == %{} do
      {state, 0}
    else
      command = state.settings.sandbox.command
      {result, state} = run_command(state, command, stats_args(command))
      record_container_result(state, result, expected)
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

  defp record_container_result(state, {output, 0}, expected) do
    case parse_container_stats(output) do
      {:ok, samples} -> {state, record_container_samples(samples, expected)}
      {:error, reason} -> {log_once(state, {:container_stats_parse_error, inspect(reason)}), 0}
    end
  end

  defp record_container_result(state, {output, status}, _expected) do
    {log_once(state, {:container_stats_failed, status, truncate(output)}), 0}
  end

  defp record_container_samples(samples, expected) do
    Enum.reduce(samples, 0, fn sample, count ->
      case Map.get(expected, sample.name) do
        nil ->
          count

        entry ->
          record_run_sample(entry, sample.cpu_percent, sample.memory_bytes)
          count + 1
      end
    end)
  end

  defp sample_processes(state, running) do
    roots = process_roots(running)
    Metrics.delete_gauges(@run_metric_names)

    if roots == [] do
      {state, 0}
    else
      {result, state} = run_command(state, "ps", @ps_columns)
      record_process_result(state, result, roots)
    end
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

  defp record_process_result(state, {output, 0}, roots) do
    case parse_ps(output) do
      {:ok, processes} -> {state, record_process_samples(processes, roots)}
      {:error, reason} -> {log_once(state, {:ps_parse_error, inspect(reason)}), 0}
    end
  end

  defp record_process_result(state, {output, status}, _roots) do
    {log_once(state, {:ps_failed, status, truncate(output)}), 0}
  end

  defp record_process_samples(processes, roots) do
    usage = aggregate_processes(processes, Enum.map(roots, &elem(&1, 0)))
    entries_by_pid = Map.new(roots)

    Enum.reduce(usage, 0, fn {pid, usage}, count ->
      entry = Map.fetch!(entries_by_pid, pid)
      record_run_sample(entry, usage.cpu_percent, usage.memory_bytes)
      count + 1
    end)
  end

  defp run_command(state, command, args) do
    result =
      try do
        state.command_runner.(command, args, stderr_to_stdout: true)
      rescue
        error -> {Exception.message(error), 127}
      catch
        kind, reason -> {inspect({kind, reason}), 127}
      end

    {result, state}
  end

  defp record_run_sample(entry, cpu_percent, memory_bytes) do
    labels = [
      issue: issue_label(entry),
      backend: backend_label(entry),
      stage: stage_label(entry)
    ]

    Metrics.set_gauge("symphony_run_cpu_percent", labels, cpu_percent)
    Metrics.set_gauge("symphony_run_memory_bytes", labels, memory_bytes)
    Metrics.record_histogram("symphony_run_cpu_percent_distribution", [], cpu_percent)
    Metrics.record_histogram("symphony_run_memory_bytes_distribution", [], memory_bytes)
  end

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

  defp log_once(state, reason) do
    if MapSet.member?(state.logged_errors, reason) do
      state
    else
      Logger.warning("Capacity sampler failed: #{inspect(reason)}")
      %{state | logged_errors: MapSet.put(state.logged_errors, reason)}
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
      memory_bytes: memory_bytes(sample)
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
      [pid, ppid, rss, cpu | _rest] ->
        with {pid, ""} <- Integer.parse(pid),
             {ppid, ""} <- Integer.parse(ppid),
             {rss, ""} <- number_parse(rss),
             {cpu, ""} <- number_parse(cpu) do
          {:ok, pid, %{ppid: ppid, rss_kb: rss, cpu_percent: cpu}}
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

  defp sum_process_tree(processes, children_by_parent, root_pid) do
    do_sum_process_tree(processes, children_by_parent, [root_pid], MapSet.new())
  end

  defp do_sum_process_tree(_processes, _children_by_parent, [], _seen) do
    %{cpu_percent: 0.0, memory_bytes: 0}
  end

  defp do_sum_process_tree(processes, children_by_parent, [pid | rest], seen) do
    if MapSet.member?(seen, pid) do
      do_sum_process_tree(processes, children_by_parent, rest, seen)
    else
      children = Map.get(children_by_parent, pid, [])
      acc = do_sum_process_tree(processes, children_by_parent, rest ++ children, MapSet.put(seen, pid))

      case Map.get(processes, pid) do
        nil ->
          acc

        sample ->
          %{
            cpu_percent: acc.cpu_percent + sample.cpu_percent,
            memory_bytes: acc.memory_bytes + round(sample.rss_kb * 1024)
          }
      end
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
