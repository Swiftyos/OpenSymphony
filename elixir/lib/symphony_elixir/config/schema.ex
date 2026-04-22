defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule TrackerProject do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false

    embedded_schema do
      field(:slug, :string)
      field(:repo, :string)
      field(:workflow, :string)
      field(:backend, :string)
      field(:default_branch, :string)
      field(:workspace_root, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:slug, :repo, :workflow, :backend, :default_branch, :workspace_root], empty_values: [])
      |> update_change(:slug, &Schema.normalize_optional_string/1)
      |> update_change(:repo, &Schema.normalize_optional_string/1)
      |> update_change(:workflow, &Schema.normalize_optional_string/1)
      |> update_change(:backend, &Schema.normalize_optional_string/1)
      |> update_change(:default_branch, &Schema.normalize_optional_string/1)
      |> update_change(:workspace_root, &Schema.normalize_optional_string/1)
      |> validate_change(:backend, fn :backend, value ->
        cond do
          is_nil(value) ->
            []

          value in ["codex", "opencode", "claude"] ->
            []

          true ->
            [backend: "must be one of: codex, opencode, claude"]
        end
      end)
      |> validate_required([:slug])
    end
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema
    alias SymphonyElixir.Config.Schema.TrackerProject

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Backlog", "Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
      embeds_many(:projects, TrackerProject, on_replace: :delete)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :assignee, :active_states, :terminal_states],
        empty_values: []
      )
      |> update_change(:kind, &Schema.normalize_optional_string/1)
      |> update_change(:project_slug, &Schema.normalize_optional_string/1)
      |> update_change(:assignee, &Schema.normalize_optional_string/1)
      |> cast_embed(:projects, with: &TrackerProject.changeset/2)
      |> Schema.validate_unique_tracker_projects()
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Providers do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:openrouter_api_key, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:openrouter_api_key], empty_values: [])
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema
    @effort_values ["low", "medium", "high", "xhigh", "max"]

    @primary_key false
    embedded_schema do
      field(:backend, :string)
      field(:default_effort, :string)
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:backend, :default_effort, :max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> update_change(:backend, &Schema.normalize_optional_string/1)
      |> update_change(:default_effort, &Schema.normalize_optional_effort/1)
      |> validate_change(:backend, fn :backend, value ->
        cond do
          is_nil(value) ->
            []

          value in ["codex", "opencode", "claude"] ->
            []

          true ->
            [backend: "must be one of: codex, opencode, claude"]
        end
      end)
      |> validate_change(:default_effort, fn :default_effort, value ->
        cond do
          is_nil(value) ->
            []

          value in @effort_values ->
            []

          true ->
            [default_effort: "must be one of: #{Enum.join(@effort_values, ", ")}"]
        end
      end)
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule OpenCode do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "opencode serve --hostname 127.0.0.1 --port 0")
      field(:agent, :string, default: "build")
      field(:model, :string)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :agent,
          :model,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command, :agent])
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
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Claude do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset
    alias SymphonyElixir.Config.Schema

    @permission_modes [
      "acceptEdits",
      "auto",
      "bypassPermissions",
      "default",
      "dontAsk",
      "plan"
    ]

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "claude")
      field(:model, :string)
      field(:permission_mode, :string, default: "bypassPermissions")
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:command, :model, :permission_mode, :turn_timeout_ms, :read_timeout_ms, :stall_timeout_ms],
        empty_values: []
      )
      |> update_change(:model, &Schema.normalize_optional_string/1)
      |> update_change(:permission_mode, &Schema.normalize_optional_string/1)
      |> validate_required([:command, :permission_mode])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_change(:permission_mode, fn :permission_mode, value ->
        cond do
          is_nil(value) ->
            []

          value in @permission_modes ->
            []

          true ->
            [permission_mode: "must be one of: #{Enum.join(@permission_modes, ", ")}"]
        end
      end)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Telemetry do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:otlp_endpoint, :string)
      field(:otlp_protocol, :string, default: "grpc")
      field(:include_traces, :boolean, default: true)
      field(:include_metrics, :boolean, default: true)
      field(:include_logs, :boolean, default: true)
      field(:resource_attributes, :map, default: %{})
    end

    @otlp_protocols ["grpc", "http/protobuf", "http/json"]

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:enabled, :otlp_endpoint, :otlp_protocol, :include_traces, :include_metrics, :include_logs, :resource_attributes],
        empty_values: []
      )
      |> validate_inclusion(:otlp_protocol, @otlp_protocols)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule Instance do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:name, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:name], empty_values: [])
      |> update_change(:name, &Schema.normalize_optional_string/1)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:providers, Providers, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:opencode, OpenCode, on_replace: :update, defaults_to_struct: true)
    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:telemetry, Telemetry, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:instance, Instance, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map(), keyword()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config, opts \\ []) when is_map(config) do
    mode = Keyword.get(opts, :mode, :legacy)

    normalized_config =
      config
      |> normalize_keys()
      |> drop_nil_values()
      |> normalize_global_projects()
      |> normalize_tracker_project_aliases()

    with :ok <- validate_unsupported_config(normalized_config, mode),
         changeset <- changeset(normalized_config),
         {:ok, settings} <- apply_action(changeset, :validate),
         finalized_settings <- finalize_settings(settings, normalized_config, opts),
         :ok <- validate_open_code_local_only(finalized_settings) do
      {:ok, finalized_settings}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}

      {:error, {:invalid_workflow_config, _message} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:invalid_workflow_config, inspect(reason)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  @doc false
  @spec validate_unique_tracker_projects(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_unique_tracker_projects(changeset) do
    duplicates =
      changeset
      |> get_field(:projects, [])
      |> Enum.map(&normalize_optional_string(&1.slug))
      |> Enum.reject(&is_nil/1)
      |> duplicate_values()

    Enum.reduce(duplicates, changeset, fn slug, acc ->
      add_error(acc, :projects, "contains duplicate project slug #{inspect(slug)}")
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:providers, with: &Providers.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:opencode, with: &OpenCode.changeset/2)
    |> cast_embed(:claude, with: &Claude.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:telemetry, with: &Telemetry.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:instance, with: &Instance.changeset/2)
  end

  defp finalize_settings(settings, raw_config, opts) do
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())
    resolved_workspace_root = resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"), base_dir)

    tracker_projects =
      settings.tracker.projects
      |> Enum.map(&finalize_tracker_project(&1, resolved_workspace_root, base_dir))

    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        project_slug: normalize_optional_string(settings.tracker.project_slug),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE")),
        projects: tracker_projects
    }

    workspace = %{
      settings.workspace
      | root: resolved_workspace_root
    }

    providers = %{
      settings.providers
      | openrouter_api_key:
          resolve_secret_setting(
            settings.providers.openrouter_api_key,
            System.get_env("OPENROUTER_API_KEY")
          )
    }

    agent = %{
      settings.agent
      | backend: resolve_agent_backend(settings.agent.backend, raw_config)
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    opencode = %{
      settings.opencode
      | model: normalize_optional_string(settings.opencode.model)
    }

    claude = %{
      settings.claude
      | model: normalize_optional_string(settings.claude.model),
        permission_mode: normalize_optional_string(settings.claude.permission_mode) || "bypassPermissions"
    }

    telemetry = %{
      settings.telemetry
      | resource_attributes: normalize_resource_attributes(settings.telemetry.resource_attributes)
    }

    %{
      settings
      | tracker: tracker,
        workspace: workspace,
        providers: providers,
        agent: agent,
        codex: codex,
        opencode: opencode,
        claude: claude,
        telemetry: telemetry
    }
  end

  defp finalize_tracker_project(project, default_workspace_root, base_dir) do
    %{
      project
      | slug: normalize_optional_string(project.slug),
        repo: resolve_repo_value(project.repo, base_dir),
        workflow: resolve_optional_workflow_path_value(project.workflow, base_dir),
        backend: normalize_optional_string(project.backend),
        default_branch: normalize_optional_string(project.default_branch),
        workspace_root: resolve_optional_path_value(project.workspace_root, default_workspace_root, base_dir)
    }
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  def normalize_optional_string(nil), do: nil

  def normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_optional_string(value), do: value

  def normalize_optional_effort(nil), do: nil

  def normalize_optional_effort(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_optional_effort(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_resource_attributes(nil), do: %{}

  defp normalize_resource_attributes(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, val}, acc ->
      case normalize_optional_string(to_string(val)) do
        nil -> acc
        normalized -> Map.put(acc, to_string(key), normalized)
      end
    end)
  end

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

  defp normalize_global_projects(config) when is_map(config) do
    case Map.get(config, "projects") do
      projects when is_list(projects) ->
        tracker =
          config
          |> Map.get("tracker", %{})
          |> case do
            tracker when is_map(tracker) -> tracker
            _tracker -> %{}
          end

        config
        |> Map.delete("projects")
        |> Map.put("tracker", Map.put(tracker, "projects", projects))

      _ ->
        config
    end
  end

  defp normalize_tracker_project_aliases(config) when is_map(config) do
    case get_in(config, ["tracker", "projects"]) do
      projects when is_list(projects) ->
        put_in(
          config,
          ["tracker", "projects"],
          Enum.map(projects, fn
            %{} = project -> normalize_tracker_project_alias(project)
            other -> other
          end)
        )

      _ ->
        config
    end
  end

  defp normalize_tracker_project_alias(project) when is_map(project) do
    slug = Map.get(project, "slug") || Map.get(project, "linear_project")

    project
    |> Map.delete("linear_project")
    |> maybe_put_slug(slug)
  end

  defp maybe_put_slug(project, nil), do: project
  defp maybe_put_slug(project, slug), do: Map.put(project, "slug", slug)

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default, base_dir) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        maybe_expand_local_path_value(path, base_dir)
    end
  end

  defp resolve_optional_path_value(nil, _default, _base_dir), do: nil

  defp resolve_optional_path_value(value, default, base_dir) when is_binary(value) do
    case resolve_path_value(value, default, base_dir) do
      nil -> nil
      resolved when is_binary(resolved) -> normalize_optional_string(resolved)
      _ -> nil
    end
  end

  defp resolve_optional_workflow_path_value(nil, _base_dir), do: nil

  defp resolve_optional_workflow_path_value(value, _base_dir) when is_binary(value) do
    value
    |> resolve_env_value(nil)
    |> case do
      nil -> nil
      resolved when is_binary(resolved) -> normalize_optional_string(resolved)
      _ -> nil
    end
  end

  defp resolve_repo_value(nil, _base_dir), do: nil

  defp resolve_repo_value(value, base_dir) when is_binary(value) do
    value
    |> resolve_env_value(nil)
    |> case do
      nil ->
        nil

      resolved when is_binary(resolved) ->
        resolved
        |> normalize_optional_string()
        |> maybe_expand_local_repo_path(base_dir)

      _ ->
        nil
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp maybe_expand_local_repo_path(nil, _base_dir), do: nil

  defp maybe_expand_local_repo_path(value, base_dir) when is_binary(value) do
    if local_repo_path?(value) do
      expand_local_path(value, base_dir)
    else
      value
    end
  end

  defp expand_local_path(value, base_dir) when is_binary(value) do
    Path.expand(value, base_dir || File.cwd!())
  end

  defp maybe_expand_local_path_value(value, base_dir) when is_binary(value) do
    if local_path_token?(value) do
      expand_local_path(value, base_dir)
    else
      value
    end
  end

  defp local_repo_path?(value) when is_binary(value) do
    value in [".", "..", "~"] or String.starts_with?(value, ["./", "../", "/", "~/"])
  end

  defp local_path_token?(value) when is_binary(value) do
    value == "." or value == ".." or value == "~" or
      String.starts_with?(value, ["./", "../", "/", "~/"]) or
      !String.match?(value, ~r/^[A-Za-z][A-Za-z0-9+.-]*:/)
  end

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp duplicate_values(values) when is_list(values) do
    values
    |> Enum.frequencies()
    |> Enum.reduce([], fn
      {value, count}, acc when count > 1 -> [value | acc]
      {_value, _count}, acc -> acc
    end)
    |> Enum.reverse()
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp validate_unsupported_config(config, mode) when is_map(config) do
    with :ok <- validate_global_only_config(config, mode) do
      case unsupported_opencode_key(config) do
        nil ->
          :ok

        unsupported_opencode_key ->
          {:error, {:invalid_workflow_config, "`opencode.#{unsupported_opencode_key}` is no longer supported. OpenCode v1 uses `command`, `agent`, `model`, and timeout settings only."}}
      end
    end
  end

  defp validate_unsupported_config(_config, _mode), do: :ok

  defp validate_global_only_config(config, :global) when is_map(config) do
    if Map.has_key?(config, "hooks") do
      {:error, {:invalid_workflow_config, "`hooks` must be defined in repo-local WORKFLOW.md files when using symphony.yml"}}
    else
      :ok
    end
  end

  defp validate_global_only_config(_config, _mode), do: :ok

  defp unsupported_opencode_key(config) when is_map(config) do
    config
    |> Map.get("opencode", %{})
    |> case do
      opencode when is_map(opencode) ->
        Enum.find(["approval_policy", "thread_sandbox", "turn_sandbox_policy"], &Map.has_key?(opencode, &1))

      _ ->
        nil
    end
  end

  defp validate_open_code_local_only(%__MODULE__{agent: %{backend: backend}})
       when backend in ["codex", "claude"],
       do: :ok

  defp validate_open_code_local_only(settings) do
    ssh_hosts =
      settings.worker.ssh_hosts
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      ssh_hosts != [] ->
        {:error, {:invalid_workflow_config, "OpenCode v1 is local-only. Remove `worker.ssh_hosts` from `WORKFLOW.md`."}}

      is_integer(settings.worker.max_concurrent_agents_per_host) ->
        {:error, {:invalid_workflow_config, "OpenCode v1 is local-only. Remove `worker.max_concurrent_agents_per_host` from `WORKFLOW.md`."}}

      true ->
        :ok
    end
  end

  defp resolve_agent_backend(explicit_backend, raw_config) do
    case normalize_optional_string(explicit_backend) do
      backend when backend in ["codex", "opencode", "claude"] ->
        backend

      _ ->
        case provider_presence(raw_config) do
          {true, false, false} -> "codex"
          {false, true, false} -> "opencode"
          {false, false, true} -> "claude"
          _ -> "codex"
        end
    end
  end

  defp provider_presence(raw_config) do
    {
      provider_config_present?(raw_config, "codex"),
      provider_config_present?(raw_config, "opencode"),
      provider_config_present?(raw_config, "claude")
    }
  end

  defp provider_config_present?(config, key) when is_map(config) and is_binary(key) do
    Map.has_key?(config, key)
  end

  defp provider_config_present?(_config, _key), do: false

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
