defmodule SymphonyElixir.ProjectWorkflow do
  @moduledoc """
  Loads and validates repo-local `WORKFLOW.md` files for multi-project routing.
  """

  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @supported_top_level_keys MapSet.new(["agent", "hooks", "codex", "opencode", "claude"])

  @ignored_legacy_top_level_keys MapSet.new([
                                   "tracker",
                                   "polling",
                                   "workspace",
                                   "worker",
                                   "observability",
                                   "server",
                                   "projects"
                                 ])

  @allowed_top_level_keys MapSet.union(@supported_top_level_keys, @ignored_legacy_top_level_keys)

  @allowed_agent_keys MapSet.new([
                        "backend",
                        "default_effort",
                        "max_concurrent_agents",
                        "max_turns",
                        "max_retry_backoff_ms",
                        "max_concurrent_agents_by_state"
                      ])

  @allowed_hook_keys MapSet.new(["after_create", "before_run", "after_run", "before_remove", "timeout_ms"])

  @allowed_codex_keys MapSet.new([
                        "command",
                        "approval_policy",
                        "thread_sandbox",
                        "turn_sandbox_policy",
                        "turn_timeout_ms",
                        "read_timeout_ms",
                        "stall_timeout_ms"
                      ])

  @allowed_opencode_keys MapSet.new([
                           "command",
                           "agent",
                           "model",
                           "turn_timeout_ms",
                           "read_timeout_ms",
                           "stall_timeout_ms"
                         ])

  @allowed_claude_keys MapSet.new([
                         "command",
                         "model",
                         "permission_mode",
                         "turn_timeout_ms",
                         "read_timeout_ms",
                         "stall_timeout_ms"
                       ])

  @claude_permission_modes [
    "acceptEdits",
    "auto",
    "bypassPermissions",
    "default",
    "dontAsk",
    "plan"
  ]

  @type loaded_project_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t(),
          hooks: Schema.Hooks.t(),
          agent: Schema.Agent.t(),
          codex: Schema.Codex.t(),
          opencode: Schema.OpenCode.t(),
          claude: Schema.Claude.t()
        }

  @spec load(Path.t()) :: {:ok, loaded_project_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, %{config: config} = workflow} <- Workflow.load(path),
         {:ok, normalized, hooks, agent, codex, opencode, claude} <- validate_workflow_config(config) do
      {:ok,
       workflow
       |> Map.put(:config, normalized)
       |> Map.put(:hooks, hooks)
       |> Map.put(:agent, agent)
       |> Map.put(:codex, codex)
       |> Map.put(:opencode, opencode)
       |> Map.put(:claude, claude)}
    end
  end

  defp validate_workflow_config(config) when is_map(config) do
    normalized =
      config
      |> normalize_keys()
      |> drop_nil_values()

    with :ok <- validate_allowed_top_level_keys(normalized),
         :ok <- validate_allowed_nested_keys(normalized),
         {:ok, hooks} <- cast_hooks(Map.get(normalized, "hooks", %{})),
         {:ok, agent} <- cast_agent(Map.get(normalized, "agent", %{})),
         {:ok, codex} <- cast_codex(Map.get(normalized, "codex", %{})),
         {:ok, opencode} <- cast_opencode(Map.get(normalized, "opencode", %{})),
         {:ok, claude} <- cast_claude(Map.get(normalized, "claude", %{})) do
      {:ok, normalized, hooks, agent, codex, opencode, claude}
    end
  end

  defp validate_allowed_top_level_keys(config) when is_map(config) do
    case Enum.find(Map.keys(config), &(not MapSet.member?(@allowed_top_level_keys, &1))) do
      nil -> :ok
      key -> {:error, {:invalid_project_workflow_config, "unsupported key #{inspect(key)} in project workflow"}}
    end
  end

  defp validate_allowed_nested_keys(config) when is_map(config) do
    with :ok <- validate_map_keys(Map.get(config, "agent", %{}), @allowed_agent_keys, "agent"),
         :ok <- validate_map_keys(Map.get(config, "hooks", %{}), @allowed_hook_keys, "hooks"),
         :ok <- validate_map_keys(Map.get(config, "codex", %{}), @allowed_codex_keys, "codex"),
         :ok <- validate_map_keys(Map.get(config, "opencode", %{}), @allowed_opencode_keys, "opencode"),
         :ok <- validate_map_keys(Map.get(config, "claude", %{}), @allowed_claude_keys, "claude") do
      :ok
    end
  end

  defp validate_map_keys(%{} = map, allowed_keys, prefix) do
    case Enum.find(Map.keys(map), &(not MapSet.member?(allowed_keys, &1))) do
      nil -> :ok
      key -> {:error, {:invalid_project_workflow_config, "unsupported key #{inspect(prefix <> "." <> key)} in project workflow"}}
    end
  end

  defp validate_map_keys(_value, _allowed_keys, prefix) do
    {:error, {:invalid_project_workflow_config, "#{prefix} must be a map in project workflow"}}
  end

  defp cast_hooks(attrs) when is_map(attrs) do
    changeset =
      %Schema.Hooks{
        after_create: nil,
        before_run: nil,
        after_run: nil,
        before_remove: nil,
        timeout_ms: nil
      }
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)

    case apply_action(changeset, :validate) do
      {:ok, hooks} ->
        {:ok, hooks}

      {:error, %Ecto.Changeset{} = error_changeset} ->
        {:error, {:invalid_project_workflow_config, format_errors(error_changeset)}}
    end
  end

  defp cast_agent(attrs) when is_map(attrs) do
    base_agent = %Schema.Agent{
      backend: nil,
      default_effort: nil,
      max_concurrent_agents: nil,
      max_turns: nil,
      max_retry_backoff_ms: nil,
      max_concurrent_agents_by_state: nil
    }

    changeset = Schema.Agent.changeset(base_agent, attrs)

    case apply_action(changeset, :validate) do
      {:ok, agent} ->
        {:ok, agent}

      {:error, %Ecto.Changeset{} = error_changeset} ->
        {:error, {:invalid_project_workflow_config, format_errors(error_changeset)}}
    end
  end

  defp cast_codex(attrs) when is_map(attrs) do
    changeset =
      %Schema.Codex{
        command: nil,
        approval_policy: nil,
        thread_sandbox: nil,
        turn_sandbox_policy: nil,
        turn_timeout_ms: nil,
        read_timeout_ms: nil,
        stall_timeout_ms: nil
      }
      |> cast(
        attrs,
        [:command, :approval_policy, :thread_sandbox, :turn_sandbox_policy, :turn_timeout_ms, :read_timeout_ms, :stall_timeout_ms],
        empty_values: []
      )
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)

    case apply_action(changeset, :validate) do
      {:ok, codex} ->
        {:ok, codex}

      {:error, %Ecto.Changeset{} = error_changeset} ->
        {:error, {:invalid_project_workflow_config, format_errors(error_changeset)}}
    end
  end

  defp cast_opencode(attrs) when is_map(attrs) do
    changeset =
      %Schema.OpenCode{
        command: nil,
        agent: nil,
        model: nil,
        turn_timeout_ms: nil,
        read_timeout_ms: nil,
        stall_timeout_ms: nil
      }
      |> cast(attrs, [:command, :agent, :model, :turn_timeout_ms, :read_timeout_ms, :stall_timeout_ms], empty_values: [])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_change(:model, fn :model, value ->
        cond do
          is_nil(value) ->
            []

          is_binary(value) and String.trim(value) == "" ->
            []

          is_binary(value) and String.contains?(value, "/") ->
            []

          true ->
            [model: "must use provider/model format"]
        end
      end)

    case apply_action(changeset, :validate) do
      {:ok, opencode} ->
        {:ok, opencode}

      {:error, %Ecto.Changeset{} = error_changeset} ->
        {:error, {:invalid_project_workflow_config, format_errors(error_changeset)}}
    end
  end

  defp cast_claude(attrs) when is_map(attrs) do
    changeset =
      %Schema.Claude{
        command: nil,
        model: nil,
        permission_mode: nil,
        turn_timeout_ms: nil,
        read_timeout_ms: nil,
        stall_timeout_ms: nil
      }
      |> cast(attrs, [:command, :model, :permission_mode, :turn_timeout_ms, :read_timeout_ms, :stall_timeout_ms], empty_values: [])
      |> update_change(:model, &Schema.normalize_optional_string/1)
      |> update_change(:permission_mode, &Schema.normalize_optional_string/1)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_change(:permission_mode, fn :permission_mode, value ->
        cond do
          is_nil(value) ->
            []

          value in @claude_permission_modes ->
            []

          true ->
            [permission_mode: "must be one of: #{Enum.join(@claude_permission_modes, ", ")}"]
        end
      end)

    case apply_action(changeset, :validate) do
      {:ok, claude} ->
        {:ok, claude}

      {:error, %Ecto.Changeset{} = error_changeset} ->
        {:error, {:invalid_project_workflow_config, format_errors(error_changeset)}}
    end
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, normalize_key(key), normalize_keys(nested))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors) when is_map(errors) do
    Enum.flat_map(errors, fn {field, nested} ->
      flatten_errors(field, nested)
    end)
  end

  defp flatten_errors(prefix, errors) when is_list(errors) do
    Enum.flat_map(errors, fn
      message when is_binary(message) ->
        ["#{prefix} #{message}"]

      nested ->
        flatten_errors(prefix, nested)
    end)
  end

  defp flatten_errors(prefix, errors) when is_map(errors) do
    Enum.flat_map(errors, fn {field, nested} ->
      flatten_errors("#{prefix}.#{field}", nested)
    end)
  end
end
