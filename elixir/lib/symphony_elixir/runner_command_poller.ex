defmodule SymphonyElixir.RunnerCommandPoller do
  @moduledoc """
  The runner side of steering: a task that long-polls the controller for
  commands and hands each dashboard message to the process registered for the
  issue in the runner (the agent runner's turn loop).

  `RunHost.Remote.inbox_register/3` starts it, and `inbox_unregister/2` stops
  it. The poller registers itself in `SymphonyElixir.RunnerCommandPoller.Registry`
  (started by the runner's reduced application) so the owner can be found and
  the task stopped.
  """

  require Logger

  alias SymphonyElixir.RunHost.Remote

  @registry SymphonyElixir.RunnerCommandPoller.Registry
  @wait_ms 20_000
  @error_backoff_ms 1_000

  @doc "The registry the poller registers in."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "Whether the runner has the task supervisor and registry the poller needs."
  @spec available?() :: boolean()
  def available? do
    Process.whereis(SymphonyElixir.TaskSupervisor) != nil and Process.whereis(@registry) != nil
  end

  @doc "Starts a poller for `identifier` under the runner's task supervisor, reporting to `owner`."
  @spec start(Remote.t(), String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start(%Remote{} = host, identifier, owner)
      when is_binary(identifier) and is_pid(owner) do
    case Registry.lookup(@registry, identifier) do
      [{pid, _value}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: start_task(host, identifier, owner)

      [] ->
        start_task(host, identifier, owner)
    end
  end

  defp start_task(host, identifier, owner) do
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn -> run(host, identifier, owner) end)
  end

  @doc "Stops the poller registered for `identifier`, if there is one."
  @spec stop(String.t()) :: :ok
  def stop(identifier) when is_binary(identifier) do
    case Registry.lookup(@registry, identifier) do
      [{pid, _value}] ->
        if Process.whereis(SymphonyElixir.TaskSupervisor) do
          Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid)
        else
          Process.exit(pid, :shutdown)
        end

      [] ->
        :ok
    end

    :ok
  end

  def stop(_identifier), do: :ok

  @doc """
  Polls until the task is stopped. `after_seq` starts at 0: the controller
  replays commands this runner hasn't confirmed yet.
  """
  @spec run(Remote.t(), String.t(), pid()) :: no_return()
  def run(%Remote{} = host, identifier, owner) do
    register(identifier, owner)
    loop(host, identifier, owner, 0)
  end

  defp register(identifier, owner) do
    if Process.whereis(@registry) && Registry.lookup(@registry, identifier) == [] do
      Registry.register(@registry, identifier, %{owner: owner})
    end

    :ok
  end

  defp loop(host, identifier, owner, after_seq) do
    commands = Remote.commands(host, after_seq, @wait_ms)

    case commands do
      [] ->
        Process.sleep(@error_backoff_ms)
        loop(host, identifier, owner, after_seq)

      commands ->
        deliver(commands, owner)
        loop(host, identifier, owner, max_seq(commands, after_seq))
    end
  end

  defp deliver(commands, owner) do
    Enum.each(commands, fn command -> deliver_command(command, owner) end)
  end

  defp deliver_command(%{"type" => "agent_inbox", "message_id" => message_id}, owner)
       when is_binary(message_id) do
    send(owner, {:agent_inbox, message_id})
  end

  defp deliver_command(command, _owner) do
    Logger.debug("Runner ignored command: #{inspect(command, limit: 5)}")
  end

  defp max_seq(commands, after_seq) do
    Enum.reduce(commands, after_seq, fn %{"seq" => seq}, acc -> max(acc, seq) end)
  end
end
