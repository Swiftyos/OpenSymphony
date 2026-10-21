defmodule SymphonyElixir.SessionHistory do
  @moduledoc """
  Agent sessions that have ended, for the dashboard's session list: which issue
  and stage the agent worked on, with which harness, for how long and how many
  tokens, and how the session ended.

  The orchestrator records a session when its run leaves `running` (it
  finished, crashed, stalled, or was stopped because its issue moved on).
  Sessions are kept for #{30} days, the newest #{2_000} at most, in
  `~/.symphony/session_history.json` through `StateStore`; only in memory when
  the path is nil (tests).

  Entries use the dashboard's live-session field names (`issue_identifier`,
  `issue_title`, `tokens`, ...) so live and ended sessions render alike, plus
  `ended_at`, `runtime_seconds`, `stage`, `outcome` and `error`.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentMetrics, IssueStage, StateStore, StatusDashboard, UsageLedger}
  alias SymphonyElixir.Linear.Issue

  @format_version 1
  @retention_ms 30 * 86_400_000
  @max_entries 2_000
  @max_message 400

  @typedoc """
  How a session ended: `finished` (the agent's run ended normally), `crashed`,
  `stalled` (restarted after going quiet), `closed` (its issue reached a
  terminal state), `paused`, `moved` (its issue left the agent's states or
  this worker), or `missing` (its issue could no longer be found).
  """
  @type outcome :: :finished | :crashed | :stalled | :closed | :paused | :moved | :missing

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Records an ended session from the orchestrator's snapshot of its running
  entry. Never blocks the caller.
  """
  @spec record(map(), outcome(), String.t() | nil) :: :ok
  def record(entry, outcome, error \\ nil) when is_map(entry) and is_atom(outcome) do
    # Every run leaving `running` passes here, in-process or runner-hosted.
    AgentMetrics.run_ended(entry, outcome)
    GenServer.cast(__MODULE__, {:record, entry, outcome, error, DateTime.utc_now()})
  end

  @doc """
  Ended sessions, newest first. `since_ms` keeps those that ended at or after
  that Unix time in milliseconds.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    since = Keyword.get(opts, :since_ms)
    entries = GenServer.call(__MODULE__, :list, 2_000)
    if is_integer(since), do: Enum.take_while(entries, &(&1.ended_at_ms >= since)), else: entries
  catch
    :exit, _reason -> []
  end

  @doc false
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, %{entries: load()}}

  @impl true
  def handle_cast({:record, entry, outcome, error, now}, state) do
    now_ms = DateTime.to_unix(now, :millisecond)

    entries =
      [session(entry, outcome, error, now) | state.entries]
      |> Enum.take_while(&(&1.ended_at_ms >= now_ms - @retention_ms))
      |> Enum.take(@max_entries)

    save(entries)
    {:noreply, %{state | entries: entries}}
  rescue
    error ->
      Logger.warning("Session history: couldn't record a session reason=#{Exception.message(error)}")
      {:noreply, state}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.entries, state}
  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | entries: []}}

  defp session(entry, outcome, error, now) do
    started_at = Map.get(entry, :started_at)
    stage = stage(entry)

    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      issue_title: Map.get(entry, :issue_title),
      issue_url: Map.get(entry, :issue_url),
      project_slug: Map.get(entry, :project_slug),
      project_name: Map.get(entry, :project_name),
      state: Map.get(entry, :state),
      stage: stage && stage["name"],
      stage_id: stage && stage["id"],
      backend: Map.get(entry, :backend),
      model: Map.get(entry, :model) || UsageLedger.model_label(Map.get(entry, :backend)),
      effort: Map.get(entry, :effort),
      session_id: Map.get(entry, :session_id),
      worker_host: Map.get(entry, :worker_host),
      turn_count: Map.get(entry, :turn_count) || 0,
      tokens: %{
        input_tokens: Map.get(entry, :agent_input_tokens) || 0,
        output_tokens: Map.get(entry, :agent_output_tokens) || 0,
        total_tokens: Map.get(entry, :agent_total_tokens) || 0
      },
      last_event: entry |> Map.get(:last_agent_event) |> then(&(&1 && to_string(&1))),
      last_message: message(Map.get(entry, :last_agent_message)),
      started_at: iso8601(started_at),
      ended_at: iso8601(now),
      ended_at_ms: DateTime.to_unix(now, :millisecond),
      runtime_seconds: runtime_seconds(started_at, now),
      outcome: Atom.to_string(outcome),
      error: error
    }
  end

  # The stage the agent worked in: the issue's stage when its run ended.
  defp stage(entry) do
    IssueStage.stage_definition(%Issue{
      identifier: Map.get(entry, :identifier),
      project_slug: Map.get(entry, :project_slug),
      state: Map.get(entry, :state),
      labels: Map.get(entry, :labels) || []
    })
  rescue
    _error -> nil
  end

  defp message(nil), do: nil

  defp message(raw) do
    case StatusDashboard.humanize_agent_message(raw) do
      text when is_binary(text) -> String.slice(text, 0, @max_message)
      _ -> nil
    end
  end

  defp runtime_seconds(%DateTime{} = started_at, now), do: max(DateTime.diff(now, started_at, :second), 0)
  defp runtime_seconds(_started_at, _now), do: 0

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_at), do: nil

  # ------------------------------------------------------------- storage

  defp save(entries) do
    case path() do
      nil ->
        :ok

      path ->
        case StateStore.write(path, Jason.encode!(%{"version" => @format_version, "sessions" => entries})) do
          :ok -> :ok
          {:error, reason} -> Logger.error("Session history save failed path=#{path} reason=#{inspect(reason)}")
        end
    end
  end

  defp load do
    with path when is_binary(path) <- path(),
         {:ok, body} <- StateStore.read(path),
         {:ok, %{"sessions" => rows}} when is_list(rows) <- Jason.decode(body) do
      for row <- rows, {:ok, entry} <- [parse(row)], do: entry
    else
      nil ->
        []

      {:error, :enoent} ->
        []

      other ->
        Logger.warning("Session history unreadable, starting empty reason=#{inspect(other, limit: 5)}")
        []
    end
  end

  @fields ~w(issue_id issue_identifier issue_title issue_url project_slug project_name state stage stage_id backend model
             effort session_id worker_host turn_count last_event last_message started_at ended_at ended_at_ms
             runtime_seconds outcome error)a

  defp parse(%{"issue_identifier" => identifier, "ended_at_ms" => ended} = row) when is_binary(identifier) and is_integer(ended) do
    tokens = Map.get(row, "tokens") || %{}
    entry = Map.new(@fields, &{&1, Map.get(row, Atom.to_string(&1))})

    {:ok,
     %{
       entry
       | turn_count: entry.turn_count || 0,
         runtime_seconds: entry.runtime_seconds || 0
     }
     |> Map.put(:tokens, %{
       input_tokens: tokens["input_tokens"] || 0,
       output_tokens: tokens["output_tokens"] || 0,
       total_tokens: tokens["total_tokens"] || 0
     })}
  end

  defp parse(_row), do: :error

  defp path do
    case Application.get_env(:symphony_elixir, :session_history_path, :default) do
      :default -> Path.join(StateStore.root(), "session_history.json")
      path -> path
    end
  end
end
