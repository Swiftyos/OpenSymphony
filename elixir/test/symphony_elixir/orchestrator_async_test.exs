defmodule SymphonyElixir.OrchestratorAsyncTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunLauncher.Local

  # A Linear client that hands every tracker call to the test. The gate can
  # block or crash a call, so the test controls how long the orchestrator's
  # poll task is in flight.
  defmodule AsyncTrackerClient do
    @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
    def fetch_candidate_issues do
      gate(:fetch_candidate_issues, [])

      count = Application.get_env(:symphony_elixir, :async_tracker_candidate_fetches, 0) + 1
      Application.put_env(:symphony_elixir, :async_tracker_candidate_fetches, count)
      send_recipient({:candidate_fetched, self(), count})

      if count in List.wrap(Application.get_env(:symphony_elixir, :async_tracker_crash_on_fetch)) do
        raise "the tracker is down"
      end

      {:ok, issues()}
    end

    @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
    def fetch_issue_states_by_ids(issue_ids) do
      send_recipient({:states_fetched, self(), issue_ids})

      Enum.each(issue_ids, fn issue_id ->
        gate(:fetch_issue_states_by_ids, issue_id)

        case Map.get(Application.get_env(:symphony_elixir, :async_tracker_state_delays, %{}), issue_id, 0) do
          delay_ms when is_integer(delay_ms) and delay_ms > 0 -> Process.sleep(delay_ms)
          _ -> :ok
        end
      end)

      {:ok, Enum.filter(issues(), &(&1.id in issue_ids))}
    end

    @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issues_by_states(states) do
      normalized = Enum.map(states, &normalize_state/1)
      {:ok, Enum.filter(issues(), &(normalize_state(&1.state) in normalized))}
    end

    defp gate(name, detail) do
      send_recipient({:tracker_gate, name, detail, self()})

      case Application.get_env(:symphony_elixir, :async_tracker_gate, :open) do
        :block ->
          receive do
            {:release, pid} when pid == self() -> :ok
          after
            5_000 -> :ok
          end

        :crash ->
          raise "the tracker is down"

        _ ->
          :ok
      end
    end

    defp issues, do: Application.get_env(:symphony_elixir, :async_tracker_issues, [])

    defp send_recipient(message) do
      case Application.get_env(:symphony_elixir, :async_tracker_recipient) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end

    defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
    defp normalize_state(_state), do: ""
  end

  # Starts runs that never execute AgentRunner, recording the issue the
  # orchestrator dispatched so the test can see the dispatch order.
  defmodule RecordingLauncher do
    @behaviour SymphonyElixir.RunLauncher

    @impl true
    def start(fun, _opts) do
      issue_identifier =
        fun
        |> :erlang.fun_info(:env)
        |> elem(1)
        |> Enum.find_value(fn
          %Issue{identifier: identifier} -> identifier
          _ -> nil
        end)

      send(Application.fetch_env!(:symphony_elixir, :async_tracker_recipient), {:launched, issue_identifier})

      Local.start(
        fn ->
          receive do
            :stop -> :ok
          after
            10_000 -> :ok
          end
        end,
        []
      )
    end

    @impl true
    def alive?(ref), do: Local.alive?(ref)

    @impl true
    def stop(ref), do: Local.stop(ref)
  end

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-orchestrator-async-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: test_root,
      poll_interval_ms: 30_000,
      max_concurrent_agents: 5
    )

    previous = %{
      linear_client_module: Application.get_env(:symphony_elixir, :linear_client_module),
      run_launcher: Application.get_env(:symphony_elixir, :run_launcher)
    }

    Application.put_env(:symphony_elixir, :linear_client_module, AsyncTrackerClient)
    Application.put_env(:symphony_elixir, :async_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :async_tracker_issues, [])
    Application.put_env(:symphony_elixir, :async_tracker_candidate_fetches, 0)
    Application.delete_env(:symphony_elixir, :async_tracker_crash_on_fetch)
    Application.delete_env(:symphony_elixir, :async_tracker_state_delays)
    Application.put_env(:symphony_elixir, :async_tracker_gate, :open)

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous.linear_client_module)
      restore_app_env(:run_launcher, previous.run_launcher)
      Application.delete_env(:symphony_elixir, :async_tracker_recipient)
      Application.delete_env(:symphony_elixir, :async_tracker_issues)
      Application.delete_env(:symphony_elixir, :async_tracker_candidate_fetches)
      Application.delete_env(:symphony_elixir, :async_tracker_crash_on_fetch)
      Application.delete_env(:symphony_elixir, :async_tracker_state_delays)
      Application.delete_env(:symphony_elixir, :async_tracker_gate)
      File.rm_rf(test_root)
    end)

    %{test_root: test_root}
  end

  test "snapshot and request_refresh answer while the poll task is waiting on the tracker" do
    Application.put_env(:symphony_elixir, :async_tracker_gate, :block)
    {pid, name} = start_orchestrator()

    assert_receive {:tracker_gate, :fetch_candidate_issues, [], task_pid}, 2_000

    {snapshot_ms, snapshot} = timed(fn -> Orchestrator.snapshot(name, 200) end)
    assert is_map(snapshot)
    assert snapshot_ms < 200

    {refresh_ms, refresh} = timed(fn -> Orchestrator.request_refresh(name) end)
    assert %{queued: true, coalesced: true} = refresh
    assert refresh_ms < 200

    send(task_pid, {:release, task_pid})
    wait_until(fn -> :sys.get_state(pid).poll_task == nil end)
  end

  test "the async poll dispatches the chosen issues in the same order even when refreshes finish out of order" do
    Application.put_env(:symphony_elixir, :run_launcher, RecordingLauncher)

    issues = [
      queued_issue("issue-high", "MT-ASYNC-1", 1),
      queued_issue("issue-mid", "MT-ASYNC-2", 2),
      queued_issue("issue-low", "MT-ASYNC-3", 4)
    ]

    Application.put_env(:symphony_elixir, :async_tracker_issues, issues)
    # The first chosen issue is refreshed last, so dispatch must wait for it.
    Application.put_env(:symphony_elixir, :async_tracker_state_delays, %{"issue-high" => 100})
    {pid, _name} = start_orchestrator()

    assert_receive {:launched, "MT-ASYNC-1"}, 2_000
    assert_receive {:launched, "MT-ASYNC-2"}, 2_000
    assert_receive {:launched, "MT-ASYNC-3"}, 2_000

    wait_until(fn -> map_size(:sys.get_state(pid).running) == 3 end)
    assert Enum.sort(Map.keys(:sys.get_state(pid).running)) == ["issue-high", "issue-low", "issue-mid"]
  end

  test "a crashed fetch task is logged and the next tick still polls" do
    Application.put_env(:symphony_elixir, :async_tracker_crash_on_fetch, [1])
    Application.put_env(:symphony_elixir, :async_tracker_gate, :open)

    log =
      capture_log(fn ->
        {pid, _name} = start_orchestrator()

        assert_receive {:candidate_fetched, _task_pid, 1}, 2_000
        wait_until(fn -> :sys.get_state(pid).poll_task == nil end)

        send(pid, :tick)
        assert_receive {:candidate_fetched, _task_pid, 2}, 2_000
      end)

    assert log =~ "Poll cycle failed"
  end

  test "two refresh requests during one poll add at most one more poll" do
    Application.put_env(:symphony_elixir, :async_tracker_gate, :block)
    {pid, name} = start_orchestrator()

    assert_receive {:tracker_gate, :fetch_candidate_issues, [], task_pid}, 2_000
    assert %{queued: true, coalesced: true} = Orchestrator.request_refresh(name)
    assert %{queued: true, coalesced: true} = Orchestrator.request_refresh(name)

    send(task_pid, {:release, task_pid})
    wait_until(fn -> :sys.get_state(pid).poll_task == nil end)

    refute_receive {:tracker_gate, :fetch_candidate_issues, [], _pid}, 200
  end

  defp queued_issue(id, identifier, priority) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Async dispatch " <> identifier,
      state: "Todo",
      priority: priority,
      labels: []
    }
  end

  defp start_orchestrator do
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {pid, name}
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  defp timed(fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started_at, result}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
