defmodule SymphonyElixir.RunHost.Local do
  @moduledoc """
  The in-process run host: exactly the calls a run made to the controller
  before the run host seam existed.

  `recipient` is the orchestrator process that `SymphonyElixir.AgentRunner.run/3`
  receives as its update recipient, or `nil` when nobody is listening (tests,
  live e2e). Everything else goes to `SymphonyElixir.Transcript`,
  `SymphonyElixir.AgentInbox` and `SymphonyElixir.SessionStore` as before.
  """

  @behaviour SymphonyElixir.RunHost

  alias SymphonyElixir.AgentInbox
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SessionStore
  alias SymphonyElixir.Transcript

  defstruct recipient: nil

  @type t :: %__MODULE__{recipient: pid() | nil}

  @doc "A host that reports to `recipient`, if one is given."
  @spec new(pid() | nil) :: t()
  def new(recipient \\ nil), do: %__MODULE__{recipient: recipient}

  @impl true
  def runtime_info(%__MODULE__{recipient: recipient}, %Issue{id: issue_id}, worker_host, workspace)
      when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  def runtime_info(_host, _issue, _worker_host, _workspace), do: :ok

  @impl true
  def route_info(%__MODULE__{recipient: recipient}, %Issue{id: issue_id}, route)
      when is_binary(issue_id) and is_pid(recipient) and is_map(route) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         backend: Map.get(route, :backend),
         effort: Map.get(route, :effort)
       }}
    )

    :ok
  end

  def route_info(_host, _issue, _route), do: :ok

  @impl true
  def agent_update(%__MODULE__{recipient: recipient}, issue, backend, message) do
    Transcript.record(issue_identifier(issue), message, backend: backend)
    send_agent_update(recipient, issue, backend, message)
  end

  @impl true
  def transcript_note(_host, identifier, text), do: Transcript.note(identifier, text)

  @impl true
  def turn_started(_host, identifier, info), do: Transcript.turn_started(identifier, info)

  @impl true
  def session_get(_host, issue_id), do: SessionStore.get(issue_id)

  @impl true
  def session_put(_host, issue_id, record), do: SessionStore.put(issue_id, record)

  @impl true
  def session_delete(_host, issue_id), do: SessionStore.delete(issue_id)

  @impl true
  def inbox_register(_host, issue, backend), do: AgentInbox.register_runner(issue, backend)

  @impl true
  def inbox_unregister(_host, identifier), do: AgentInbox.unregister_runner(identifier)

  @impl true
  def inbox_take_queued(_host, identifier), do: AgentInbox.take_queued(identifier)

  @impl true
  def inbox_queued?(_host, identifier), do: AgentInbox.queued?(identifier)

  @impl true
  def inbox_prompt_section(_host, messages), do: AgentInbox.prompt_section(messages)

  @impl true
  def codex_turn(_host, issue, steer), do: AgentInbox.codex_turn(issue, steer)

  @impl true
  def inbox_get(_host, identifier, id), do: AgentInbox.get(identifier, id)

  @impl true
  def inbox_steer_text(_host, message), do: AgentInbox.steer_text(message)

  @impl true
  def inbox_mark_delivered(_host, identifier, id, delivery),
    do: AgentInbox.mark_delivered(identifier, id, delivery)

  defp send_agent_update(recipient, %Issue{id: issue_id}, "codex", message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, _backend, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _backend, _message), do: :ok

  defp issue_identifier(%Issue{identifier: identifier}), do: identifier
end
