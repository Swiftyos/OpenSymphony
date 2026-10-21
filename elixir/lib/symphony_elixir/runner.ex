defmodule SymphonyElixir.Runner do
  @moduledoc """
  The `symphony runner <spec.json>` entrypoint, without the CLI around it.

  It reads the run spec, starts the reduced runner application (see
  `SymphonyElixir.Application`), runs the issue through `AgentRunner.run/3`
  with `SymphonyElixir.RunHost.Remote`, then posts a `finished` event and
  flushes the outbox before returning. The CLI maps `:ok` to exit status 0 and
  an error to 1. Everything the run does reaches the controller through the
  runner protocol; see `docs/durable-runs.md`.
  """

  require Logger

  alias SymphonyElixir.Accounts
  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.RunHost.Remote
  alias SymphonyElixir.RunnerCommandPoller
  alias SymphonyElixir.RunOutbox
  alias SymphonyElixir.RunSpec

  @flush_timeout_ms 10_000

  @doc "Runs the spec, returning `:ok` or an error; never raises for a failed run."
  @spec run(Path.t()) :: :ok | {:error, term()}
  def run(spec_path) do
    with {:ok, spec} <- RunSpec.read(Path.expand(spec_path)),
         :ok <- start_application() do
      started = ensure_runner_processes()

      try do
        run_spec(spec)
      after
        stop_started(started)
      end
    end
  end

  defp start_application do
    Application.put_env(:symphony_elixir, :app_mode, :runner)

    case Application.ensure_all_started(:symphony_elixir) do
      {:ok, _apps} -> :ok
      {:error, {_app, reason}} -> {:error, reason}
    end
  end

  # In a real runner these are children of the runner application. A test (or
  # any caller giving the app a different start mode first) may not have them,
  # so start the missing ones and stop only those here.
  defp ensure_runner_processes do
    [
      start_missing(Task.Supervisor, fn -> Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor) end),
      start_missing(RunOutbox, fn -> RunOutbox.start_link([]) end),
      start_missing(RunnerCommandPoller.registry(), fn ->
        Registry.start_link(keys: :unique, name: RunnerCommandPoller.registry())
      end)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp start_missing(name, starter) do
    if Process.whereis(name) do
      nil
    else
      case starter.() do
        {:ok, pid} -> pid
        _error -> nil
      end
    end
  end

  defp stop_started(started) do
    Enum.each(started, fn pid ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _reason -> :ok
        end
      end
    end)
  end

  defp run_spec(%RunSpec{} = spec) do
    :ok =
      RunOutbox.configure(
        run_id: spec.run_id,
        base_url: spec.controller_url,
        token: spec.token,
        dir: RunSpec.dir(spec.run_id)
      )

    host = %Remote{
      base_url: spec.controller_url,
      run_id: spec.run_id,
      token: spec.token,
      outbox: Process.whereis(RunOutbox)
    }

    issue = RunSpec.to_issue(spec)
    account = resolve_account(spec.account)

    # The run gets its own process: the agent CLIs are ports linked to it, and a
    # port that dies (an agent that exits at once gives :epipe) would otherwise
    # take the runner down before it could report the run's end.
    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        AgentRunner.run(issue, nil, run_host: host, attempt: spec.attempt, worker_host: spec.worker_host, account: account)
      end)

    try do
      case Task.yield(task, :infinity) do
        {:ok, :ok} ->
          finish(host, "normal")
          :ok

        {:exit, reason} ->
          message = exit_message(reason)
          finish(host, message)
          {:error, message}
      end
    after
      RunOutbox.flush(@flush_timeout_ms)
    end
  end

  defp exit_message({%{__exception__: true} = exception, _stacktrace}), do: Exception.message(exception)
  defp exit_message(reason), do: inspect(reason, limit: 10)

  # The spec names an account by id; the runner reloads the credential from the
  # same config so tokens refreshed on the controller are picked up.
  defp resolve_account(nil), do: nil

  defp resolve_account(%{backend: backend, id: id}) when is_binary(backend) and is_binary(id) do
    case Accounts.get(backend, id) do
      {:ok, account} ->
        account

      {:error, reason} ->
        Logger.warning("Runner could not reload account backend=#{backend} id=#{id} reason=#{inspect(reason, limit: 5)}")
        nil
    end
  rescue
    error ->
      Logger.warning("Runner could not reload account backend=#{backend} id=#{id} reason=#{inspect(error, limit: 5)}")
      nil
  end

  defp finish(%Remote{} = host, reason) when is_binary(reason) do
    RunOutbox.append(host.outbox, "finished", %{run_id: host.run_id, reason: reason})
    :ok
  end
end
