defmodule SymphonyElixir.RunOutboxTest do
  use SymphonyElixir.TestSupport

  # Real git/process/HTTP integration; excluded by `make test-fast`.
  @moduletag :slow

  import ExUnit.CaptureLog

  alias SymphonyElixir.RunnerCommands
  alias SymphonyElixir.RunnerTestSupport, as: Support
  alias SymphonyElixir.RunOutbox
  alias SymphonyElixir.RunToken

  defmodule RawResponseServer do
    def start(body) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      response = "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      pid = spawn(fn -> accept(listen, response) end)
      {pid, port}
    end

    defp accept(listen, response) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          _request = read_request(socket, "")
          :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)
          accept(listen, response)

        _error ->
          :ok
      end
    end

    defp read_request(socket, acc) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> maybe_complete(socket, acc <> data)
        _error -> acc
      end
    end

    defp maybe_complete(socket, request) do
      case String.split(request, "\r\n\r\n", parts: 2) do
        [_headers, body] ->
          if byte_size(body) >= content_length(request), do: request, else: read_request(socket, request)

        _ ->
          read_request(socket, request)
      end
    end

    defp content_length(request) do
      case Regex.run(~r/content-length: (\d+)/i, request) do
        [_all, length] -> String.to_integer(length)
        _ -> 0
      end
    end
  end

  setup do
    root = Support.temp_root!("run-outbox")
    Support.setup_runs!(root)
    endpoint = Support.start_endpoint!()
    %{root: root, endpoint: endpoint}
  end

  defp start_outbox!(name, opts) do
    start_supervised!({RunOutbox, Keyword.put(opts, :name, name)})
  end

  test "batches events to the controller, persists them, and flushes when acked", %{root: root, endpoint: endpoint} do
    Support.record_run!("issue-1", "run-1", identifier: "MT-O-1", backend: "claude")
    name = :"outbox-#{System.unique_integer([:positive])}"
    dir = Path.join(root, "runs/run-1")
    outbox = start_outbox!(name, run_id: "run-1", base_url: endpoint.url, token: RunToken.sign("run-1", 1), dir: dir)

    RunOutbox.append(outbox, "runtime_info", %{issue_id: "issue-1", worker_host: "build-1", workspace_path: "/ws"})
    RunOutbox.append(outbox, "heartbeat", %{})

    assert :ok = RunOutbox.flush(5_000, outbox)
    assert_receive {:orchestrator_message, {:worker_runtime_info, "issue-1", %{worker_host: "build-1"}}}
    assert RunnerCommands.last_seq("run-1") == 2

    lines = dir |> Path.join("outbox.jsonl") |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 2
    assert [%{"seq" => 1, "type" => "runtime_info"}, %{"seq" => 2, "type" => "heartbeat"}] = Enum.map(lines, &Jason.decode!/1)

    # Crossing the 50-event threshold sends without waiting for the timer.
    for n <- 3..62, do: RunOutbox.append(outbox, "heartbeat", %{n: n})
    assert :ok = RunOutbox.flush(5_000, outbox)
    assert RunnerCommands.last_seq("run-1") == 62
  end

  test "keeps buffering while the controller is unreachable, then replays the file", %{root: root, endpoint: endpoint} do
    Support.record_run!("issue-1", "run-2", identifier: "MT-O-2")
    name = :"outbox-#{System.unique_integer([:positive])}"
    dir = Path.join(root, "runs/run-2")
    token = RunToken.sign("run-2", 1)

    outbox =
      start_outbox!(name,
        run_id: "run-2",
        base_url: "http://127.0.0.1:1",
        token: token,
        dir: dir
      )

    RunOutbox.append(outbox, "runtime_info", %{issue_id: "issue-1", worker_host: "offline", workspace_path: "/ws"})
    Process.sleep(300)
    assert File.exists?(Path.join(dir, "outbox.jsonl"))

    # Reconfiguring reloads the file and points at the live controller.
    capture_log(fn ->
      assert :ok = RunOutbox.configure(name: name, run_id: "run-2", base_url: endpoint.url, token: token, dir: dir)
      assert :ok = RunOutbox.flush(5_000, outbox)
    end)

    assert_receive {:orchestrator_message, {:worker_runtime_info, "issue-1", %{worker_host: "offline"}}}
    assert RunnerCommands.last_seq("run-2") == 1
  end

  test "a stale epoch stops the outbox with {:shutdown, :stale_epoch}", %{root: root, endpoint: endpoint} do
    Support.record_run!("issue-1", "run-3", epoch: 1, identifier: "MT-O-3")
    stale_token = RunToken.sign("run-3", 1)
    Support.record_run!("issue-1", "run-3", epoch: 2, identifier: "MT-O-3")

    name = :"outbox-#{System.unique_integer([:positive])}"
    Process.flag(:trap_exit, true)

    {:ok, outbox} =
      RunOutbox.start_link(
        name: name,
        run_id: "run-3",
        base_url: endpoint.url,
        token: stale_token,
        dir: Path.join(root, "runs/run-3")
      )

    try do
      RunOutbox.append(outbox, "heartbeat", %{})
      assert_receive {:EXIT, ^outbox, {:shutdown, :stale_epoch}}, 5_000
    after
      Process.flag(:trap_exit, false)
    end
  end

  test "an unconfigured outbox ignores events and flushes immediately", %{root: root} do
    name = :"outbox-#{System.unique_integer([:positive])}"
    outbox = start_outbox!(name, [])

    capture_log(fn ->
      assert :ok = RunOutbox.append(outbox, "heartbeat", %{})
    end) =~ "before it is configured"

    assert :ok = RunOutbox.flush(0, outbox)
    assert :ok = RunOutbox.flush(0)
    assert :ok = RunOutbox.append("heartbeat", %{})
    assert :ok = RunOutbox.flush(0, Path.join(root, "not-a-pid"))
  end

  test "a success without a usable acknowledgement keeps the events", %{root: root} do
    Support.record_run!("issue-1", "run-raw", identifier: "MT-O-RAW")
    {server, port} = RawResponseServer.start("not json")
    on_exit(fn -> Process.exit(server, :kill) end)
    name = :"outbox-#{System.unique_integer([:positive])}"

    outbox =
      start_outbox!(name,
        run_id: "run-raw",
        base_url: "http://127.0.0.1:#{port}",
        token: RunToken.sign("run-raw", 1),
        dir: Path.join(root, "runs/run-raw")
      )

    RunOutbox.append(outbox, "heartbeat", %{})
    Process.sleep(500)
    assert RunnerCommands.last_seq("run-raw") == 0
    assert :ok = RunOutbox.flush(100, outbox)
  end

  test "a raw JSON acknowledgement string is decoded", %{root: root} do
    Support.record_run!("issue-1", "run-raw-json", identifier: "MT-O-RAW")
    {server, port} = RawResponseServer.start(~s({"applied_through":1}))
    on_exit(fn -> Process.exit(server, :kill) end)
    name = :"outbox-#{System.unique_integer([:positive])}"

    outbox =
      start_outbox!(name,
        run_id: "run-raw-json",
        base_url: "http://127.0.0.1:#{port}",
        token: RunToken.sign("run-raw-json", 1),
        dir: Path.join(root, "runs/run-raw-json")
      )

    RunOutbox.append(outbox, "heartbeat", %{})
    assert :ok = RunOutbox.flush(2_000, outbox)
  end

  test "the default start_link arity is available" do
    {:ok, default} = RunOutbox.start_link()
    GenServer.stop(default)
  end

  test "more than one batch is sent and the remainder is flushed on the next tick", %{root: root, endpoint: endpoint} do
    Support.record_run!("issue-1", "run-big", identifier: "MT-O-BIG")
    name = :"outbox-#{System.unique_integer([:positive])}"

    outbox =
      start_outbox!(name,
        run_id: "run-big",
        base_url: endpoint.url,
        token: RunToken.sign("run-big", 1),
        dir: Path.join(root, "runs/run-big")
      )

    for n <- 1..150, do: RunOutbox.append(outbox, "heartbeat", %{n: n})
    assert :ok = RunOutbox.flush(10_000, outbox)
    assert RunnerCommands.last_seq("run-big") == 150
  end

  test "map options, a missing directory, and garbage lines load sensibly", %{root: root} do
    name = :"outbox-#{System.unique_integer([:positive])}"
    outbox = start_outbox!(name, [])
    dir = Path.join(root, "runs/run-map")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "outbox.jsonl"), """
    not json
    {"seq":0,"type":"heartbeat","data":"e30="}
    {"seq":1,"type":"heartbeat","data":"e30="}
    {"seq":"bad","type":"heartbeat","data":"e30="}
    """)

    assert :ok = RunOutbox.configure(%{name: name, run_id: "run-map", base_url: "http://127.0.0.1:1", token: "t", dir: dir})
    assert :ok = RunOutbox.flush(0, outbox)
    assert :ok = RunOutbox.configure(name: name, run_id: "run-no-dir")
    assert :ok = RunOutbox.append(outbox, "heartbeat", %{})
    assert :ok = RunOutbox.flush(0, outbox)
    send(outbox, :ignored)
    Process.sleep(20)
    assert Process.alive?(outbox)
  end

  test "a write failure is logged, not raised", %{root: root} do
    Support.record_run!("issue-1", "run-write", identifier: "MT-O-WRITE")
    name = :"outbox-#{System.unique_integer([:positive])}"
    file = Path.join(root, "not-a-dir")
    File.write!(file, "")
    outbox = start_outbox!(name, run_id: "run-write", base_url: "http://127.0.0.1:1", token: "t", dir: file)

    log =
      capture_log(fn ->
        RunOutbox.append(outbox, "heartbeat", %{})
        Process.sleep(50)
      end)

    assert log =~ "Run outbox write failed"
  end

  test "the default server and a run id without a directory are accepted" do
    {:ok, default} = RunOutbox.start_link([])
    GenServer.stop(default)
    start_supervised!({RunOutbox, []})
    assert :ok = RunOutbox.configure(:any_opts)
    assert :ok = RunOutbox.append("heartbeat", %{})
    assert :ok = RunOutbox.flush(0)
  end

  test "a run id without a directory has no file", %{root: root} do
    name = :"outbox-#{System.unique_integer([:positive])}"
    outbox = start_outbox!(name, [])

    assert :ok =
             RunOutbox.configure(
               name: name,
               run_id: nil,
               base_url: "http://127.0.0.1:1",
               token: "t",
               dir: root
             )

    assert :ok = RunOutbox.append(outbox, "heartbeat", %{})
    refute File.exists?(Path.join(root, "outbox.jsonl"))
  end

  test "a successful send with nothing waiting flushes without a waiter", %{root: root, endpoint: endpoint} do
    Support.record_run!("issue-1", "run-fresh", identifier: "MT-O-FRESH")
    name = :"outbox-#{System.unique_integer([:positive])}"
    {:ok, outbox} = RunOutbox.start_link(name: name, run_id: "run-fresh", base_url: endpoint.url, token: RunToken.sign("run-fresh", 1), dir: Path.join(root, "runs/run-fresh"))

    try do
      RunOutbox.append(outbox, "heartbeat", %{})

      SymphonyElixir.TestSupport.wait_until(
        fn -> RunnerCommands.last_seq("run-fresh") == 1 end,
        2_000
      )

      assert RunnerCommands.last_seq("run-fresh") == 1
      assert :ok = RunOutbox.flush(0, outbox)
    after
      if Process.alive?(outbox), do: GenServer.stop(outbox)
    end
  end

  test "an endpoint that answers with an error is retried", %{root: root, endpoint: endpoint} do
    Support.record_run!("issue-1", "run-4", identifier: "MT-O-4")
    name = :"outbox-#{System.unique_integer([:positive])}"

    outbox =
      start_outbox!(name,
        run_id: "run-4",
        base_url: endpoint.url,
        token: "bad-token",
        dir: Path.join(root, "runs/run-4")
      )

    capture_log(fn ->
      RunOutbox.append(outbox, "heartbeat", %{})
      Process.sleep(300)
    end)

    assert Process.alive?(outbox)
    assert File.exists?(Path.join([root, "runs/run-4", "outbox.jsonl"]))
  end
end
