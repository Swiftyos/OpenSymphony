defmodule SymphonyElixir.RunnerTestSupport do
  @moduledoc """
  Shared harness for the runner protocol tests: a real Phoenix endpoint on a
  free loopback port, a stub orchestrator that forwards messages to the test
  process, and run registry entries.
  """

  import ExUnit.Callbacks
  import ExUnit.Assertions

  require Logger

  alias SymphonyElixir.HttpServer
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunnerCommands
  alias SymphonyElixir.RunRegistry
  alias SymphonyElixirWeb.Endpoint

  @secret String.duplicate("r", 64)

  defmodule StubOrchestrator do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts), do: {:ok, %{recipient: Keyword.fetch!(opts, :recipient)}}

    @impl true
    def handle_info(message, state) do
      send(state.recipient, {:orchestrator_message, message})
      {:noreply, state}
    end
  end

  @doc "Starts an endpoint on 127.0.0.1:0 and a stub orchestrator; returns `%{port, secret, orchestrator}`."
  def start_endpoint!(opts \\ []) do
    previous = Application.get_env(:symphony_elixir, Endpoint, [])
    secret = Keyword.get(opts, :secret_key_base, @secret)
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")

    {:ok, _pid} = StubOrchestrator.start_link(name: name, recipient: self())

    config =
      previous
      |> Keyword.merge(
        server: true,
        http: [ip: {127, 0, 0, 1}, port: 0],
        secret_key_base: secret,
        orchestrator: name,
        snapshot_timeout_ms: 200,
        check_origin: false
      )

    Application.put_env(:symphony_elixir, Endpoint, config)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous)
      RunnerCommands.reset()
    end)

    start_supervised!({Endpoint, []})

    if Process.whereis(SymphonyElixir.RunnerCommandPoller.registry()) == nil do
      start_supervised!({Registry, keys: :unique, name: SymphonyElixir.RunnerCommandPoller.registry()})
    end

    port = HttpServer.bound_port()
    assert is_integer(port)

    %{port: port, secret: secret, orchestrator: name, url: "http://127.0.0.1:#{port}"}
  end

  @doc "Points the run registry at a temp file for this test and resets commands."
  def setup_runs!(tmp_root) do
    runs_path = Path.join(tmp_root, "runs.json")
    previous = Application.get_env(:symphony_elixir, :runs_path)

    Application.put_env(:symphony_elixir, :runs_path, runs_path)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :runs_path)
        value -> Application.put_env(:symphony_elixir, :runs_path, value)
      end

      RunnerCommands.reset()
    end)

    runs_path
  end

  @doc "Records `run_id`/`epoch` for `issue_id` in the run registry."
  def record_run!(issue_id, run_id, opts \\ []) do
    epoch = Keyword.get(opts, :epoch, 1)

    :ok =
      RunRegistry.record(issue_id, %{
        run_id: run_id,
        attempt: Keyword.get(opts, :attempt, 0),
        epoch: epoch,
        launcher: SymphonyElixir.RunLauncher.Local,
        ref: Keyword.get(opts, :ref, "test:#{run_id}"),
        started_at_unix_ms: System.system_time(:millisecond),
        metadata: %{
          identifier: Keyword.get(opts, :identifier, "MT-RUNNER-1"),
          backend: Keyword.get(opts, :backend, "claude"),
          issue_title: "Runner protocol",
          labels: []
        }
      })

    RunRegistry.load()[issue_id]
  end

  @doc "A minimal issue for specs and tests."
  def issue_fixture(id, identifier, opts \\ []) do
    %Issue{
      id: id,
      identifier: identifier,
      title: Keyword.get(opts, :title, "Exercise the runner protocol"),
      description: "Runner protocol test harness",
      state: Keyword.get(opts, :state, "In Progress"),
      url: "https://example.org/issues/#{identifier}",
      labels: Keyword.get(opts, :labels, ["backend"])
    }
  end

  @doc "A unique temp directory removed when the test exits."
  def temp_root!(suffix) do
    root = Path.join(System.tmp_dir!(), "symphony-elixir-#{suffix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  @doc "A fake Claude launcher that answers each prompt with one successful turn."
  def write_fake_claude_launcher!(test_root) do
    launcher = Path.join(test_root, "fake-claude-launcher.sh")

    File.write!(
      launcher,
      """
      #!/bin/sh
      session_id=""
      previous_arg=""

      for arg in "$@"; do
        if [ "$previous_arg" = "--session-id" ]; then
          session_id="$arg"
        fi
        previous_arg="$arg"
      done

      while IFS= read -r line; do
        printf '%s\\n' "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"$session_id\\"}"
        printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"session_id\\":\\"$session_id\\",\\"uuid\\":\\"runner-result\\"}"
      done
      """
    )

    File.chmod!(launcher, 0o755)
    launcher
  end
end
