defmodule SymphonyElixir.DurableRunnerConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  test "the local launcher and its command are the defaults" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert Config.agent_launcher() == :local
    assert Config.agent_runner_command() == Config.default_runner_command()
    assert Config.agent_runner_command() =~ "setsid {symphony} runner {spec}"
  end

  test "the process launcher and a VM template are read from config" do
    command = "systemd-run --user --unit=symphony-run-{run_id} --collect {symphony} runner {spec} --i-understand-that-this-will-be-running-without-the-usual-guardrails"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_launcher: "process",
      agent_runner_command: command
    )

    assert Config.agent_launcher() == :process
    assert Config.agent_runner_command() == command
    assert SymphonyElixir.RunLauncher.launcher() == SymphonyElixir.RunLauncher.Process
  end

  test "the kubernetes launcher and its pod settings are read from config" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_launcher: "kubernetes")

    assert Config.agent_launcher() == :kubernetes
    assert SymphonyElixir.RunLauncher.launcher() == SymphonyElixir.RunLauncher.Kubernetes

    assert {:ok, settings} =
             Schema.parse(%{
               "agent" => %{
                 "launcher" => "kubernetes",
                 "kubernetes" => %{
                   "controller_url" => " http://symphony.symphony.svc:4000 ",
                   "finished_pod_retention_ms" => 0,
                   "janitor_interval_ms" => 60_000
                 }
               }
             })

    kube = settings.agent.kubernetes
    assert kube.controller_url == "http://symphony.symphony.svc:4000"
    assert kube.finished_pod_retention_ms == 0
    assert kube.janitor_interval_ms == 60_000

    assert {:ok, defaults} = Schema.parse(%{})
    assert defaults.agent.kubernetes.controller_url == nil
    assert defaults.agent.kubernetes.finished_pod_retention_ms == 3_600_000
    assert defaults.agent.kubernetes.janitor_interval_ms == 300_000

    for {field, value, expected} <- [
          {"controller_url", "symphony:4000", "agent.kubernetes.controller_url must be an http(s) URL"},
          {"finished_pod_retention_ms", -1, "agent.kubernetes.finished_pod_retention_ms must be greater than or equal to 0"},
          {"janitor_interval_ms", 0, "agent.kubernetes.janitor_interval_ms must be greater than 0"}
        ] do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"kubernetes" => %{field => value}}})

      assert message =~ expected
    end
  end

  test "launcher and runner command validation reject bad values" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"agent" => %{"launcher" => "container"}})

    assert message == "agent.launcher must be one of: local, process, kubernetes"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"agent" => %{"runner_command" => "symphony {spec}"}})

    assert message == "agent.runner_command must include {symphony}, {spec} and {run_id} placeholders"

    assert {:ok, settings} = Schema.parse(%{"agent" => %{"launcher" => "process"}})
    assert settings.agent.launcher == "process"
    assert settings.agent.runner_command =~ "{symphony}"
  end
end
