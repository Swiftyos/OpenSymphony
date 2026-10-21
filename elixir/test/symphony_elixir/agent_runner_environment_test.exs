defmodule SymphonyElixir.AgentRunnerEnvironmentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Sandbox

  # The agent's container must come from the issue's resolved environment even
  # when no workspace hook runs first: the agent launch itself creates it.
  setup do
    root = Path.join(System.tmp_dir!(), "symphony-runner-environment-#{System.unique_integer([:positive])}")
    fake_dir = Path.join(root, "fake-docker")
    File.mkdir_p!(fake_dir)
    docker = Path.join(fake_dir, "docker")

    # Logs every call; `inspect` answers from `inspect-<name>.out`/`.status`;
    # the agent launch (`exec --interactive`) exits at once so the run ends;
    # no network exists yet.
    File.write!(docker, """
    #!/bin/sh
    dir="#{fake_dir}"
    printf '%s\\n' "$*" >> "$dir/calls.log"
    case "$1 $2" in
      "exec --interactive") exit 1 ;;
      "network inspect") exit 1 ;;
    esac
    if [ "$1" = "inspect" ]; then
      last=$(printf '%s\\n' "$@" | tail -n 1)
      [ -f "$dir/inspect-$last.out" ] && cat "$dir/inspect-$last.out"
      [ -f "$dir/inspect-$last.status" ] && exit "$(cat "$dir/inspect-$last.status")"
      exit 1
    fi
    exit 0
    """)

    File.chmod!(docker, 0o755)
    on_exit(fn -> File.rm_rf(root) end)

    previous = Application.get_env(:symphony_elixir, :startup_mode)
    Application.put_env(:symphony_elixir, :startup_mode, :legacy)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :startup_mode, previous),
        else: Application.delete_env(:symphony_elixir, :startup_mode)
    end)

    {:ok, root: root, fake_dir: fake_dir, docker: docker}
  end

  defp write_environment_workflow!(ctx) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, agent_backend: "codex", workspace_root: Path.join(ctx.root, "workspaces"))
    "---\n" <> rest = File.read!(path)

    File.write!(
      path,
      """
      ---
      sandbox:
        kind: docker
        command: #{inspect(ctx.docker)}
        image: symphony-global:latest
        network: none
      environments:
        default:
          image: registry.example.com/agents/python:3.12
          resources: {cpu: 2, memory: 4g}
          allowed_images: [registry.example.com/]
          service_resources: {cpu: 1, memory: 512m}
          services:
            - name: db
              image: registry.example.com/services/postgres:16
      """ <> rest
    )

    WorkflowStore.force_reload()
  end

  defp calls(ctx) do
    case File.read(Path.join(ctx.fake_dir, "calls.log")) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  test "the agent launch creates the container from the environment and restarts reaped services", ctx do
    write_environment_workflow!(ctx)
    assert Config.settings!().sandbox.kind == "docker"

    issue = %Issue{id: "issue-env", identifier: "MT-ENV-1", title: "Environment", state: "In Progress", labels: []}
    fetcher = fn _ids -> {:ok, [%{issue | state: "Done"}]} end

    capture_log(fn ->
      assert_raise RuntimeError, fn -> AgentRunner.run(issue, nil, issue_state_fetcher: fetcher) end
    end)

    workspace = Path.join([ctx.root, "workspaces", "MT-ENV-1"])
    name = Sandbox.container_name(workspace)
    network = Sandbox.network_name(workspace)
    calls = calls(ctx)

    main_run = Enum.find(calls, &String.starts_with?(&1, "run --detach --init --name #{name}"))
    assert main_run, inspect(calls)
    assert main_run =~ "--network #{network} --cpus 2 --memory 4g"
    assert main_run =~ "--entrypoint sleep registry.example.com/agents/python:3.12 infinity"
    refute main_run =~ "symphony-global:latest"
    refute main_run =~ "--network none"

    db_run = Enum.find(calls, &String.starts_with?(&1, "run --detach --name #{name}-db"))
    assert db_run =~ "--network #{network} --network-alias db --cpus 1 --memory 512m"
    assert "network create --internal --label symphony.workspace=#{workspace} #{network}" in calls

    # The agent was launched in that container, and the run's reap stopped the service.
    assert Enum.any?(calls, &String.starts_with?(&1, "exec --interactive --workdir #{workspace}"))
    assert List.last(calls) == "stop #{name}-db"

    # Second run: the agent container is still up, but its service was stopped.
    File.rm!(Path.join(ctx.fake_dir, "calls.log"))
    File.write!(Path.join(ctx.fake_dir, "inspect-#{name}.out"), "true\n")
    File.write!(Path.join(ctx.fake_dir, "inspect-#{name}.status"), "0")
    File.write!(Path.join(ctx.fake_dir, "inspect-#{name}-db.out"), "false\n")
    File.write!(Path.join(ctx.fake_dir, "inspect-#{name}-db.status"), "0")

    capture_log(fn ->
      assert_raise RuntimeError, fn -> AgentRunner.run(issue, nil, issue_state_fetcher: fetcher) end
    end)

    calls = calls(ctx)
    refute Enum.any?(calls, &String.starts_with?(&1, "run "))
    start_index = Enum.find_index(calls, &(&1 == "start #{name}-db"))
    exec_index = Enum.find_index(calls, &String.starts_with?(&1, "exec --interactive"))
    assert start_index && exec_index && start_index < exec_index, inspect(calls)
  end
end
