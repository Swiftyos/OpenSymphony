defmodule SymphonyElixir.RunRegistry do
  @moduledoc """
  The orchestrator's agent runs, kept across restarts: for each running issue
  its run id, attempt, epoch, launcher reference, start time and the metadata
  the run resumes with.

  The orchestrator records a run when it dispatches it and deletes it when the
  run leaves `running` (finished, crashed, cancelled or stopped). A run left in
  the document was therefore cut off by a restart: on start the orchestrator
  stops it if a launcher still reports it alive, schedules its next attempt and
  deletes it.

  Epochs are per issue and strictly increasing across restarts, so a run from
  an earlier attempt can be told from the current one; they are kept when the
  run is deleted.

  Kept in `~/.symphony/runs.json` through `StateStore`; not kept when the path
  is nil (tests).
  """

  require Logger

  alias SymphonyElixir.StateStore

  @format_version 1
  # The same run metadata the retry queue keeps, so a recovered run retries
  # with the same fields it started with.
  @fields ~w(identifier issue_title issue_url project_id project_slug project_name labels backend effort worker_host workspace_path)a

  @typedoc "A recorded run: its identity, its launcher reference and its metadata."
  @type entry :: %{
          run_id: String.t(),
          attempt: non_neg_integer(),
          epoch: pos_integer(),
          launcher: module() | String.t() | nil,
          ref: String.t(),
          started_at_unix_ms: integer(),
          metadata: map()
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
       metadata: normalize_metadata(Map.get(row, "metadata"))
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
      metadata: normalize_metadata(Map.get(entry, :metadata))
    }
  end

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

  defp encode(entry) do
    %{
      "run_id" => Map.get(entry, :run_id),
      "attempt" => normalize_attempt(entry),
      "epoch" => normalize_epoch(entry),
      "launcher" => launcher_to_string(Map.get(entry, :launcher)),
      "ref" => Map.get(entry, :ref),
      "started_at_unix_ms" => Map.get(entry, :started_at_unix_ms),
      "metadata" => encode_metadata(Map.get(entry, :metadata))
    }
  end

  defp encode_metadata(raw) do
    metadata = normalize_metadata(raw)
    Map.new(@fields, fn field -> {Atom.to_string(field), Map.get(metadata, field)} end)
  end

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
