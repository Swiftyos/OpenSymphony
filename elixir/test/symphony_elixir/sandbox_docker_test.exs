defmodule SymphonyElixir.SandboxDockerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Sandbox

  @moduletag :docker
  @moduletag timeout: 180_000

  @docker_skip_reason if(System.get_env("SYMPHONY_RUN_DOCKER_TESTS") != "1",
                        do: "set SYMPHONY_RUN_DOCKER_TESTS=1 to run against a real Docker/Podman engine"
                      )

  @image System.get_env("SYMPHONY_DOCKER_TEST_IMAGE", "debian:bookworm-slim")

  defp settings(workspace_root) do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    settings = Config.settings!()

    %{
      settings
      | sandbox: %{settings.sandbox | kind: "docker", image: @image, env: ["SYMPHONY_SANDBOX_PASSTHROUGH"]}
    }
  end

  defp running_count(workspace, pattern) do
    script = "for p in /proc/[0-9]*; do tr '\\0' ' ' < $p/cmdline 2>/dev/null; echo; done | grep -c '^#{pattern}' || true"
    {out, _} = System.cmd("docker", ["exec", Sandbox.container_name(workspace), "sh", "-c", script], stderr_to_stdout: true)
    out |> String.trim() |> String.to_integer()
  end

  @tag skip: @docker_skip_reason
  test "commands run inside a per-workspace container that shares the workspace path" do
    root = Path.join(System.user_home!(), ".symphony-sandbox-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "MT-1")
    File.mkdir_p!(workspace)
    settings = settings(root)
    System.put_env("SYMPHONY_SANDBOX_PASSTHROUGH", "from-host")

    try do
      assert :ok = Sandbox.ensure_container(workspace, settings)
      # Idempotent: a second call reuses the running container.
      assert :ok = Sandbox.ensure_container(workspace, settings)

      script = "echo \"$(pwd) $SECRET $SYMPHONY_SANDBOX_PASSTHROUGH $(cat /etc/os-release | head -1)\" > probe.txt"

      {:ok, spec} = Sandbox.command_spec(workspace, script, ["SECRET"], settings: settings)
      refute Enum.any?(spec.args, &String.contains?(&1, "top-secret"))

      {output, status} = System.cmd(spec.executable, spec.args, env: [{"SECRET", "top-secret"}], stderr_to_stdout: true)
      assert status == 0, output

      probe = File.read!(Path.join(workspace, "probe.txt"))
      assert probe =~ "#{workspace} top-secret from-host"
      # Proves it ran in the image, not on the host.
      assert probe =~ "PRETTY_NAME"

      # A process that ignores stdin and outlives its exec client is reaped.
      {:ok, spec} = Sandbox.command_spec(workspace, "sleep 600", [], settings: settings)
      port = Port.open({:spawn_executable, spec.executable}, [:binary, args: spec.args])
      Process.sleep(1_000)
      {:os_pid, client_pid} = Port.info(port, :os_pid)
      System.cmd("kill", ["-9", Integer.to_string(client_pid)])
      # Simulate Docker leaving it behind: a detached, tagged process survives any client.
      name = Sandbox.container_name(workspace)
      {_, 0} = System.cmd("docker", ["exec", "-d", "--env", "SYMPHONY_SANDBOX_EXEC=1", name, "sleep", "700"])
      {_, 0} = System.cmd("docker", ["exec", "-d", name, "sleep", "800"])
      Process.sleep(500)
      assert running_count(workspace, "sleep 700") == 1

      assert :ok = Sandbox.reap(workspace, settings)
      Process.sleep(500)
      assert running_count(workspace, "sleep 600") == 0
      assert running_count(workspace, "sleep 700") == 0
      # Untagged processes (not started by Symphony) are left alone.
      assert running_count(workspace, "sleep 800") == 1

      # Stopped containers are restarted rather than recreated.
      {_, 0} = System.cmd("docker", ["stop", "-t", "0", Sandbox.container_name(workspace)], stderr_to_stdout: true)
      assert :ok = Sandbox.ensure_container(workspace, settings)
    after
      Sandbox.remove_container(workspace, settings)
      System.delete_env("SYMPHONY_SANDBOX_PASSTHROUGH")
      File.rm_rf!(root)
    end

    {_, status} = System.cmd("docker", ["inspect", Sandbox.container_name(workspace)], stderr_to_stdout: true)
    assert status != 0, "container should be gone after remove_container/2"
  end
end
