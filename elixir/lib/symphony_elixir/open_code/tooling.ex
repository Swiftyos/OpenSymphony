defmodule SymphonyElixir.OpenCode.Tooling do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.GraphqlTool

  @linear_tool_path [".opencode", "tools", "linear_graphql.ts"]
  @git_exclude_entry ".opencode/"

  @spec bootstrap_workspace(Path.t()) :: :ok | {:error, term()}
  def bootstrap_workspace(workspace) when is_binary(workspace) do
    case Config.settings!().tracker.kind do
      "linear" ->
        ensure_linear_tool(workspace)

      _ ->
        remove_linear_tool(workspace)
    end
  end

  def bootstrap_workspace(_workspace), do: :ok

  defp ensure_linear_tool(workspace) do
    tool_path = Path.join([workspace | @linear_tool_path])

    with :ok <- File.mkdir_p(Path.dirname(tool_path)),
         :ok <- File.write(tool_path, linear_tool_source()),
         :ok <- ensure_git_exclude(workspace) do
      :ok
    else
      {:error, reason} -> {:error, {:opencode_tooling_failed, reason}}
    end
  end

  defp remove_linear_tool(workspace) do
    tool_path = Path.join([workspace | @linear_tool_path])

    case File.rm(tool_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:opencode_tooling_failed, reason}}
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

  defp linear_tool_source do
    GraphqlTool.open_code_tool_source()
  end
end
