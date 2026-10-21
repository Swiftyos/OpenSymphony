defmodule SymphonyElixir.RunHost do
  @moduledoc """
  The only way an agent run talks to the Symphony controller.

  A run (`SymphonyElixir.AgentRunner` and the backend app servers) reports
  runtime info and agent events, records transcript entries, reads the
  dashboard inbox, steers Codex turns and stores its session through the host
  it is given. It never sends to the orchestrator, or calls `Transcript`,
  `AgentInbox` or `SessionStore`, directly.

  Today the host is `SymphonyElixir.RunHost.Local`, which makes exactly the
  in-process calls the run used to make, so behaviour is unchanged. A later
  step moves the agent loop into its own OS process and talks to the
  controller over HTTP (`RunHost.Remote`), which is what lets a run outlive a
  controller restart; see `docs/durable-runs.md`.

  A host is a value: a struct threaded through the run. Each function below
  dispatches on `host.__struct__`, so implementing the behaviour is all a new
  host needs.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunHost.Local

  @typedoc "A run host: any struct whose module implements this behaviour."
  @type t :: struct()

  @doc "Tells the controller where the run's workspace is (host and path)."
  @callback runtime_info(t(), Issue.t(), String.t() | nil, String.t()) :: :ok

  @doc "Reports the route a run was re-resolved to after a pick-up (backend and effort)."
  @callback route_info(t(), Issue.t(), map()) :: :ok

  @doc """
  Reports an agent event for the issue, after recording it in the issue's
  transcript. The controller message is `{:codex_worker_update, ...}` for the
  codex backend and `{:agent_worker_update, ...}` for any other.
  """
  @callback agent_update(t(), Issue.t(), String.t() | nil, map()) :: :ok

  @doc "Adds a note to the issue's transcript."
  @callback transcript_note(t(), String.t() | nil, String.t()) :: :ok

  @doc "Marks the start of a turn in the issue's transcript."
  @callback turn_started(t(), String.t() | nil, map()) :: :ok

  @doc "The interrupted session recorded for the issue, if any."
  @callback session_get(t(), String.t()) :: map() | nil

  @doc "Records the session the issue's run has started."
  @callback session_put(t(), String.t(), map()) :: :ok

  @doc "Forgets the issue's session: its run ended, or the record no longer applies."
  @callback session_delete(t(), String.t()) :: :ok

  @doc "Registers the calling process as the runner for the issue's dashboard messages."
  @callback inbox_register(t(), map(), String.t() | nil) :: :ok

  @doc "Removes the calling process's runner registration."
  @callback inbox_unregister(t(), String.t() | nil) :: :ok

  @doc "Marks the issue's queued dashboard messages delivered with `next_turn` and returns them."
  @callback inbox_take_queued(t(), String.t() | nil) :: [map()]

  @doc "Whether the issue has dashboard messages that haven't reached an agent yet."
  @callback inbox_queued?(t(), String.t() | nil) :: boolean()

  @doc "The prompt section announcing dashboard messages to the agent."
  @callback inbox_prompt_section(t(), [map()]) :: String.t()

  @doc """
  Records the Codex turn that dashboard messages should steer
  (`%{thread_id, turn_id}`), or `nil` when the turn ended.
  """
  @callback codex_turn(t(), Issue.t(), %{thread_id: String.t(), turn_id: String.t()} | nil) :: :ok

  @doc "One dashboard message for the issue, if it exists."
  @callback inbox_get(t(), String.t(), String.t()) :: map() | nil

  @doc "The text sent into a running Codex turn with `turn/steer`."
  @callback inbox_steer_text(t(), map()) :: String.t()

  @doc "Marks one dashboard message delivered, as `steered` or `next_turn`."
  @callback inbox_mark_delivered(t(), String.t(), String.t(), String.t()) :: :ok

  @spec runtime_info(t(), Issue.t(), String.t() | nil, String.t()) :: :ok
  def runtime_info(host, issue, worker_host, workspace),
    do: host.__struct__.runtime_info(host, issue, worker_host, workspace)

  @spec route_info(t(), Issue.t(), map()) :: :ok
  def route_info(host, issue, route), do: host.__struct__.route_info(host, issue, route)

  @spec agent_update(t(), Issue.t(), String.t() | nil, map()) :: :ok
  def agent_update(host, issue, backend, message),
    do: host.__struct__.agent_update(host, issue, backend, message)

  @spec transcript_note(t(), String.t() | nil, String.t()) :: :ok
  def transcript_note(host, identifier, text),
    do: host.__struct__.transcript_note(host, identifier, text)

  @spec turn_started(t(), String.t() | nil, map()) :: :ok
  def turn_started(host, identifier, info),
    do: host.__struct__.turn_started(host, identifier, info)

  @spec session_get(t(), String.t()) :: map() | nil
  def session_get(host, issue_id), do: host.__struct__.session_get(host, issue_id)

  @spec session_put(t(), String.t(), map()) :: :ok
  def session_put(host, issue_id, record), do: host.__struct__.session_put(host, issue_id, record)

  @spec session_delete(t(), String.t()) :: :ok
  def session_delete(host, issue_id), do: host.__struct__.session_delete(host, issue_id)

  @spec inbox_register(t(), map(), String.t() | nil) :: :ok
  def inbox_register(host, issue, backend), do: host.__struct__.inbox_register(host, issue, backend)

  @spec inbox_unregister(t(), String.t() | nil) :: :ok
  def inbox_unregister(host, identifier), do: host.__struct__.inbox_unregister(host, identifier)

  @spec inbox_take_queued(t(), String.t() | nil) :: [map()]
  def inbox_take_queued(host, identifier), do: host.__struct__.inbox_take_queued(host, identifier)

  @spec inbox_queued?(t(), String.t() | nil) :: boolean()
  def inbox_queued?(host, identifier), do: host.__struct__.inbox_queued?(host, identifier)

  @spec inbox_prompt_section(t(), [map()]) :: String.t()
  def inbox_prompt_section(host, messages), do: host.__struct__.inbox_prompt_section(host, messages)

  @spec codex_turn(t(), Issue.t(), %{thread_id: String.t(), turn_id: String.t()} | nil) :: :ok
  def codex_turn(host, issue, steer), do: host.__struct__.codex_turn(host, issue, steer)

  @spec inbox_get(t(), String.t(), String.t()) :: map() | nil
  def inbox_get(host, identifier, id), do: host.__struct__.inbox_get(host, identifier, id)

  @spec inbox_steer_text(t(), map()) :: String.t()
  def inbox_steer_text(host, message), do: host.__struct__.inbox_steer_text(host, message)

  @spec inbox_mark_delivered(t(), String.t(), String.t(), String.t()) :: :ok
  def inbox_mark_delivered(host, identifier, id, delivery),
    do: host.__struct__.inbox_mark_delivered(host, identifier, id, delivery)

  @doc "The default host for a run: in-process calls to the controller."
  @spec local(pid() | nil) :: Local.t()
  def local(recipient \\ nil), do: Local.new(recipient)
end
