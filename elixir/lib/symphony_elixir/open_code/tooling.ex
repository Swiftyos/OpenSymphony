defmodule SymphonyElixir.OpenCode.Tooling do
  @moduledoc false

  alias SymphonyElixir.Config

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
    """
    import { tool } from "@opencode-ai/plugin";
    import { z } from "zod";

    const ENDPOINT = process.env.SYMPHONY_LINEAR_ENDPOINT || "https://api.linear.app/graphql";
    const API_KEY = process.env.SYMPHONY_LINEAR_API_KEY;

    const format = (value: unknown) => JSON.stringify(value, null, 2);

    const fail = (payload: unknown): never => {
      throw new Error(format(payload));
    };

    export default tool({
      description: "Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.",
      args: {
        query: z.string().min(1),
        variables: z.record(z.string(), z.unknown()).nullable().optional(),
      },
      async execute(args) {
        if (!API_KEY) {
          fail({
            error: {
              message: "Symphony is missing Linear auth. Set `tracker.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`.",
            },
          });
        }

        try {
          const response = await fetch(ENDPOINT, {
            method: "POST",
            headers: {
              Authorization: API_KEY,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              query: args.query.trim(),
              variables: args.variables ?? {},
            }),
          });

          const json = await response.json();

          if (!response.ok) {
            fail({
              error: {
                message: `Linear GraphQL request failed with HTTP ${response.status}.`,
                status: response.status,
                body: json,
              },
            });
          }

          if (Array.isArray(json?.errors) && json.errors.length > 0) {
            fail(json);
          }

          return format(json);
        } catch (error) {
          fail({
            error: {
              message: "Linear GraphQL request failed before receiving a successful response.",
              reason: error instanceof Error ? error.message : String(error),
            },
          });
        }
      },
    });
    """
  end
end
