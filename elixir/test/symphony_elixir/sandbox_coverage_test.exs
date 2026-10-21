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
    cmd="$1"
    if [ -f "$dir/$cmd.out" ]; then cat "$dir/$cmd.out"; fi
    if [ -f "$dir/$cmd.status" ]; then exit "$(cat "$dir/$cmd.status")"; fi
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
end
