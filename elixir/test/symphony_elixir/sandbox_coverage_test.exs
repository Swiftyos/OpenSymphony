defmodule SymphonyElixir.SandboxCoverageTest do
  use SymphonyElixir.TestSupport

  # Real git/process/HTTP integration; excluded by `make test-fast`.
  @moduletag :slow

  alias SymphonyElixir.Sandbox

  # Every docker call goes to a fake `docker` script in a temp dir. The script
  # logs its arguments and answers with canned output/status per subcommand.
  setup do
    root = Path.join(System.tmp_dir!(), "symphony-sandbox-coverage-#{System.unique_integer([:positive])}")
    fake_dir = Path.join(root, "fake-docker")
    workspace = Path.join(root, "workspaces/MT-1")
    File.mkdir_p!(fake_dir)
    File.mkdir_p!(workspace)

    docker = Path.join(fake_dir, "docker")

    File.write!(docker, """
    #!/bin/sh
    dir="#{fake_dir}"
    printf '%s\\n' "$*" >> "$dir/calls.log"
    if [ -f "$dir/hang" ] && printf '%s' "$*" | grep -qF -- "$(cat "$dir/hang")"; then
      exec sleep 30
    fi
    cmd="$1"
    key="$cmd"
    if [ "$cmd" = "network" ]; then
      key="network-$2"
    elif [ "$cmd" = "inspect" ] || [ "$cmd" = "start" ] || [ "$cmd" = "stop" ]; then
      last=$(printf '%s\n' "$@" | tail -n 1)
      key="$cmd-$last"
    fi
    if [ -f "$dir/$key.out" ]; then
      cat "$dir/$key.out"
    elif [ -f "$dir/$cmd.out" ]; then
      cat "$dir/$cmd.out"
    fi
    if [ -f "$dir/$key.status" ]; then
      exit "$(cat "$dir/$key.status")"
    elif [ -f "$dir/$cmd.status" ]; then
      exit "$(cat "$dir/$cmd.status")"
    fi
    exit 0
    """)

    File.chmod!(docker, 0o755)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, fake_dir: fake_dir, docker: docker, workspace: workspace}
  end

  defp settings(ctx, sandbox_overrides \\ %{}) do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(ctx.root, "workspaces"))
    settings = Config.settings!()

    sandbox =
      settings.sandbox
      |> Map.merge(%{kind: "docker", command: ctx.docker, image: "symphony-test:latest"})
      |> Map.merge(sandbox_overrides)

    %{settings | sandbox: sandbox}
  end

  defp respond(ctx, cmd, output, status) do
    File.write!(Path.join(ctx.fake_dir, "#{cmd}.out"), output)
    File.write!(Path.join(ctx.fake_dir, "#{cmd}.status"), Integer.to_string(status))
  end

  defp calls(ctx) do
    case File.read(Path.join(ctx.fake_dir, "calls.log")) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  # Configures the workflow file itself for the fake docker, for the
  # `Config.settings!()` default-argument paths.
  defp write_docker_workflow!(ctx) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, workspace_root: Path.join(ctx.root, "workspaces"))
    "---\n" <> rest = File.read!(path)

    sandbox = """
    ---
    sandbox:
      kind: docker
      command: #{inspect(ctx.docker)}
      image: symphony-test:latest
    """

    File.write!(path, sandbox <> rest)
    WorkflowStore.force_reload()
    assert Config.settings!().sandbox.kind == "docker"
  end

  test "enabled?/0 and validate_run/3 read the sandbox kind", ctx do
    refute Sandbox.enabled?()
    assert Sandbox.validate_run("codex", "host-1") == :ok

    docker = settings(ctx)
    assert Sandbox.enabled?(docker)
    assert Sandbox.validate_run("claude", nil, docker) == :ok
    assert Sandbox.validate_run("codex", "worker-1", docker) == {:error, {:sandbox_unsupported, :ssh_worker_host, "worker-1"}}
    assert Sandbox.validate_run("opencode", nil, docker) == {:error, {:sandbox_unsupported, :backend, "opencode"}}
  end

  test "ensure_container reuses a running container", ctx do
    respond(ctx, "inspect", "true\n", 0)
    name = Sandbox.container_name(ctx.workspace)

    assert :ok = Sandbox.ensure_container(ctx.workspace, settings(ctx))
    assert calls(ctx) == ["inspect --format {{.State.Running}} #{name}"]
  end

  test "ensure_container restarts a stopped container and reports start failures", ctx do
    name = Sandbox.container_name(ctx.workspace)
    respond(ctx, "inspect", "false\n", 0)

    assert :ok = Sandbox.ensure_container(ctx.workspace, settings(ctx))
    assert List.last(calls(ctx)) == "start #{name}"

    respond(ctx, "start", "cannot start", 3)

    assert {:error, {:sandbox_start_failed, 3, "cannot start"}} =
             Sandbox.ensure_container(ctx.workspace, settings(ctx))
  end

  test "ensure_container creates a missing container with mounts, network, and run args", ctx do
    respond(ctx, "inspect", "Error: no such container", 1)
    name = Sandbox.container_name(ctx.workspace)

    overrides = %{
      mounts: ["~/symphony-cache:/cache:ro", "/opt/tools"],
      network: "symphony-net",
      run_args: ["--memory", "2g"]
    }

    settings = settings(ctx, overrides)

    log = capture_log(fn -> assert :ok = Sandbox.ensure_container(ctx.workspace, settings) end)
    assert log =~ "Starting sandbox container name=#{name} image=symphony-test:latest"

    [_inspect, run] = calls(ctx)
    store_root = settings.accounts.store_root
    home = System.user_home!()

    assert run ==
             Enum.join(
               [
                 "run --detach --init --name #{name} --label symphony.workspace=#{ctx.workspace}",
                 "--workdir #{ctx.workspace}",
                 "--volume #{ctx.workspace}:#{ctx.workspace}",
                 "--volume #{store_root}:#{store_root}",
                 "--volume #{home}/symphony-cache:/cache:ro",
                 "--volume /opt/tools:/opt/tools",
                 "--network symphony-net --memory 2g",
                 "--entrypoint sleep symphony-test:latest infinity"
               ],
               " "
             )

    respond(ctx, "run", String.duplicate("x", 3_000), 125)

    capture_log(fn ->
      assert {:error, {:sandbox_create_failed, 125, output}} = Sandbox.ensure_container(ctx.workspace, settings)
      assert String.length(output) == 2_048
    end)
  end

  test "a missing docker command is reported instead of raising", ctx do
    settings = settings(ctx, %{command: "symphony-missing-docker-#{System.unique_integer([:positive])}"})

    capture_log(fn ->
      assert {:error, {:sandbox_create_failed, 127, output}} = Sandbox.ensure_container(ctx.workspace, settings)
      assert output =~ ":sandbox_command_not_found"

      assert {:error, {:sandbox_create_failed, 127, _output}} =
               Sandbox.command_spec(ctx.workspace, "true", [], settings: settings)
    end)
  end

  test "command_spec runs through docker exec and passes env names, not values", ctx do
    respond(ctx, "inspect", "true\n", 0)
    previous = System.get_env("SYMPHONY_SANDBOX_COVERAGE_PASS")
    System.put_env("SYMPHONY_SANDBOX_COVERAGE_PASS", "secret-value")
    on_exit(fn -> restore_env("SYMPHONY_SANDBOX_COVERAGE_PASS", previous) end)

    settings = settings(ctx, %{env: ["SYMPHONY_SANDBOX_COVERAGE_PASS", "SYMPHONY_SANDBOX_COVERAGE_UNSET"]})

    assert {:ok, spec} =
             Sandbox.command_spec(ctx.workspace, "make test", ["TOKEN", "SYMPHONY_SANDBOX_COVERAGE_PASS"],
               settings: settings,
               shell: "sh"
             )

    assert spec.executable == ctx.docker
    assert spec.cd == nil

    assert spec.args ==
             ["exec", "--interactive", "--workdir", ctx.workspace] ++
               ["--env", "SYMPHONY_SANDBOX_EXEC=1", "--env", "TOKEN", "--env", "SYMPHONY_SANDBOX_COVERAGE_PASS"] ++
               [Sandbox.container_name(ctx.workspace), "sh", "-lc", "make test"]

    refute Enum.any?(spec.args, &(&1 =~ "secret-value"))
  end

  test "command_spec without a sandbox runs the host shell", ctx do
    settings = %{settings(ctx) | sandbox: %{settings(ctx).sandbox | kind: "none"}}

    assert {:ok, %{executable: sh, args: ["-lc", "echo hi"], cd: workspace}} =
             Sandbox.command_spec(ctx.workspace, "echo hi", [], settings: settings, shell: "sh")

    assert sh == System.find_executable("sh")
    assert workspace == ctx.workspace

    assert {:error, :sh_not_found} =
             Sandbox.command_spec(ctx.workspace, "echo hi", [], settings: settings, shell: "symphony-no-such-shell")

    # The three-argument form reads the workflow's default (disabled) sandbox.
    assert {:ok, %{args: ["-lc", "echo hi"], cd: _workspace}} =
             Sandbox.command_spec(ctx.workspace, "echo hi", [])

    assert calls(ctx) == []
  end

  test "remove_container and reap only call docker when the sandbox is enabled", ctx do
    name = Sandbox.container_name(ctx.workspace)
    disabled = %{settings(ctx) | sandbox: %{settings(ctx).sandbox | kind: "none"}}

    assert :ok = Sandbox.remove_container(ctx.workspace, disabled)
    assert :ok = Sandbox.reap(ctx.workspace, disabled)
    assert calls(ctx) == []

    enabled = settings(ctx)
    assert :ok = Sandbox.remove_container(ctx.workspace, enabled)
    assert :ok = Sandbox.reap(ctx.workspace, enabled)

    assert [rm, reap] = calls(ctx)
    assert rm == "rm --force #{name}"
    assert reap =~ "exec #{name} sh -c for p in /proc/[0-9]*; do"
    assert reap =~ "grep -qx 'SYMPHONY_SANDBOX_EXEC=1'"
  end

  test "an existing network is reused and services start or report failures", ctx do
    environment = %SymphonyElixir.Environment{
      name: "svc",
      image: "registry.example.com/base:1",
      resources: %{},
      services: [
        %{name: "db", image: "registry.example.com/db:1", env: "not-a-map", ports: [], command: []},
        %{name: "worker", image: "registry.example.com/worker:1", env: %{}, ports: [], command: []}
      ],
      setup: [],
      egress_extra: [],
      digest: "digest",
      repo_file: false
    }

    settings = settings(ctx, %{environment: environment})
    name = Sandbox.container_name(ctx.workspace)

    respond(ctx, "network-inspect", "", 0)
    respond(ctx, "inspect-#{name}", "true\n", 0)
    respond(ctx, "inspect-#{name}-worker", "true\n", 0)

    assert :ok = Sandbox.ensure_container(ctx.workspace, settings)
    calls = calls(ctx)

    refute Enum.any?(calls, &String.starts_with?(&1, "network create"))
    db_run = Enum.find(calls, &String.starts_with?(&1, "run --detach --name #{name}-db"))
    assert db_run
    refute db_run =~ "--env"

    respond(ctx, "inspect-#{name}-worker", "false\n", 0)
    respond(ctx, "start-#{name}-worker", "", 0)
    assert :ok = Sandbox.ensure_container(ctx.workspace, settings)
    assert "start #{name}-worker" in calls(ctx)

    respond(ctx, "start-#{name}-worker", "cannot start", 3)

    assert {:error, {:sandbox_service_start_failed, 3, "cannot start"}} =
             Sandbox.ensure_container(ctx.workspace, settings)
  end

  test "a non-map environment option leaves the sandbox unchanged", ctx do
    settings = settings(ctx)
    respond(ctx, "inspect", "missing", 1)

    assert :ok = Sandbox.ensure_container(ctx.workspace, settings, environment: "not-a-map")
    run = Enum.find(calls(ctx), &String.starts_with?(&1, "run "))
    assert run =~ "symphony-test:latest"
    refute run =~ "--network"
  end

  test "a resolved environment sets the image, resources, network, and sibling services", ctx do
    environment = %SymphonyElixir.Environment{
      name: "python",
      image: "registry.example.com/agents/python:3.12",
      resources: %{"cpu" => 2, "memory" => "4g"},
      services: [
        %{
          name: "db",
          image: "registry.example.com/services/postgres:16",
          env: %{"POSTGRES_PASSWORD" => "secret"},
          ports: ["5432"],
          command: [],
          resources: %{"cpu" => 1, "memory" => "1g"}
        },
        %{
          name: "redis",
          image: "registry.example.com/services/redis:7",
          env: %{},
          ports: [],
          command: ["redis-server", "--save", ""]
        }
      ],
      setup: [],
      egress_extra: [],
      digest: "digest",
      repo_file: true
    }

    settings = settings(ctx, %{environment: environment})
    name = Sandbox.container_name(ctx.workspace)
    network = Sandbox.network_name(ctx.workspace)

    respond(ctx, "network-inspect", "not found", 1)
    respond(ctx, "inspect", "not found", 1)

    log = capture_log(fn -> assert :ok = Sandbox.ensure_container(ctx.workspace, settings) end)
    assert log =~ "image=registry.example.com/agents/python:3.12"

    calls = calls(ctx)

    assert Enum.take(calls, 2) == [
             "network inspect #{network}",
             "network create --internal --label symphony.workspace=#{ctx.workspace} #{network}"
           ]

    main_run = Enum.find(calls, &String.starts_with?(&1, "run --detach --init"))
    # No operator network: the engine default stays, and the internal service
    # network is connected after creation.
    refute main_run =~ "--network"
    assert "network connect #{network} #{name}" in calls
    assert main_run =~ "--cpus 2 --memory 4g"
    assert main_run =~ "--entrypoint sleep registry.example.com/agents/python:3.12 infinity"
    refute main_run =~ "symphony-test:latest"

    assert Enum.any?(calls, fn call ->
             call ==
               "run --detach --name #{name}-db --label symphony.workspace=#{ctx.workspace} " <>
                 "--label symphony.service-of=#{name} --network #{network} --network-alias db " <>
                 "--cpus 1 --memory 1g --env POSTGRES_PASSWORD=secret --expose 5432 registry.example.com/services/postgres:16"
           end)

    assert Enum.any?(
             calls,
             &(&1 ==
                 "run --detach --name #{name}-redis --label symphony.workspace=#{ctx.workspace} " <>
                   "--label symphony.service-of=#{name} --network #{network} --network-alias redis " <>
                   "registry.example.com/services/redis:7 redis-server --save ")
           )

    assert :ok = Sandbox.reap(ctx.workspace, settings)
    assert List.last(calls(ctx)) == "stop #{name}-redis"

    File.write!(Path.join(ctx.fake_dir, "ps.out"), "#{name}-db\n#{name}-redis\n")
    assert :ok = Sandbox.remove_container(ctx.workspace, settings)

    calls = calls(ctx)

    assert Enum.slice(calls, -4, 4) == [
             "ps -aq --filter label=symphony.service-of=#{name}",
             "rm --force #{name}-db #{name}-redis",
             "rm --force #{name}",
             "network rm #{network}"
           ]
  end

  test "environment services stop is idempotent and skips stopping when there are none", ctx do
    environment = %SymphonyElixir.Environment{
      name: "plain",
      image: "symphony-test:latest",
      resources: %{},
      services: [],
      setup: [],
      egress_extra: [],
      digest: "digest",
      repo_file: false
    }

    settings = settings(ctx, %{environment: environment})
    respond(ctx, "inspect", "true\n", 0)

    assert :ok = Sandbox.ensure_container(ctx.workspace, settings)
    assert :ok = Sandbox.reap(ctx.workspace, settings)
    assert Enum.any?(calls(ctx), &String.starts_with?(&1, "exec "))
    refute Enum.any?(calls(ctx), &String.starts_with?(&1, "stop "))

    assert :ok = Sandbox.remove_container(ctx.workspace, settings)
    respond(ctx, "ps", "cannot list", 1)
    assert :ok = Sandbox.remove_container(ctx.workspace, settings)
    assert Enum.any?(calls(ctx), &(&1 == "rm --force #{Sandbox.container_name(ctx.workspace)}"))
    refute Enum.any?(calls(ctx), &String.starts_with?(&1, "rm --force #{Sandbox.container_name(ctx.workspace)}-"))
  end

  test "environment setup commands run once when the container is created", ctx do
    environment = %SymphonyElixir.Environment{
      name: "python",
      image: "registry.example.com/agents/python:3.12",
      resources: %{},
      services: [],
      setup: ["pip install -r requirements.txt", "npm ci"],
      egress_extra: [],
      digest: "digest",
      repo_file: true
    }

    settings = settings(ctx, %{environment: environment})
    name = Sandbox.container_name(ctx.workspace)
    respond(ctx, "inspect", "missing", 1)

    assert :ok = Sandbox.ensure_container(ctx.workspace, settings)
    calls = calls(ctx)

    setup_prefix =
      "exec --env SYMPHONY_SANDBOX_EXEC=1 --workdir #{ctx.workspace} #{name} sh -c " <>
        ~s(if timeout -s KILL 5 true >/dev/null 2>&1; then exec timeout -s KILL 65 sh -lc "$1"; fi; exec sh -lc "$1" symphony-setup )

    assert (setup_prefix <> "pip install -r requirements.txt") in calls
    assert (setup_prefix <> "npm ci") in calls

    respond(ctx, "inspect", "true\n", 0)
    exec_count = Enum.count(calls, &String.starts_with?(&1, "exec "))
    assert :ok = Sandbox.ensure_container(ctx.workspace, settings)
    assert Enum.count(calls(ctx), &String.starts_with?(&1, "exec ")) == exec_count
  end

  test "a failed setup command removes the half-prepared container", ctx do
    environment = %SymphonyElixir.Environment{
      name: "python",
      image: "registry.example.com/agents/python:3.12",
      resources: %{},
      services: [],
      setup: ["false"],
      egress_extra: [],
      digest: "digest",
      repo_file: true
    }

    settings = settings(ctx, %{environment: environment})
    name = Sandbox.container_name(ctx.workspace)
    respond(ctx, "inspect", "missing", 1)
    respond(ctx, "exec", "setup failed", 42)

    assert {:error, {:sandbox_setup_failed, 42, "setup failed"}} =
             Sandbox.ensure_container(ctx.workspace, settings)

    assert "rm --force #{name}" in calls(ctx)
  end

  test "default-argument variants read the sandbox from the workflow", ctx do
    write_docker_workflow!(ctx)
    respond(ctx, "inspect", "true\n", 0)
    name = Sandbox.container_name(ctx.workspace)

    assert Sandbox.enabled?()
    assert :ok = Sandbox.ensure_container(ctx.workspace)
    assert :ok = Sandbox.remove_container(ctx.workspace)
    assert :ok = Sandbox.reap(ctx.workspace)

    assert [inspect, rm, reap] = calls(ctx)
    assert inspect == "inspect --format {{.State.Running}} #{name}"
    assert rm == "rm --force #{name}"
    assert reap =~ "exec #{name} sh -c"
  end

  defp service_environment(overrides \\ %{}) do
    struct(
      SymphonyElixir.Environment,
      Map.merge(
        %{
          name: "svc",
          image: "registry.example.com/base:1",
          resources: %{},
          services: [
            %{
              name: "db",
              image: "registry.example.com/db:1",
              env: %{},
              ports: [],
              command: [],
              resources: %{"cpu" => 0.5, "memory" => "256m"}
            }
          ],
          setup: [],
          egress_extra: [],
          digest: "digest",
          repo_file: false
        },
        overrides
      )
    )
  end

  test "services never widen the operator's network", ctx do
    name = Sandbox.container_name(ctx.workspace)
    network = Sandbox.network_name(ctx.workspace)
    respond(ctx, "inspect", "missing", 1)
    respond(ctx, "network-inspect", "missing", 1)

    main_run = fn ->
      Enum.find(calls(ctx), &String.starts_with?(&1, "run --detach --init"))
    end

    # `none`: the agent gets only the internal (no egress) service network.
    settings = settings(ctx, %{network: "none", environment: service_environment()})
    assert :ok = Sandbox.ensure_container(ctx.workspace, settings)
    assert main_run.() =~ "--network #{network} --entrypoint"
    refute main_run.() =~ "--network none"
    refute Enum.any?(calls(ctx), &String.starts_with?(&1, "network connect"))
    assert "network create --internal --label symphony.workspace=#{ctx.workspace} #{network}" in calls(ctx)

    # A named operator network is kept; the internal one is added beside it.
    File.rm!(Path.join(ctx.fake_dir, "calls.log"))
    settings = settings(ctx, %{network: "filtered-egress", environment: service_environment()})
    assert :ok = Sandbox.ensure_container(ctx.workspace, settings)
    assert main_run.() =~ "--network filtered-egress --network #{network} --entrypoint"
    refute Enum.any?(calls(ctx), &String.starts_with?(&1, "network connect"))

    # Services only ever join the internal network.
    service_run = Enum.find(calls(ctx), &String.starts_with?(&1, "run --detach --name #{name}-db"))
    assert service_run =~ "--network #{network} --network-alias db"
    refute service_run =~ "filtered-egress"

    # Without services the operator's network is used alone, and no service network exists.
    File.rm!(Path.join(ctx.fake_dir, "calls.log"))
    settings = settings(ctx, %{network: "filtered-egress", environment: service_environment(%{services: []})})
    assert :ok = Sandbox.ensure_container(ctx.workspace, settings)
    assert main_run.() =~ "--network filtered-egress --entrypoint"
    refute main_run.() =~ network
    refute Enum.any?(calls(ctx), &String.starts_with?(&1, "network "))
  end

  test "a failed network connect discards the new container", ctx do
    name = Sandbox.container_name(ctx.workspace)
    respond(ctx, "inspect", "missing", 1)
    respond(ctx, "network-connect", "not supported", 2)

    settings = settings(ctx, %{environment: service_environment()})

    assert {:error, {:sandbox_network_connect_failed, 2, "not supported"}} =
             Sandbox.ensure_container(ctx.workspace, settings)

    assert List.last(calls(ctx)) == "rm --force #{name}"
    refute Enum.any?(calls(ctx), &String.starts_with?(&1, "run --detach --name #{name}-db"))
  end

  test "services get resource limits and only the safe hardening run_args", ctx do
    name = Sandbox.container_name(ctx.workspace)
    respond(ctx, "inspect", "missing", 1)

    run_args = [
      "--cap-drop=ALL",
      "--security-opt",
      "no-new-privileges",
      "--memory",
      "2g",
      "--userns=keep-id",
      "--read-only",
      "--pids-limit",
      "256",
      "--volume",
      "/secrets:/secrets",
      "--device=/dev/fuse",
      "--cap-drop"
    ]

    settings = settings(ctx, %{network: "none", run_args: run_args, environment: service_environment()})
    assert :ok = Sandbox.ensure_container(ctx.workspace, settings)

    service_run = Enum.find(calls(ctx), &String.starts_with?(&1, "run --detach --name #{name}-db"))

    assert service_run =~
             "--network-alias db --cap-drop=ALL --security-opt no-new-privileges --userns=keep-id --pids-limit 256 " <>
               "--cpus 0.5 --memory 256m registry.example.com/db:1"

    refute service_run =~ "/secrets"
    refute service_run =~ "--read-only"
    refute service_run =~ "/dev/fuse"
    refute service_run =~ "2g"

    # The agent container still gets every run_arg.
    main_run = Enum.find(calls(ctx), &String.starts_with?(&1, "run --detach --init"))
    assert main_run =~ Enum.join(run_args, " ")
  end

  test "a service that fails to start discards a container created in the same call", ctx do
    name = Sandbox.container_name(ctx.workspace)
    respond(ctx, "inspect-#{name}", "missing", 1)
    respond(ctx, "inspect-#{name}-db", "missing", 1)
    respond(ctx, "run", "pull denied", 125)

    settings = settings(ctx, %{network: "none", environment: service_environment(%{setup: ["make deps"]})})

    capture_log(fn ->
      assert {:error, {:sandbox_create_failed, 125, "pull denied"}} = Sandbox.ensure_container(ctx.workspace, settings)
    end)

    # Main container creation succeeds, the service does not.
    File.rm!(Path.join(ctx.fake_dir, "calls.log"))
    File.rm!(Path.join(ctx.fake_dir, "run.status"))
    File.write!(Path.join(ctx.fake_dir, "run.out"), "")

    fail_service = """
    #!/bin/sh
    case "$*" in
      "run --detach --name #{name}-db"*) printf '%s\\n' "$*" >> "#{ctx.fake_dir}/calls.log"; echo "db failed"; exit 7 ;;
    esac
    exec "#{ctx.docker}" "$@"
    """

    wrapper = Path.join(ctx.fake_dir, "docker-wrapper")
    File.write!(wrapper, fail_service)
    File.chmod!(wrapper, 0o755)
    settings = settings(ctx, %{command: wrapper, network: "none", environment: service_environment(%{setup: ["make deps"]})})

    capture_log(fn ->
      assert {:error, {:sandbox_service_create_failed, 7, "db failed\n"}} = Sandbox.ensure_container(ctx.workspace, settings)
    end)

    assert "rm --force #{name}" in calls(ctx)
    refute Enum.any?(calls(ctx), &(&1 =~ "make deps"))

    # A container that already existed is kept; only the error is returned.
    File.rm!(Path.join(ctx.fake_dir, "calls.log"))
    respond(ctx, "inspect-#{name}", "true\n", 0)
    assert {:error, {:sandbox_service_create_failed, 7, _output}} = Sandbox.ensure_container(ctx.workspace, settings)
    refute "rm --force #{name}" in calls(ctx)
  end

  test "a stopped service is restarted when the agent container is already running", ctx do
    name = Sandbox.container_name(ctx.workspace)
    respond(ctx, "network-inspect", "", 0)
    respond(ctx, "inspect-#{name}", "true\n", 0)
    respond(ctx, "inspect-#{name}-db", "false\n", 0)

    assert :ok = Sandbox.ensure_container(ctx.workspace, settings(ctx, %{environment: service_environment()}))
    assert List.last(calls(ctx)) == "start #{name}-db"
  end

  test "a setup command that outlives the hooks timeout is killed and fails the run", ctx do
    name = Sandbox.container_name(ctx.workspace)
    respond(ctx, "inspect", "missing", 1)
    File.write!(Path.join(ctx.fake_dir, "hang"), "symphony-setup sleep-forever")

    settings = settings(ctx, %{environment: service_environment(%{services: [], setup: ["echo ok", "sleep-forever"]})})
    settings = %{settings | hooks: %{settings.hooks | timeout_ms: 300}}

    {elapsed_us, result} =
      :timer.tc(fn ->
        capture_log(fn -> send(self(), {:result, Sandbox.ensure_container(ctx.workspace, settings)}) end)
        assert_received {:result, result}
        result
      end)

    assert result == {:error, {:sandbox_setup_timeout, "sleep-forever", 300}}
    assert elapsed_us < 5_000_000
    # The backstop `timeout` inside the container is set past the host deadline.
    assert Enum.any?(calls(ctx), &(&1 =~ "exec timeout -s KILL 6 sh -lc"))
    assert "rm --force #{name}" in calls(ctx)
    refute_received {_port, {:exit_status, _status}}

    log = capture_log(fn -> Sandbox.ensure_container(ctx.workspace, settings) end)
    assert log =~ "Sandbox setup command timed out"
  end

  test "sweep_orphans removes service containers and networks whose workspace is gone", ctx do
    disabled = %{settings(ctx) | sandbox: %{settings(ctx).sandbox | kind: "none"}}
    assert :ok = Sandbox.sweep_orphans(disabled)
    assert calls(ctx) == []

    gone = Path.join(ctx.root, "workspaces/MT-GONE")

    File.write!(Path.join(ctx.fake_dir, "ps.out"), "c1\nc2\nc3\nc4\n")
    File.write!(Path.join(ctx.fake_dir, "inspect-c4.out"), "c1 #{gone}\nc2 #{ctx.workspace}\nc3 <no value>\nc4\n")
    respond(ctx, "network-ls", "symphony-a-net\nsymphony-b-net\nother-net\nsymphony-c\n", 0)

    File.write!(
      Path.join(ctx.fake_dir, "network-inspect.out"),
      "symphony-a-net #{gone}\nsymphony-b-net #{ctx.workspace}\nother-net #{gone}\nsymphony-c #{gone}\n"
    )

    settings = settings(ctx)
    assert :ok = Sandbox.sweep_orphans(settings)

    assert calls(ctx) == [
             "ps -aq --filter label=symphony.service-of",
             ~s(inspect --format {{.Id}} {{index .Config.Labels "symphony.workspace"}} c1 c2 c3 c4),
             "rm --force c1",
             "network ls -q --filter label=symphony.workspace",
             ~s(network inspect --format {{.Name}} {{index .Labels "symphony.workspace"}} symphony-a-net symphony-b-net other-net symphony-c),
             "network rm symphony-a-net"
           ]

    # Nothing to list, nothing orphaned, or an engine error: no removals.
    File.rm!(Path.join(ctx.fake_dir, "calls.log"))
    File.write!(Path.join(ctx.fake_dir, "ps.out"), "")
    respond(ctx, "network-ls", "symphony-b-net\n", 0)
    File.write!(Path.join(ctx.fake_dir, "network-inspect.out"), "symphony-b-net #{ctx.workspace}\n")
    assert :ok = Sandbox.sweep_orphans(settings)
    refute Enum.any?(calls(ctx), &String.starts_with?(&1, "rm "))
    refute Enum.any?(calls(ctx), &String.starts_with?(&1, "network rm"))

    File.rm!(Path.join(ctx.fake_dir, "calls.log"))
    File.write!(Path.join(ctx.fake_dir, "ps.out"), "c2\n")
    File.write!(Path.join(ctx.fake_dir, "inspect-c2.out"), "c2 #{ctx.workspace}\n")
    respond(ctx, "network-ls", "boom", 1)
    assert :ok = Sandbox.sweep_orphans(settings)
    assert List.last(calls(ctx)) == "network ls -q --filter label=symphony.workspace"
    refute Enum.any?(calls(ctx), &String.starts_with?(&1, "rm "))

    respond(ctx, "inspect-c2", "boom", 1)
    assert :ok = Sandbox.sweep_orphans(settings)
  end

  test "sweep_orphans/0 reads the workflow's sandbox", ctx do
    write_docker_workflow!(ctx)
    respond(ctx, "ps", "", 1)
    respond(ctx, "network-ls", "", 1)
    assert :ok = Sandbox.sweep_orphans()
    assert length(calls(ctx)) == 2
  end
end
