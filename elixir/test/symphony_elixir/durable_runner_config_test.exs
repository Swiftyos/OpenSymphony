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

  test "launcher and runner command validation reject bad values" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"agent" => %{"launcher" => "container"}})

    assert message == "agent.launcher must be one of: local, process"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"agent" => %{"runner_command" => "symphony {spec}"}})

    assert message == "agent.runner_command must include {symphony}, {spec} and {run_id} placeholders"

    assert {:ok, settings} = Schema.parse(%{"agent" => %{"launcher" => "process"}})
    assert settings.agent.launcher == "process"
    assert settings.agent.runner_command =~ "{symphony}"
  end
end
