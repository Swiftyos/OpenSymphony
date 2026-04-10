defmodule SymphonyElixir.ClaudeCode.Tooling do
  @moduledoc false

  alias SymphonyElixir.{Config, SSH}
  alias SymphonyElixir.Linear.GraphqlTool

  @bundle_root [".symphony", "claude"]
  @mcp_server_path @bundle_root ++ ["linear_graphql_mcp.js"]
  @mcp_config_path @bundle_root ++ ["mcp.json"]
  @git_exclude_entry ".symphony/"

  @spec bootstrap_workspace(Path.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def bootstrap_workspace(workspace, worker_host \\ nil, opts \\ []) when is_binary(workspace) do
    linear_enabled? = Config.settings!().tracker.kind == "linear"
    timeout = Keyword.get(opts, :timeout_ms, Config.settings!().hooks.timeout_ms)

    if is_binary(worker_host) do
      bootstrap_remote_workspace(workspace, worker_host, linear_enabled?, timeout)
    else
      bootstrap_local_workspace(workspace, linear_enabled?)
    end
  end

  @spec mcp_config_relative_path() :: String.t()
  def mcp_config_relative_path do
    Path.join(@mcp_config_path)
  end

  defp bootstrap_local_workspace(workspace, linear_enabled?) do
    config_path = Path.join([workspace | @mcp_config_path])
    server_path = Path.join([workspace | @mcp_server_path])

    with :ok <- File.mkdir_p(Path.dirname(config_path)),
         :ok <- File.write(config_path, mcp_config_source(linear_enabled?)),
         :ok <- maybe_write_server(server_path, linear_enabled?),
         :ok <- ensure_git_exclude(workspace) do
      :ok
    else
      {:error, reason} -> {:error, {:claude_tooling_failed, reason}}
    end
  end

  defp bootstrap_remote_workspace(workspace, worker_host, linear_enabled?, timeout) do
    script = remote_bootstrap_script(workspace, linear_enabled?)

    case SSH.run(worker_host, script, stderr_to_stdout: true, timeout: timeout) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:claude_tooling_failed, {:remote_bootstrap_failed, worker_host, status, output}}}
      {:error, reason} -> {:error, {:claude_tooling_failed, reason}}
    end
  end

  defp maybe_write_server(server_path, true) do
    with :ok <- File.write(server_path, GraphqlTool.claude_mcp_server_source()),
         :ok <- File.chmod(server_path, 0o755) do
      :ok
    end
  end

  defp maybe_write_server(server_path, false) do
    case File.rm(server_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_git_exclude(workspace) do
    case git_exclude_path(workspace) do
      nil ->
        :ok

      exclude_path ->
        :ok = File.mkdir_p(Path.dirname(exclude_path))

        existing =
          case File.read(exclude_path) do
            {:ok, contents} -> contents
            {:error, :enoent} -> ""
            {:error, reason} -> raise File.Error, reason: reason, action: "read", path: exclude_path
          end

        if String.contains?(existing, @git_exclude_entry) do
          :ok
        else
          prefix = if existing == "" or String.ends_with?(existing, "\n"), do: existing, else: existing <> "\n"
          File.write(exclude_path, prefix <> @git_exclude_entry <> "\n")
        end
    end
  rescue
    error in [File.Error] ->
      {:error, error}
  end

  defp git_exclude_path(workspace) do
    git_path = Path.join(workspace, ".git")

    cond do
      File.dir?(git_path) ->
        Path.join([git_path, "info", "exclude"])

      File.regular?(git_path) ->
        with {:ok, contents} <- File.read(git_path),
             {:ok, git_dir} <- parse_git_dir(contents, workspace) do
          Path.join([git_dir, "info", "exclude"])
        else
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp parse_git_dir(contents, workspace) when is_binary(contents) do
    case contents
         |> String.split("\n", trim: true)
         |> Enum.find(&String.starts_with?(&1, "gitdir:")) do
      nil ->
        :error

      line ->
        git_dir =
          line
          |> String.replace_prefix("gitdir:", "")
          |> String.trim()
          |> Path.expand(workspace)

        {:ok, git_dir}
    end
  end

  defp mcp_config_source(linear_enabled?) do
    config = %{
      "mcpServers" =>
        if linear_enabled? do
          %{
            "symphony-linear" => %{
              "command" => "node",
              "args" => [Path.join(@mcp_server_path)]
            }
          }
        else
          %{}
        end
    }

    Jason.encode!(config, pretty: true)
  end

  defp remote_bootstrap_script(workspace, linear_enabled?) do
    config_source = mcp_config_source(linear_enabled?)
    server_source = GraphqlTool.claude_mcp_server_source()

    [
      "set -eu",
      shell_assign("workspace", workspace),
      "config_dir=\"$workspace/#{Path.join(@bundle_root)}\"",
      "config_path=\"$workspace/#{Path.join(@mcp_config_path)}\"",
      "server_path=\"$workspace/#{Path.join(@mcp_server_path)}\"",
      "mkdir -p \"$config_dir\"",
      "cat > \"$config_path\" <<'SYMPHONY_CLAUDE_MCP_CONFIG'",
      config_source,
      "SYMPHONY_CLAUDE_MCP_CONFIG",
      if(linear_enabled?, do: remote_server_write_script(server_source), else: "rm -f \"$server_path\""),
      remote_git_exclude_script()
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp remote_server_write_script(server_source) do
    [
      "cat > \"$server_path\" <<'SYMPHONY_CLAUDE_MCP_SERVER'",
      server_source,
      "SYMPHONY_CLAUDE_MCP_SERVER",
      "chmod 755 \"$server_path\""
    ]
  end

  defp remote_git_exclude_script do
    [
      "if command -v git >/dev/null 2>&1; then",
      "  exclude_path=$(cd \"$workspace\" && git rev-parse --git-path info/exclude 2>/dev/null || true)",
      "  if [ -n \"$exclude_path\" ]; then",
      "    case \"$exclude_path\" in",
      "      /*) final_exclude_path=\"$exclude_path\" ;;",
      "      *) final_exclude_path=\"$workspace/$exclude_path\" ;;",
      "    esac",
      "    mkdir -p \"$(dirname \"$final_exclude_path\")\"",
      "    touch \"$final_exclude_path\"",
      "    if ! grep -Fqx #{@git_exclude_entry |> shell_escape()} \"$final_exclude_path\"; then",
      "      printf '%s\\n' #{@git_exclude_entry |> shell_escape()} >> \"$final_exclude_path\"",
      "    fi",
      "  fi",
      "fi"
    ]
  end

  defp shell_assign(name, value) when is_binary(name) and is_binary(value) do
    "#{name}=#{shell_escape(value)}"
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
