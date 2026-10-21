defmodule SymphonyElixir.RunRegistry do
  @moduledoc """
  The orchestrator's agent runs, kept across restarts: for each running issue
  its run id, attempt, epoch, launcher reference, start time and the metadata
  the run resumes with.

  The orchestrator records a run when it dispatches it and deletes it when the
  run leaves `running` (finished, crashed, cancelled or stopped). A run left in
  the document was therefore cut off by a restart: on start the orchestrator
  adopts it if its launcher still reports it alive, otherwise it schedules the
  next attempt and deletes it.

  Epochs are per issue and strictly increasing across restarts, so a run from
  an earlier attempt can be told from the current one; they are kept when the
  run is deleted.

  It also keeps the issue metadata needed to rebuild an adopted run and the
  last event seq applied for it, so the runner protocol's deduplication
  survives a controller restart.

  Kept in `~/.symphony/runs.json` through `StateStore`; not kept when the path
  is nil (tests).
  """

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.StateStore

  @format_version 1
  # The same run metadata the retry queue keeps, plus the issue itself so an
  # adopted run can be rebuilt without asking the tracker. `last_seq` lets the
  # controller keep event deduplication across a restart.
  @fields ~w(identifier issue_title issue_url project_id project_slug project_name labels backend effort worker_host workspace_path issue)a

  @typedoc "A recorded run: its identity, its launcher reference and its metadata."
  @type entry :: %{
          run_id: String.t(),
          attempt: non_neg_integer(),
          epoch: pos_integer(),
          launcher: module() | String.t() | nil,
          ref: String.t(),
          started_at_unix_ms: integer(),
          metadata: map(),
          last_seq: non_neg_integer(),
          finished: String.t() | nil
        }

  @doc """
  Records the run for `issue_id`, replacing any earlier run for it and moving
  its epoch forward.
  """
  @spec record(String.t(), map()) :: :ok
  def record(issue_id, entry) when is_binary(issue_id) and is_map(entry) do
    case path() do
      nil ->
        :ok

      path ->
        {runs, epochs} = read(path)
        epoch = normalize_epoch(entry)
        runs = Map.put(runs, issue_id, normalize_entry(entry, epoch))
        epochs = Map.update(epochs, issue_id, epoch, &max(&1, epoch))
        save(path, runs, epochs)
    end
  end

  @doc "Forgets the run for `issue_id`, keeping its epoch."
  @spec delete(String.t()) :: :ok
  def delete(issue_id) when is_binary(issue_id) do
    case path() do
      nil ->
        :ok

      path ->
        {runs, epochs} = read(path)
        save(path, Map.delete(runs, issue_id), epochs)
    end
  end

  @doc """
  Records the last event seq applied for a run, and its finished reason once
  it has ended. Writes are batched by the runner protocol (one call per event
  batch), not one per event. A write for an older run is ignored.
  """
  @spec advance_progress(String.t(), String.t(), non_neg_integer(), String.t() | nil) :: :ok
  def advance_progress(issue_id, run_id, last_seq, finished \\ nil)

  def advance_progress(issue_id, run_id, last_seq, finished)
      when is_binary(issue_id) and is_binary(run_id) and is_integer(last_seq) and last_seq >= 0 do
    case path() do
      nil -> :ok
      path -> advance_progress_at(path, issue_id, run_id, last_seq, finished)
    end
  end

  def advance_progress(_issue_id, _run_id, _last_seq, _finished), do: :ok

  defp advance_progress_at(path, issue_id, run_id, last_seq, finished) do
    {runs, epochs} = read(path)

    case Map.get(runs, issue_id) do
      %{run_id: ^run_id} = entry -> save_progress(path, runs, epochs, issue_id, entry, last_seq, finished)
      _ -> :ok
    end
  end

  defp save_progress(path, runs, epochs, issue_id, entry, last_seq, finished) do
    next = %{
      entry
      | last_seq: max(entry.last_seq, last_seq),
        finished: finished || entry.finished
    }

    if next == entry do
      :ok
    else
      save(path, Map.put(runs, issue_id, next), epochs)
    end
  end

  @doc "The recorded runs, by issue id; empty when nothing was saved or it can't be read."
  @spec load() :: %{String.t() => entry()}
  def load do
    case path() do
      nil -> %{}
      path -> path |> read() |> elem(0)
    end
  end

  @doc "The next epoch for `issue_id`: one more than the last one recorded, across restarts."
  @spec next_epoch(String.t()) :: pos_integer()
  def next_epoch(issue_id) when is_binary(issue_id) do
    case path() do
      nil ->
        1

      path ->
        {_runs, epochs} = read(path)
        Map.get(epochs, issue_id, 0) + 1
    end
  end

  @doc "A random run id."
  @spec new_run_id() :: String.t()
  def new_run_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp read(path) do
    with {:ok, body} <- StateStore.read(path),
         {:ok, %{} = document} <- Jason.decode(body) do
      {decode_runs(Map.get(document, "runs")), decode_epochs(Map.get(document, "epochs"))}
    else
      {:error, :enoent} ->
        {%{}, %{}}

      other ->
        Logger.warning("Run registry unreadable, starting empty path=#{path} reason=#{inspect(other, limit: 5)}")
        {%{}, %{}}
    end
  end

  defp save(path, runs, epochs) do
    document = %{
      "version" => @format_version,
      "runs" => Map.new(runs, fn {issue_id, entry} -> {issue_id, encode(entry)} end),
      "epochs" => epochs
    }

    case StateStore.write(path, Jason.encode!(document)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Run registry save failed path=#{path} reason=#{inspect(reason)}")
    end

    :ok
  end

  defp decode_runs(%{} = rows) do
    for {issue_id, row} <- rows, {:ok, entry} <- [parse(row)], into: %{}, do: {issue_id, entry}
  end

  defp decode_runs(_rows), do: %{}

  defp decode_epochs(%{} = rows) do
    for {issue_id, epoch} <- rows, is_integer(epoch) and epoch > 0, into: %{}, do: {issue_id, epoch}
  end

  defp decode_epochs(_rows), do: %{}

  defp parse(
         %{
           "run_id" => run_id,
           "attempt" => attempt,
           "epoch" => epoch,
           "ref" => ref,
           "started_at_unix_ms" => started_at
         } = row
       )
       when is_binary(run_id) and run_id != "" and is_integer(attempt) and attempt >= 0 and
              is_integer(epoch) and epoch > 0 and is_binary(ref) and is_integer(started_at) do
    {:ok,
     %{
       run_id: run_id,
       attempt: attempt,
       epoch: epoch,
       launcher: launcher_from_string(Map.get(row, "launcher")),
       ref: ref,
       started_at_unix_ms: started_at,
       metadata: decode_metadata(Map.get(row, "metadata")),
       last_seq: normalize_last_seq(Map.get(row, "last_seq")),
       finished: normalize_finished(Map.get(row, "finished"))
     }}
  end

  defp parse(_row), do: :error

  defp normalize_entry(entry, epoch) do
    %{
      run_id: Map.get(entry, :run_id),
      attempt: normalize_attempt(entry),
      epoch: epoch,
      launcher: Map.get(entry, :launcher),
      ref: Map.get(entry, :ref),
      started_at_unix_ms: Map.get(entry, :started_at_unix_ms),
      metadata: decode_metadata(Map.get(entry, :metadata)),
      last_seq: normalize_last_seq(Map.get(entry, :last_seq)),
      finished: normalize_finished(Map.get(entry, :finished))
    }
  end

  defp normalize_last_seq(seq) when is_integer(seq) and seq >= 0, do: seq
  defp normalize_last_seq(_seq), do: 0

  defp normalize_finished(reason) when is_binary(reason), do: reason
  defp normalize_finished(_reason), do: nil

  defp normalize_attempt(entry) do
    case Map.get(entry, :attempt) do
      attempt when is_integer(attempt) and attempt >= 0 -> attempt
      _ -> 0
    end
  end

  defp normalize_epoch(entry) do
    case Map.get(entry, :epoch) do
      epoch when is_integer(epoch) and epoch > 0 -> epoch
      _ -> 1
    end
  end

  defp normalize_metadata(raw) when is_map(raw) do
    metadata =
      Map.new(@fields, fn field ->
        {field, Map.get(raw, field) || Map.get(raw, Atom.to_string(field))}
      end)

    %{metadata | labels: metadata.labels || []}
  end

  defp normalize_metadata(_raw) do
    metadata = Map.new(@fields, &{&1, nil})
    %{metadata | labels: []}
  end

  defp decode_metadata(raw) do
    metadata = normalize_metadata(raw)

    issue =
      case metadata.issue do
        %Issue{} = issue -> issue
        %{} = issue -> RunSpec.to_issue(%RunSpec{run_id: "", epoch: 1, issue: issue})
        _ -> nil
      end

    %{metadata | issue: issue}
  end

  defp encode(entry) do
    %{
      "run_id" => Map.get(entry, :run_id),
      "attempt" => normalize_attempt(entry),
      "epoch" => normalize_epoch(entry),
      "launcher" => launcher_to_string(Map.get(entry, :launcher)),
      "ref" => Map.get(entry, :ref),
      "started_at_unix_ms" => Map.get(entry, :started_at_unix_ms),
      "metadata" => encode_metadata(Map.get(entry, :metadata)),
      "last_seq" => normalize_last_seq(Map.get(entry, :last_seq)),
      "finished" => normalize_finished(Map.get(entry, :finished))
    }
  end

  defp encode_metadata(raw) do
    metadata = normalize_metadata(raw)
    Map.new(@fields, fn field -> {Atom.to_string(field), encode_metadata_value(Map.get(metadata, field))} end)
  end

  defp encode_metadata_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_metadata_value(%Date{} = value), do: Date.to_iso8601(value)
  defp encode_metadata_value(%_{} = value), do: value |> Map.from_struct() |> encode_metadata_value()
  defp encode_metadata_value(value) when is_list(value), do: Enum.map(value, &encode_metadata_value/1)

  defp encode_metadata_value(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), encode_metadata_value(item)} end)
  end

  defp encode_metadata_value(value), do: value

  defp launcher_to_string(launcher) when is_atom(launcher) and not is_nil(launcher), do: Atom.to_string(launcher)
  defp launcher_to_string(launcher) when is_binary(launcher), do: launcher
  defp launcher_to_string(_launcher), do: nil

  defp launcher_from_string(launcher) when is_binary(launcher) do
    String.to_existing_atom(launcher)
  rescue
    ArgumentError -> launcher
  end

  defp launcher_from_string(launcher), do: launcher

  defp path do
    case Application.get_env(:symphony_elixir, :runs_path, :default) do
      :default -> Path.join(StateStore.root(), "runs.json")
      path -> path
    end
  end
end
