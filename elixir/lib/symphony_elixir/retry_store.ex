defmodule SymphonyElixir.RetryStore do
  @moduledoc """
  The orchestrator's retry queue, kept across restarts: each issue waiting for
  a retry or a continuation check, its attempt number, when it is due and the
  metadata the retry runs with.

  The orchestrator saves the whole queue whenever it changes and restores it on
  start, so a restart neither forgets an issue's backoff nor resets its attempt
  count. Due times are wall-clock (Unix milliseconds) so they mean the same on
  the next start; a retry that came due while Symphony was down runs right away.

  Kept in `~/.symphony/retries.json` through `StateStore`; not kept when the
  path is nil (tests).
  """

  require Logger

  alias SymphonyElixir.StateStore

  @format_version 1
  @fields ~w(identifier error worker_host workspace_path issue_title issue_url project_id project_slug project_name labels backend effort)a

  @typedoc "A restored retry: the attempt, its wall-clock due time and its metadata."
  @type entry :: %{attempt: pos_integer(), due_at_unix_ms: integer(), metadata: map()}

  @doc """
  Saves the queue. `retries` is the orchestrator's `retry_attempts` map; only
  `attempt`, `due_at_unix_ms` and the retry metadata fields are kept.
  """
  @spec save(%{String.t() => map()}) :: :ok
  def save(retries) when is_map(retries) do
    case path() do
      nil ->
        :ok

      path ->
        rows =
          for {issue_id, %{attempt: attempt, due_at_unix_ms: due} = retry} <- retries, into: %{} do
            {issue_id, %{"attempt" => attempt, "due_at_unix_ms" => due, "metadata" => Map.new(@fields, &{&1, Map.get(retry, &1)})}}
          end

        case StateStore.write(path, Jason.encode!(%{"version" => @format_version, "retries" => rows})) do
          :ok -> :ok
          {:error, reason} -> Logger.error("Retry queue save failed path=#{path} reason=#{inspect(reason)}")
        end

        :ok
    end
  end

  @doc "The saved queue, by issue id; empty when nothing was saved or it can't be read."
  @spec load() :: %{String.t() => entry()}
  def load do
    case path() do
      nil -> %{}
      path -> load(path)
    end
  end

  defp load(path) do
    with {:ok, body} <- StateStore.read(path),
         {:ok, %{"retries" => %{} = rows}} <- Jason.decode(body) do
      for {issue_id, row} <- rows, {:ok, entry} <- [parse(row)], into: %{}, do: {issue_id, entry}
    else
      {:error, :enoent} ->
        %{}

      other ->
        Logger.warning("Retry queue unreadable, starting empty path=#{path} reason=#{inspect(other, limit: 5)}")
        %{}
    end
  end

  defp parse(%{"attempt" => attempt, "due_at_unix_ms" => due} = row) when is_integer(attempt) and attempt > 0 and is_integer(due) do
    raw = Map.get(row, "metadata") || %{}
    metadata = Map.new(@fields, fn field -> {field, Map.get(raw, Atom.to_string(field))} end)
    {:ok, %{attempt: attempt, due_at_unix_ms: due, metadata: %{metadata | labels: metadata.labels || []}}}
  end

  defp parse(_row), do: :error

  defp path do
    case Application.get_env(:symphony_elixir, :retries_path, :default) do
      :default -> Path.join(StateStore.root(), "retries.json")
      path -> path
    end
  end
end
