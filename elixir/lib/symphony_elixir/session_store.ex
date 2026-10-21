defmodule SymphonyElixir.SessionStore do
  @moduledoc """
  The agent session each issue is running, so a run cut off by a restart can
  resume its conversation instead of starting the stage over.

  A record (backend, stage, workspace and the Codex thread id or Claude session
  id) is saved when a run's session starts and removed when the run ends, by
  success or by error. A restart kills runs without that cleanup, so a record
  that survives means the run was interrupted, and the next run for the same
  issue, stage, backend and workspace resumes it (`AgentRunner`).

  Kept in `~/.symphony/sessions.json` (owner-only, or Postgres; see
  `StateStore`); in memory when the path is nil (tests).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.StateStore

  @type record :: %{String.t() => String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The interrupted session recorded for an issue, if any."
  @spec get(String.t()) :: record() | nil
  def get(issue_id) when is_binary(issue_id), do: call({:get, issue_id})
  def get(_issue_id), do: nil

  @doc "Records the session a run for the issue has started."
  @spec put(String.t(), record()) :: :ok
  def put(issue_id, %{} = record) when is_binary(issue_id), do: call({:put, issue_id, record}) || :ok
  def put(_issue_id, _record), do: :ok

  @doc "Forgets the issue's session: its run ended, or the record no longer applies."
  @spec delete(String.t()) :: :ok
  def delete(issue_id) when is_binary(issue_id), do: call({:delete, issue_id}) || :ok
  def delete(_issue_id), do: :ok

  defp call(message) do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, message), else: nil
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    {:ok, %{path: path, sessions: load(path)}}
  end

  @impl true
  def handle_call({:get, issue_id}, _from, state), do: {:reply, Map.get(state.sessions, issue_id), state}

  def handle_call({:put, issue_id, record}, _from, state) do
    record = record |> Map.new(fn {key, value} -> {to_string(key), value} end) |> Map.put("saved_at", now())
    {:reply, :ok, save(%{state | sessions: Map.put(state.sessions, issue_id, record)})}
  end

  def handle_call({:delete, issue_id}, _from, state) do
    if Map.has_key?(state.sessions, issue_id),
      do: {:reply, :ok, save(%{state | sessions: Map.delete(state.sessions, issue_id)})},
      else: {:reply, :ok, state}
  end

  defp save(%{path: nil} = state), do: state

  defp save(%{path: path, sessions: sessions} = state) do
    case StateStore.write(path, Jason.encode!(%{"version" => 1, "sessions" => sessions}, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Session store save failed path=#{path} reason=#{inspect(reason)}")
    end

    state
  end

  defp load(nil), do: %{}

  defp load(path) do
    with {:ok, body} <- StateStore.read(path),
         {:ok, %{"sessions" => %{} = sessions}} <- Jason.decode(body) do
      sessions
    else
      {:error, :enoent} ->
        %{}

      other ->
        Logger.warning("Session store unreadable, starting empty path=#{path} reason=#{inspect(other, limit: 5)}")
        %{}
    end
  end

  defp default_path do
    case Application.get_env(:symphony_elixir, :sessions_path, :default) do
      :default -> Path.expand("~/.symphony/sessions.json")
      path -> path
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
