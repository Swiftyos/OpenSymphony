defmodule SymphonyElixir.ClaudeCodeToolingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.Tooling

  test "bootstrap_workspace writes Claude MCP config, server, and git exclude entry" do
    test_root = temp_root!("linear")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE-TOOLING")
      git_info_dir = Path.join([workspace, ".git", "info"])

      File.mkdir_p!(git_info_dir)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: workspace_root
      )

      assert :ok = Tooling.bootstrap_workspace(workspace)

      config_path = Path.join(workspace, ".symphony/claude/mcp.json")
      server_path = Path.join(workspace, ".symphony/claude/linear_graphql_mcp.js")
      exclude_path = Path.join(git_info_dir, "exclude")

      assert File.exists?(config_path)
      assert File.exists?(server_path)
      assert File.exists?(exclude_path)

      assert %{
               "mcpServers" => %{
                 "symphony-linear" => %{
                   "command" => "node",
                   "args" => [".symphony/claude/linear_graphql_mcp.js"]
                 }
               }
             } = config_path |> File.read!() |> Jason.decode!()

      server_source = File.read!(server_path)
      assert server_source =~ "linear_graphql"
      assert server_source =~ "Content-Length"
      assert File.read!(exclude_path) =~ ".symphony/"
    after
      File.rm_rf(test_root)
    end
  end

  test "bootstrap_workspace omits Linear MCP wiring when the tracker is not Linear" do
    test_root = temp_root!("memory")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE-MEMORY")
      git_info_dir = Path.join([workspace, ".git", "info"])
      server_path = Path.join(workspace, ".symphony/claude/linear_graphql_mcp.js")

      File.mkdir_p!(git_info_dir)
      File.mkdir_p!(Path.dirname(server_path))
      File.write!(server_path, "stale server")

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      assert :ok = Tooling.bootstrap_workspace(workspace)

      config_path = Path.join(workspace, ".symphony/claude/mcp.json")
      exclude_path = Path.join(git_info_dir, "exclude")

      assert File.exists?(config_path)
      refute File.exists?(server_path)
      assert File.read!(exclude_path) =~ ".symphony/"
      assert %{"mcpServers" => %{}} = config_path |> File.read!() |> Jason.decode!()
    after
      File.rm_rf(test_root)
    end
  end

  defp temp_root!(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-claude-tooling-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end
end
