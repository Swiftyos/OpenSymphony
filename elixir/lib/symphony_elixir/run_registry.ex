defmodule SymphonyElixir.RunRegistry do
  @moduledoc """
  The orchestrator's agent runs, kept across restarts: for each running issue
  its run id, attempt, epoch, launcher reference, start time and the metadata
  the run resumes with.

  The orchestrator records a run when it dispatches it and deletes it when the
  run leaves `running` (finished, crashed, cancelled or stopped). A run left in
  the registry was therefore cut off by a restart: on start the orchestrator
  adopts it if its launcher still reports it alive, otherwise it schedules the
  next attempt and deletes it.

  Epochs are per issue and strictly increasing across restarts, so a run from
  an earlier attempt can be told from the current one; they are kept when the
  run is deleted.

  It also keeps the issue metadata needed to rebuild an adopted run and the
  last event seq applied for it, so the runner protocol's deduplication
  survives a controller restart.

  ## Storage

  Each issue is its own `StateStore` document,
  `<dir of runs_path>/run_registry/<base64url issue id>.json`, holding the
  issue id, its highest epoch and its run (`null` once deleted). A write
  therefore costs the same with 1 or 1,000 runs. The single `runs.json` of
  earlier versions (`~/.symphony/runs.json`, the configured `runs_path`) is
  read once when the registry is first loaded: its runs and epochs become
  per-issue documents and the file is rewritten empty with a `migrated_to`
  marker. Nothing is kept when the path is nil (tests).

  ## Cache

  Every write is serialised through `SymphonyElixir.RunRegistry.Server`
  (started before the orchestrator), which also keeps the decoded registry in
  an ETS table indexed by issue and by run id. `load/0`, `find_run/1` and
  `next_epoch/1` read that table, so the runner endpoints never decode the
  store per request. Without the server (a runner, or a test without the app)
  reads and writes go to the store directly.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunRegistry.Server
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.StateStore

  @format_version 2
  @dir_name "run_registry"
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

  @typedoc "One issue's document: its highest epoch and its run, if one is recorded."
  @type doc :: %{epoch: non_neg_integer(), run: entry() | nil}

  @doc """
  Records the run for `issue_id`, replacing any earlier run for it and moving
  its epoch forward.
  """
  @spec record(String.t(), map()) :: :ok
  def record(issue_id, entry) when is_binary(issue_id) and is_map(entry), do: write({:record, issue_id, entry})

  @doc "Forgets the run for `issue_id`, keeping its epoch."
  @spec delete(String.t()) :: :ok
  def delete(issue_id) when is_binary(issue_id), do: write({:delete, issue_id})

  @doc """
  Records the last event seq applied for a run, and its finished reason once
  it has ended. A write for an older run is ignored.

  Progress without a finished reason is applied to the cache at once (readers
  see it) and persisted by `RunRegistry.Server` at most once a second, for the
  changed runs only. A finished reason is written before this returns, so the
  controller acks a `finished` event only once it is durable.
  """
  @spec advance_progress(String.t(), String.t(), non_neg_integer(), String.t() | nil) :: :ok
  def advance_progress(issue_id, run_id, last_seq, finished \\ nil)

  def advance_progress(issue_id, run_id, last_seq, nil)
      when is_binary(issue_id) and is_binary(run_id) and is_integer(last_seq) and last_seq >= 0 do
    with path when is_binary(path) <- path(),
         false <- Server.buffer_progress(path, issue_id, run_id, last_seq) do
      write({:progress, issue_id, run_id, last_seq, nil})
    else
      _buffered_or_no_path -> :ok
    end
  end

  def advance_progress(issue_id, run_id, last_seq, finished)
      when is_binary(issue_id) and is_binary(run_id) and is_integer(last_seq) and last_seq >= 0 and
             is_binary(finished) do
    write({:progress, issue_id, run_id, last_seq, finished})
  end

  def advance_progress(_issue_id, _run_id, _last_seq, _finished), do: :ok

  @doc "Writes any coalesced progress now (shutdown and tests)."
  @spec flush() :: :ok
  def flush, do: Server.flush()

  @doc """
  Drops the cached registry, so the next read loads it from the store again
  (tests that change the store underneath the server).
  """
  @spec reload() :: :ok
  def reload do
    case path() do
      nil -> :ok
      path -> Server.drop(path)
    end
  end

  # Every write goes through the single `RunRegistry.Server`, so read-modify-
  # write cycles from the orchestrator and the runner endpoints never
  # interleave. Without the server the write is applied in the caller.
  defp write(op) do
    case path() do
      nil -> :ok
      path -> if Server.write(path, op), do: :ok, else: apply_direct(path, op)
    end
  end

  defp apply_direct(path, op) do
    {docs, changed} = apply_op(op, read_store(path))
    persist(path, docs, changed)
  end

  @doc false
  # Applies one write to the issue documents it touches. Returns the documents
  # and the issue ids whose document changed (to persist). Used by
  # `RunRegistry.Server` and by callers writing without it.
  @spec apply_op(tuple(), %{String.t() => doc()}) :: {%{String.t() => doc()}, [String.t()]}
  def apply_op({:record, issue_id, entry}, docs) do
    epoch = normalize_epoch(entry)
    previous = Map.get(docs, issue_id, %{epoch: 0, run: nil})
    doc = %{epoch: max(previous.epoch, epoch), run: normalize_entry(entry, epoch)}
    {Map.put(docs, issue_id, doc), [issue_id]}
  end

  def apply_op({:delete, issue_id}, docs) do
    case Map.get(docs, issue_id) do
      %{run: %{}} = doc -> {Map.put(docs, issue_id, %{doc | run: nil}), [issue_id]}
      _missing_or_deleted -> {docs, []}
    end
  end

  def apply_op({:progress, issue_id, run_id, last_seq, finished}, docs) do
    case Map.get(docs, issue_id) do
      %{run: %{run_id: ^run_id} = entry} = doc ->
        case progressed(entry, last_seq, finished) do
          ^entry -> {docs, []}
          next -> {Map.put(docs, issue_id, %{doc | run: next}), [issue_id]}
        end

      _other ->
        {docs, []}
    end
  end

  defp progressed(entry, last_seq, finished) do
    %{entry | last_seq: max(entry.last_seq, last_seq), finished: finished || entry.finished}
  end

  @doc "The recorded runs, by issue id; empty when nothing was saved or it can't be read."
  @spec load() :: %{String.t() => entry()}
  def load do
    case path() do
      nil -> %{}
      path -> path |> docs() |> runs()
    end
  end

  @doc "The recorded run with this run id, as `{issue_id, entry}`, or nil."
  @spec find_run(String.t() | nil) :: {String.t(), entry()} | nil
  def find_run(run_id) when is_binary(run_id) do
    case path() do
      nil -> nil
      path -> find_cached_run(path, run_id)
    end
  end

  def find_run(_run_id), do: nil

  defp find_cached_run(path, run_id) do
    case Server.find_run(path, run_id) do
      :unavailable -> path |> read_store() |> runs() |> Enum.find(fn {_issue_id, entry} -> entry.run_id == run_id end)
      found -> found
    end
  end

  @doc "The next epoch for `issue_id`: one more than the last one recorded, across restarts."
  @spec next_epoch(String.t()) :: pos_integer()
  def next_epoch(issue_id) when is_binary(issue_id) do
    case path() do
      nil ->
        1

      path ->
        doc =
          case Server.lookup(path, issue_id) do
            :unavailable -> Map.get(read_store(path), issue_id)
            doc -> doc
          end

        (doc || %{epoch: 0}).epoch + 1
    end
  end

  @doc "A random run id."
  @spec new_run_id() :: String.t()
  def new_run_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp docs(path) do
    case Server.docs(path) do
      :unavailable -> read_store(path)
      docs -> docs
    end
  end

  defp runs(docs) do
    for {issue_id, %{run: %{} = entry}} <- docs, into: %{}, do: {issue_id, entry}
  end

  @doc false
  # Every issue document for the registry at `path`, migrating the single
  # legacy `runs.json` there into per-issue documents first.
  @spec read_store(Path.t()) :: %{String.t() => doc()}
  def read_store(path) do
    docs = read_dir(path)

    case read_legacy(path) do
      empty when map_size(empty) == 0 -> docs
      legacy -> migrate(path, docs, legacy)
    end
  end

  defp read_dir(path) do
    case StateStore.list(dir(path)) do
      {:ok, documents} ->
        for {doc_path, body} <- documents,
            {:ok, issue_id, doc} <- [decode_doc(doc_path, body)],
            into: %{},
            do: {issue_id, doc}

      {:error, reason} ->
        Logger.warning("Run registry unreadable, starting empty path=#{dir(path)} reason=#{inspect(reason, limit: 5)}")
        %{}
    end
  end

  defp decode_doc(doc_path, body) do
    case Jason.decode(body) do
      {:ok, %{"issue_id" => issue_id} = row} when is_binary(issue_id) and issue_id != "" ->
        epoch = decode_epoch(Map.get(row, "epoch"))

        run =
          case parse(Map.get(row, "run")) do
            {:ok, entry} -> entry
            :error -> nil
          end

        {:ok, issue_id, %{epoch: max(epoch, (run && run.epoch) || 0), run: run}}

      other ->
        Logger.warning("Run registry document unreadable path=#{doc_path} reason=#{inspect(other, limit: 5)}")
        :error
    end
  end

  # The legacy single document, as issue documents; empty when there is none
  # or it has been migrated.
  defp read_legacy(path) do
    with {:ok, body} <- StateStore.read(path),
         {:ok, %{} = document} <- Jason.decode(body) do
      runs = decode_runs(Map.get(document, "runs"))
      epochs = decode_epochs(Map.get(document, "epochs"))

      epoch_docs = Map.new(epochs, fn {issue_id, epoch} -> {issue_id, %{epoch: epoch, run: nil}} end)

      Enum.reduce(runs, epoch_docs, fn {issue_id, entry}, acc ->
        epoch = max(entry.epoch, Map.get(epochs, issue_id, 0))
        Map.put(acc, issue_id, %{epoch: epoch, run: entry})
      end)
    else
      {:error, :enoent} ->
        %{}

      other ->
        Logger.warning("Run registry unreadable, starting empty path=#{path} reason=#{inspect(other, limit: 5)}")
        %{}
    end
  end

  # Per-issue documents win over the legacy file's run for the same issue;
  # epochs take the higher of the two.
  defp migrate(path, docs, legacy) do
    merged =
      Enum.reduce(legacy, docs, fn {issue_id, legacy_doc}, acc ->
        Map.update(acc, issue_id, legacy_doc, fn doc -> %{doc | epoch: max(doc.epoch, legacy_doc.epoch)} end)
      end)

    :ok = persist(path, merged, Map.keys(legacy))

    marker = %{"version" => 1, "migrated_to" => @dir_name, "runs" => %{}, "epochs" => %{}}

    case StateStore.write(path, Jason.encode!(marker)) do
      :ok -> Logger.info("Run registry migrated to per-issue documents path=#{path} issues=#{map_size(legacy)}")
      {:error, reason} -> Logger.error("Run registry migration marker failed path=#{path} reason=#{inspect(reason)}")
    end

    merged
  end

  @doc false
  # Writes the documents of `issue_ids` (one store write each).
  @spec persist(Path.t(), %{String.t() => doc()}, [String.t()]) :: :ok
  def persist(path, docs, issue_ids) do
    Enum.each(issue_ids, fn issue_id ->
      case Map.fetch(docs, issue_id) do
        {:ok, doc} -> save_doc(path, issue_id, doc)
        :error -> :ok
      end
    end)
  end

  defp save_doc(path, issue_id, %{epoch: epoch, run: run}) do
    document = %{
      "version" => @format_version,
      "issue_id" => issue_id,
      "epoch" => epoch,
      "run" => if(run, do: encode(run))
    }

    doc_path = doc_path(path, issue_id)

    case StateStore.write(doc_path, Jason.encode!(document)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Run registry save failed path=#{doc_path} reason=#{inspect(reason)}")
    end

    :ok
  end

  @doc "The directory of per-issue documents for the registry at `path`."
  @spec dir(Path.t()) :: Path.t()
  def dir(path), do: Path.join(Path.dirname(path), @dir_name)

  @doc "The document of `issue_id` in the registry at `path`."
  @spec doc_path(Path.t(), String.t()) :: Path.t()
  def doc_path(path, issue_id), do: Path.join(dir(path), Base.url_encode64(issue_id, padding: false) <> ".json")

  defp decode_runs(%{} = rows) do
    for {issue_id, row} <- rows, {:ok, entry} <- [parse(row)], into: %{}, do: {issue_id, entry}
  end

  defp decode_runs(_rows), do: %{}

  defp decode_epochs(%{} = rows) do
    for {issue_id, epoch} <- rows, is_integer(epoch) and epoch > 0, into: %{}, do: {issue_id, epoch}
  end

  defp decode_epochs(_rows), do: %{}

  defp decode_epoch(epoch) when is_integer(epoch) and epoch > 0, do: epoch
  defp decode_epoch(_epoch), do: 0

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
