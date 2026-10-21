defmodule SymphonyElixir.Capacity.Prometheus do
  @moduledoc """
  Renders the capacity series measured by `SymphonyElixir.Capacity.Metrics`.
  """

  alias SymphonyElixir.Capacity.Metrics

  @metric_definitions [
    %{
      name: "symphony_linear_requests_total",
      help: "Linear GraphQL requests made by Symphony.",
      type: "counter"
    },
    %{
      name: "symphony_linear_request_duration_seconds",
      help: "Duration of Linear GraphQL requests made by Symphony.",
      type: "histogram"
    },
    %{
      name: "symphony_linear_rate_limit_remaining",
      help: "Linear rate-limit capacity reported by the last response.",
      type: "gauge"
    },
    %{
      name: "symphony_git_operations_total",
      help: "Git and gh operations Symphony ran while preparing workspaces.",
      type: "counter"
    },
    %{
      name: "symphony_git_operation_duration_seconds",
      help: "Duration of git and gh operations Symphony ran while preparing workspaces.",
      type: "histogram"
    },
    %{
      name: "symphony_run_cpu_percent",
      help: "Latest sampled CPU use of a running agent, in percent of one CPU.",
      type: "gauge"
    },
    %{
      name: "symphony_run_memory_bytes",
      help: "Latest sampled memory use of a running agent, in bytes.",
      type: "gauge"
    },
    %{
      name: "symphony_runs_sampled",
      help: "Running agents matched in the latest capacity sample.",
      type: "gauge"
    },
    %{
      name: "symphony_capacity_sample_errors_total",
      help: "Capacity samples that failed, by reason.",
      type: "counter"
    },
    %{
      name: "symphony_run_memory_bytes_distribution",
      help: "Memory use of every sampled agent run since Symphony started, in bytes.",
      type: "histogram"
    },
    %{
      name: "symphony_run_cpu_percent_distribution",
      help: "CPU use of every sampled agent run since Symphony started, in percent of one CPU.",
      type: "histogram"
    },
    %{
      name: "symphony_run_tokens_per_minute",
      help: "Token rate of a running agent over the run's age.",
      type: "gauge"
    },
    %{
      name: "symphony_run_usage_reports_total",
      help: "CPU and memory reports from runners (pods, process runners), by how the runner measured itself.",
      type: "counter"
    },
    %{
      name: "symphony_agent_tokens_total",
      help: "Tokens agents used, by backend and type (input includes cached input).",
      type: "counter"
    },
    %{
      name: "symphony_agent_turns_total",
      help: "Agent turns started, by backend.",
      type: "counter"
    },
    %{
      name: "symphony_agent_tool_calls_total",
      help: "Agent tool calls (commands, edits, tools) that finished, by backend and outcome.",
      type: "counter"
    },
    %{
      name: "symphony_agent_runs_total",
      help: "Agent runs that ended, by backend and outcome.",
      type: "counter"
    },
    %{
      name: "symphony_agent_run_duration_seconds",
      help: "Duration of agent runs that ended, by backend and outcome.",
      type: "histogram"
    },
    %{
      name: "symphony_runner_pods",
      help: "Runner pods by phase, from the controller's pod watch.",
      type: "gauge"
    },
    %{
      name: "symphony_runner_pods_waiting",
      help: "Pending runner pods waiting for capacity: Kueue's scheduling gate, or no node that fits.",
      type: "gauge"
    },
    %{
      name: "symphony_runner_pod_start_seconds",
      help: "Time from a runner pod's creation to its runner container running (Kueue admission, scheduling, image pulls).",
      type: "histogram"
    },
    %{
      name: "symphony_runner_pod_failures_total",
      help: "Runner pods that failed, by reason (DeadlineExceeded, Evicted, OOMKilled, Error).",
      type: "counter"
    },
    %{
      name: "symphony_runner_launches_total",
      help: "Runner pod launches, by outcome.",
      type: "counter"
    },
    %{
      name: "symphony_runner_launch_failures_total",
      help: "Runner pod launches that failed, by reason.",
      type: "counter"
    },
    %{
      name: "symphony_runner_janitor_deletions_total",
      help: "Finished runner pods and orphaned run Secrets the janitor deleted.",
      type: "counter"
    },
    %{
      name: "symphony_runner_pod_watch_reconnects_total",
      help: "Times the runner pod watch was restarted, by reason (closed is the API server's normal timeout).",
      type: "counter"
    },
    %{
      name: "symphony_runner_pod_watch_synced",
      help: "1 while the runner pod cache is synced and fresh, else 0.",
      type: "gauge"
    },
    %{
      name: "symphony_runner_pod_status_checks_total",
      help: "Run watcher pod checks, by where the answer came from (cache, or an API GET on a miss or a stale cache).",
      type: "counter"
    }
  ]

  @spec render() :: String.t()
  def render do
    snapshot = Metrics.snapshot()

    @metric_definitions
    |> Enum.map_join("\n\n", fn definition ->
      block_lines =
        [
          "# HELP #{definition.name} #{definition.help}",
          "# TYPE #{definition.name} #{definition.type}"
        ] ++ render_definition(definition, snapshot)

      Enum.join(block_lines, "\n")
    end)
    |> Kernel.<>("\n")
  end

  defp render_definition(%{name: name, type: "histogram"}, snapshot) do
    snapshot.histograms
    |> Enum.filter(&(&1.name == name))
    |> Enum.sort_by(&sample_sort_key/1)
    |> Enum.flat_map(&render_histogram/1)
  end

  defp render_definition(%{name: name}, snapshot) do
    (snapshot.counters ++ snapshot.gauges)
    |> Enum.filter(&(&1.name == name))
    |> Enum.sort_by(&sample_sort_key/1)
    |> Enum.map(&render_sample/1)
  end

  defp render_histogram(histogram) do
    bucket_lines =
      Enum.map(histogram.buckets, fn {bound, count} ->
        render_sample(%{
          name: histogram.name <> "_bucket",
          labels: histogram.labels ++ [le: render_bound(bound)],
          value: count
        })
      end)

    bucket_lines ++
      [
        render_sample(%{name: histogram.name <> "_sum", labels: histogram.labels, value: histogram.sum}),
        render_sample(%{name: histogram.name <> "_count", labels: histogram.labels, value: histogram.count})
      ]
  end

  defp render_sample(%{name: name, labels: labels, value: value}) do
    "#{name}#{render_labels(sort_labels(labels))} #{render_value(value)}"
  end

  defp render_labels(labels) do
    rendered = Enum.map_join(labels, ",", fn {key, value} -> "#{key}=\"#{escape_label_value(value)}\"" end)
    "{#{rendered}}"
  end

  defp sort_labels(labels) do
    Enum.sort_by(labels, fn {key, _value} -> to_string(key) end)
  end

  defp render_bound(:inf), do: "+Inf"
  defp render_bound(bound) when is_integer(bound), do: Integer.to_string(bound)
  defp render_bound(bound) when is_float(bound), do: :erlang.float_to_binary(bound, [:compact, decimals: 6])

  defp render_value(value) when is_integer(value), do: Integer.to_string(value)
  defp render_value(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact, decimals: 6])

  defp escape_label_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\"", "\\\"")
  end

  defp sample_sort_key(sample) do
    {sample.name, Enum.map(sort_labels(sample.labels), fn {key, value} -> {key, to_string(value)} end)}
  end
end
