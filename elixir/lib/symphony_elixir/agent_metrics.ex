defmodule SymphonyElixir.AgentMetrics do
  @moduledoc """
  Prometheus counters for what agents do: tokens, turns, tool calls, and how
  and how long runs end.

  Each is recorded at the one place both run hosts converge, so a run hosted
  by a runner (a pod or a process runner, whose events arrive over
  `/runner/v1`) is counted exactly like an in-process run:

    * **Tool calls** (`tool_call/2`): every agent event a run reports reaches
      `RunHost.Local.agent_update/4` (in-process) or the runner endpoint's
      `agent_update` event, each applied once. A tool call is counted when it
      finishes, with the transcript's own reading of the event
      (`SymphonyElixir.Transcript.changes/1`): a command, edit or tool entry
      whose status is `completed`, `failed` or `declined`, or a tool result.
    * **Turns** (`turn_started/1`): `RunHost.turn_started/3`, in-process or as
      the runner's `turn_started` event.
    * **Tokens** (`tokens/2`): the deltas the orchestrator derives from those
      same agent events (`SymphonyElixir.UsageLedger.record_tokens/2`).
    * **Runs** (`run_ended/2`): every run leaving `running`
      (`SymphonyElixir.SessionHistory.record/3`), with its outcome
      (`finished`, `crashed`, `stalled`, `closed`, `paused`, `moved`,
      `missing`) and duration.

  Labels are bounded: backend (`codex`, `claude`, `opencode`), token type,
  outcome. Nothing is labelled by issue or run, so 1000 concurrent runs add
  no series; per-issue detail stays in the usage ledger and ClickHouse.
  """

  alias SymphonyElixir.Capacity.Metrics
  alias SymphonyElixir.Transcript

  @tool_kinds ["command", "edit", "tool"]
  @finished_statuses ["completed", "failed", "declined"]
  @backends ["codex", "claude", "opencode"]
  @outcomes [:finished, :crashed, :stalled, :closed, :paused, :moved, :missing]

  @doc "Counts the tool calls that finished in one agent event."
  @spec tool_call(map(), String.t() | nil) :: :ok
  def tool_call(update, backend) when is_map(update) do
    update
    |> Transcript.changes()
    |> Enum.each(fn change ->
      case tool_outcome(change) do
        nil -> :ok
        outcome -> Metrics.record_counter("symphony_agent_tool_calls_total", backend: backend_label(backend), outcome: outcome)
      end
    end)
  end

  def tool_call(_update, _backend), do: :ok

  @doc "Counts a turn starting (`info` is the transcript's turn info: `%{turn: n, backend: ...}`)."
  @spec turn_started(map() | nil) :: :ok
  def turn_started(%{turn: turn} = info) when is_integer(turn) do
    Metrics.record_counter("symphony_agent_turns_total", backend: backend_label(Map.get(info, :backend)))
  end

  def turn_started(_info), do: :ok

  @doc "Counts a token delta (`input_tokens`, `output_tokens`, `cached_input_tokens`)."
  @spec tokens(String.t() | nil, map()) :: :ok
  def tokens(backend, delta) when is_map(delta) do
    backend = backend_label(backend)

    for {type, key} <- [input: :input_tokens, output: :output_tokens, cached_input: :cached_input_tokens],
        amount = Map.get(delta, key),
        is_integer(amount) and amount > 0 do
      Metrics.record_counter("symphony_agent_tokens_total", [backend: backend, type: Atom.to_string(type)], amount)
    end

    :ok
  end

  def tokens(_backend, _delta), do: :ok

  @doc """
  Counts a run that ended and its duration. `entry` is the orchestrator's
  running-entry snapshot (`backend`, `runtime_seconds`).
  """
  @spec run_ended(map(), atom()) :: :ok
  def run_ended(entry, outcome) when is_map(entry) and is_atom(outcome) do
    labels = [backend: backend_label(Map.get(entry, :backend)), outcome: outcome_label(outcome)]
    Metrics.record_counter("symphony_agent_runs_total", labels)

    case Map.get(entry, :runtime_seconds) do
      seconds when is_number(seconds) and seconds >= 0 -> Metrics.record_histogram("symphony_agent_run_duration_seconds", labels, seconds)
      _unknown -> :ok
    end
  end

  def run_ended(_entry, _outcome), do: :ok

  defp tool_outcome({:result, _ref, %{error?: true}}), do: "error"
  defp tool_outcome({:result, _ref, _result}), do: "ok"

  defp tool_outcome({:add, %{kind: kind, status: status}}) when kind in @tool_kinds and status in @finished_statuses,
    do: if(status == "completed", do: "ok", else: "error")

  defp tool_outcome(_change), do: nil

  defp backend_label(backend) when backend in @backends, do: backend
  defp backend_label(nil), do: "unknown"
  defp backend_label(_backend), do: "other"

  defp outcome_label(outcome) when outcome in @outcomes, do: Atom.to_string(outcome)
  defp outcome_label(_outcome), do: "other"
end
