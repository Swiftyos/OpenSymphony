defmodule SymphonyElixir.RunnerCommandsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RunnerCommands

  defmodule DyingServer do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)
    @impl true
    def init(_), do: {:ok, nil}
    @impl true
    def handle_call(_message, _from, _state), do: exit(:boom)
  end

  setup do
    RunnerCommands.reset()
    on_exit(&RunnerCommands.reset/0)
    :ok
  end

  test "push assigns increasing seqs and fetch returns only newer commands" do
    assert :ok = RunnerCommands.push("MT-1", %{type: "agent_inbox", message_id: "m1"})
    assert :ok = RunnerCommands.push("MT-1", %{type: "agent_inbox", message_id: "m2"})
    assert :ok = RunnerCommands.push("MT-2", %{message_id: "other"})

    assert [%{seq: 1, type: "agent_inbox", message_id: "m1"}, %{seq: 2, message_id: "m2"}] =
             RunnerCommands.fetch("MT-1", 0, 0)

    assert [%{seq: 2, message_id: "m2"}] = RunnerCommands.fetch("MT-1", 1, 0)
    assert [] = RunnerCommands.fetch("MT-1", 2, 0)
    assert [%{seq: 3, type: "agent_inbox", message_id: "other"}] = RunnerCommands.fetch("MT-2", 0, 0)
  end

  test "a waiting fetch is woken by a push" do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :fetching)
        RunnerCommands.fetch("MT-WAIT", 0, 2_000)
      end)

    assert_receive :fetching

    Process.sleep(50)
    assert :ok = RunnerCommands.push("MT-WAIT", %{message_id: "late"})

    assert [%{seq: 1, message_id: "late"}] = Task.await(task)
  end

  test "a waiting fetch times out empty, and reset releases it" do
    parent = self()
    task = Task.async(fn -> RunnerCommands.fetch("MT-EMPTY", 0, 20) end)
    send(parent, :unused)
    assert [] = Task.await(task)

    waiting = Task.async(fn -> RunnerCommands.fetch("MT-RESET", 0, 5_000) end)
    Process.sleep(50)
    assert :ok = RunnerCommands.reset()
    assert [] = Task.await(waiting)
  end

  test "events apply once each, in seq order, and stop at finished" do
    parent = self()

    events = [
      %{seq: 2, type: "agent_update", data: %{backend: "claude"}},
      %{seq: 1, type: "runtime_info", data: %{worker_host: nil}},
      %{seq: 2, type: "agent_update", data: %{backend: "duplicate"}},
      %{seq: 3, type: "finished", data: %{reason: "normal"}},
      %{seq: 4, type: "agent_update", data: %{backend: "after"}}
    ]

    fun = fn event -> send(parent, {:applied, event.seq, event.type, event.data}) end

    assert {:ok, 3} = RunnerCommands.apply_events("run-1", events, fun)
    assert_receive {:applied, 1, "runtime_info", _}
    assert_receive {:applied, 2, "agent_update", %{backend: "claude"}}
    assert_receive {:applied, 3, "finished", %{reason: "normal"}}
    refute_received {:applied, 4, _, _}

    assert RunnerCommands.last_seq("run-1") == 3
    assert RunnerCommands.finished?("run-1")

    # A replay applies nothing; a finished run is over for every further batch.
    assert {:error, :finished} = RunnerCommands.apply_events("run-1", events, fun)
    refute_received {:applied, _, _, _}

    assert {:error, :finished} = RunnerCommands.apply_events("run-1", [%{seq: 5, type: "heartbeat", data: %{}}], fun)

    # A finished event without a reason still counts as finished.
    assert {:ok, 1} =
             RunnerCommands.apply_events("run-2", [%{seq: 1, type: "finished", data: %{}}], fn _ -> :ok end)

    # A string reason is kept as-is.
    assert {:ok, 1} =
             RunnerCommands.apply_events("run-4", [%{seq: 1, type: "finished", data: %{"reason" => "why"}}], fn _ -> :ok end)

    assert RunnerCommands.finished?("run-4")

    assert {:ok, 0} =
             RunnerCommands.apply_events("run-3", [%{seq: 0, type: "nope", data: %{}}, %{bad: true}], fn _ -> :ok end)
  end

  test "the process reports unavailable when it is not registered" do
    pid = Process.whereis(RunnerCommands)
    Process.unregister(RunnerCommands)

    try do
      assert :ok = RunnerCommands.push("MT-1", %{})
      assert [] = RunnerCommands.fetch("MT-1", 0, 10)
      assert {:error, :unavailable} = RunnerCommands.apply_events("run-1", [], fn _ -> :ok end)
      refute RunnerCommands.finished?("run-1")
      assert RunnerCommands.last_seq("run-1") == 0
      assert :ok = RunnerCommands.reset()
    after
      Process.register(pid, RunnerCommands)
    end
  end

  test "invalid arguments are ignored" do
    assert :ok = RunnerCommands.push(nil, %{})
    assert :ok = RunnerCommands.push("MT-1", :nope)
    assert [] = RunnerCommands.fetch(nil, 0, 0)
    assert [] = RunnerCommands.fetch("MT-1", -1, 0)
    assert {:error, :unavailable} = RunnerCommands.apply_events(nil, [], fn _ -> :ok end)
    assert {:error, :unavailable} = RunnerCommands.apply_events("run-1", :nope, fn _ -> :ok end)
    assert {:error, :unavailable} = RunnerCommands.apply_events("run-1", [], :nope)
    refute RunnerCommands.finished?(nil)
    assert RunnerCommands.last_seq(nil) == 0
  end

  test "a crash while calling is reported and degrades" do
    pid = Process.whereis(RunnerCommands)
    Process.unregister(RunnerCommands)
    {:ok, dying} = DyingServer.start_link([])
    Process.unlink(dying)
    Process.register(dying, RunnerCommands)

    try do
      assert [] = RunnerCommands.fetch("MT-DEAD", 0, 10)
    after
      if Process.whereis(RunnerCommands), do: Process.unregister(RunnerCommands)
      Process.register(pid, RunnerCommands)
    end
  end

  test "a crash while resetting is reported and degrades" do
    pid = Process.whereis(RunnerCommands)
    Process.unregister(RunnerCommands)
    {:ok, dying} = DyingServer.start_link([])
    Process.unlink(dying)
    Process.register(dying, RunnerCommands)

    try do
      assert :ok = RunnerCommands.reset()
    after
      if Process.whereis(RunnerCommands), do: Process.unregister(RunnerCommands)
      Process.register(pid, RunnerCommands)
    end
  end

  test "unknown messages and stale waiter timeouts are ignored" do
    send(RunnerCommands, :not_a_command)
    send(RunnerCommands, {:waiter_timeout, make_ref()})
    Process.sleep(20)
    assert Process.alive?(Process.whereis(RunnerCommands))
  end

  test "a waiter for a high seq is kept by lower pushes and woken by a later one" do
    task = Task.async(fn -> RunnerCommands.fetch("MT-HIGH", 10, 2_000) end)
    Process.sleep(50)

    for n <- 1..10, do: RunnerCommands.push("MT-HIGH", %{message_id: "low-#{n}"})
    Process.sleep(20)
    refute Task.yield(task, 10)

    assert :ok = RunnerCommands.push("MT-HIGH", %{message_id: "high"})
    assert [%{seq: 11, message_id: "high"}] = Task.await(task)
  end

  test "a push for another issue leaves a waiter parked" do
    task = Task.async(fn -> RunnerCommands.fetch("MT-PARKED", 99, 500) end)
    Process.sleep(50)

    assert :ok = RunnerCommands.push("MT-OTHER", %{message_id: "other"})
    assert :ok = RunnerCommands.push("MT-PARKED", %{message_id: "still-low"})
    refute Task.yield(task, 10)

    for _n <- 1..100, do: RunnerCommands.push("MT-PARKED", %{message_id: "high"})
    assert [%{seq: 100}] = Task.await(task)
  end

  test "fetch defaults are allowed" do
    assert [] = RunnerCommands.fetch("MT-DEFAULT")
    assert [] = RunnerCommands.fetch("MT-DEFAULT", 0)
  end
end
