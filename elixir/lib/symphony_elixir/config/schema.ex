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

  defmodule TrackerProjectRepo do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    # The name becomes the `repo/<name>` Linear label and a directory name.
    @name_pattern ~r/^[a-z0-9][a-z0-9._-]{0,63}$/

    embedded_schema do
      field(:name, :string)
      field(:repo, :string)
      field(:default_branch, :string)
      field(:description, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:name, :repo, :default_branch, :description], empty_values: [])
      |> update_change(:name, &(&1 |> Schema.normalize_optional_string() |> downcase()))
      |> update_change(:repo, &Schema.normalize_optional_string/1)
      |> update_change(:default_branch, &Schema.normalize_optional_string/1)
      |> update_change(:description, &Schema.normalize_optional_string/1)
      |> validate_required([:name, :repo])
      |> validate_format(:name, @name_pattern, message: "must be lowercase letters, digits, '.', '_' or '-'")
    end

    defp downcase(nil), do: nil
    defp downcase(value), do: String.downcase(value)
  end

  defmodule TrackerProject do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema
    alias SymphonyElixir.Config.Schema.TrackerProjectRepo

    @primary_key false
    @hook_keys ["after_create", "before_run", "after_run", "before_remove", "timeout_ms"]
    @fields [:slug, :repo, :workflow, :prompt, :hooks, :backend, :default_branch, :workspace_root, :environment]

    embedded_schema do
      field(:slug, :string)
      field(:repo, :string)
      # Optional repo-local WORKFLOW.md; without one Symphony's own prompt and config apply.
      field(:workflow, :string)
      # Optional prompt template file (relative to symphony.yml) replacing the built-in one.
      field(:prompt, :string)
      # Workspace hooks for this project, over the top-level `hooks`.
      field(:hooks, :map)
      field(:backend, :string)
      field(:default_branch, :string)
      field(:workspace_root, :string)
      # More repos agents may work in for this project; `repo` stays the primary.
      embeds_many(:repos, TrackerProjectRepo, on_replace: :delete)
      field(:environment, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> update_change(:slug, &Schema.normalize_optional_string/1)
      |> update_change(:repo, &Schema.normalize_optional_string/1)
      |> update_change(:workflow, &Schema.normalize_optional_string/1)
      |> update_change(:prompt, &Schema.normalize_optional_string/1)
      |> update_change(:backend, &Schema.normalize_optional_string/1)
      |> update_change(:default_branch, &Schema.normalize_optional_string/1)
      |> update_change(:workspace_root, &Schema.normalize_optional_string/1)
      |> update_change(:environment, &Schema.normalize_optional_string/1)
      |> validate_change(:backend, fn :backend, value ->
        if value in ["codex", "opencode", "claude"] do
          []
        else
          [backend: "must be one of: codex, opencode, claude"]
        end
      end)
      |> validate_change(:hooks, &validate_hooks/2)
      |> cast_embed(:repos, with: &TrackerProjectRepo.changeset/2)
      |> validate_required([:slug])
    end

    defp validate_hooks(:hooks, hooks) do
      cond do
        Enum.any?(Map.keys(hooks), &(to_string(&1) not in @hook_keys)) ->
          [hooks: "may only set #{Enum.join(@hook_keys, ", ")}"]

        Enum.any?(hooks, fn {key, value} -> to_string(key) != "timeout_ms" and not (is_binary(value) or is_nil(value)) end) ->
          [hooks: "commands must be strings"]

        not (is_nil(hooks["timeout_ms"]) or (is_integer(hooks["timeout_ms"]) and hooks["timeout_ms"] > 0)) ->
          [hooks: "timeout_ms must be a positive integer"]

        true ->
          []
      end
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
      field(:stage_label_prefix, :string, default: "factory")
      field(:paused_stages, {:array, :string}, default: ["blocked", "review"])
      # Opt-in label: when set, only issues carrying it are dispatched.
      field(:require_label, :string)
      # Agents add this label when a stage needs a person to approve the next move.
      field(:approval_label, :string, default: "needs-approval")
      embeds_many(:projects, TrackerProject, on_replace: :delete)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_slug,
          :assignee,
          :active_states,
          :terminal_states,
          :stage_label_prefix,
          :paused_stages,
          :require_label,
          :approval_label
        ],
        empty_values: []
      )
      |> update_change(:kind, &Schema.normalize_optional_string/1)
      |> update_change(:stage_label_prefix, &Schema.normalize_optional_string/1)
      |> update_change(:require_label, &Schema.normalize_optional_string/1)
      |> update_change(:approval_label, &Schema.normalize_optional_string/1)
      |> validate_required([:stage_label_prefix])
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

  defmodule RepoCache do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      # How old the last successful fetch may get before a workspace start
      # fetches from the remote again. 0 = fetch on every start.
      field(:max_age_ms, :integer, default: 60_000)
      # How often the background refresher warms each project cache. The
      # default is half the freshness window, so a fresh start usually skips
      # its own remote fetch. 0 = off.
      field(:refresh_interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:max_age_ms, :refresh_interval_ms], empty_values: [])
      |> validate_number(:max_age_ms, greater_than_or_equal_to: 0)
      |> validate_number(:refresh_interval_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema.RepoCache

    @primary_key false
    embedded_schema do
      # Resolved at parse time, not compile time, so a test run or a long-lived
      # build's TMPDIR is honored.
      field(:root, :string)
      embeds_one(:repo_cache, RepoCache, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
      |> cast_embed(:repo_cache, with: &RepoCache.changeset/2)
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

  defmodule Sandbox do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:kind, :string, default: "none")
      field(:command, :string, default: "docker")
      field(:image, :string)
      field(:network, :string)
      field(:mounts, {:array, :string}, default: [])
      field(:env, {:array, :string}, default: [])
      field(:run_args, {:array, :string}, default: [])
      # The per-issue environment resolved at dispatch (`SymphonyElixir.Environment`).
      # It is deliberately not cast from config: the platform catalog and the
      # repository's `.symphony/environment.yaml` are the only sources.
      field(:environment, :map)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:kind, :command, :image, :network, :mounts, :env, :run_args], empty_values: [])
      |> update_change(:image, &SymphonyElixir.Config.Schema.normalize_optional_string/1)
      |> update_change(:network, &SymphonyElixir.Config.Schema.normalize_optional_string/1)
      |> validate_inclusion(:kind, ["none", "docker"])
      |> then(fn changeset ->
        if get_field(changeset, :kind) == "docker", do: validate_required(changeset, [:image]), else: changeset
      end)
    end
  end

  defmodule GitHubApp do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @type t :: %__MODULE__{}

    @primary_key false
    @default_permissions %{
      "contents" => "write",
      "pull_requests" => "write",
      "metadata" => "read"
    }

    embedded_schema do
      field(:app_id, :integer)
      field(:private_key, :string)
      # Optional: without it, the installation is discovered per repository.
      field(:installation_id, :integer)
      field(:base_url, :string, default: "https://api.github.com")
      field(:permissions, :map, default: @default_permissions)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:app_id, :private_key, :installation_id, :base_url, :permissions], empty_values: [])
      |> update_change(:base_url, &Schema.normalize_optional_string/1)
      |> validate_change(:permissions, fn :permissions, permissions ->
        case SymphonyElixir.GitHubApp.validate_permissions(permissions) do
          {:ok, _permissions} -> []
          {:error, reason} -> [permissions: permissions_error(reason)]
        end
      end)
      |> then(fn changeset ->
        if get_field(changeset, :app_id) || get_field(changeset, :private_key) do
          validate_required(changeset, [:app_id, :private_key])
        else
          changeset
        end
      end)
    end

    defp permissions_error({:forbidden_permissions, keys}) do
      allowed = Enum.join(SymphonyElixir.GitHubApp.allowed_permissions(), ", ")
      "must not include #{Enum.join(keys, ", ")} (allowed: #{allowed})"
    end

    defp permissions_error({:invalid_permissions, :empty}), do: "must not be empty (GitHub grants every permission for an empty map)"
    # The field is cast as :map, so validate_permissions/1 never sees a non-map here.
    defp permissions_error({:invalid_permissions, keys}), do: "must use read or write for #{Enum.join(keys, ", ")}"
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

  defmodule Accounts do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @rotation_strategies ["usage_aware_round_robin", "least_usage"]

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:store_root, :string, default: "~/.symphony/accounts")
      field(:allow_host_auth_fallback, :boolean, default: false)
      field(:rotation_strategy, :string, default: "usage_aware_round_robin")
      field(:max_concurrent_sessions_per_account, :integer, default: 1)
      field(:exhausted_cooldown_ms, :integer, default: 300_000)
      field(:daily_token_budget, :integer)
      field(:claude_rate_limit_probe_interval_ms, :integer, default: 900_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      attrs =
        normalize_boolean_attrs(attrs, [
          :enabled,
          :allow_host_auth_fallback
        ])

      schema
      |> cast(
        attrs,
        [
          :enabled,
          :store_root,
          :allow_host_auth_fallback,
          :rotation_strategy,
          :max_concurrent_sessions_per_account,
          :exhausted_cooldown_ms,
          :daily_token_budget,
          :claude_rate_limit_probe_interval_ms
        ],
        empty_values: []
      )
      |> validate_required([:store_root, :rotation_strategy])
      |> validate_inclusion(:rotation_strategy, @rotation_strategies)
      |> validate_number(:max_concurrent_sessions_per_account, greater_than: 0)
      |> validate_number(:exhausted_cooldown_ms, greater_than_or_equal_to: 0)
      |> validate_number(:daily_token_budget, greater_than: 0)
      |> validate_number(:claude_rate_limit_probe_interval_ms, greater_than_or_equal_to: 60_000)
    end

    defp normalize_boolean_attrs(attrs, fields) when is_map(attrs) do
      Enum.reduce(fields, attrs, fn field, acc ->
        acc
        |> normalize_boolean_attr(field)
        |> normalize_boolean_attr(Atom.to_string(field))
      end)
    end

    defp normalize_boolean_attrs(attrs, _fields), do: attrs

    defp normalize_boolean_attr(attrs, field) do
      case Map.fetch(attrs, field) do
        {:ok, value} ->
          Map.put(attrs, field, normalize_boolean_value(value))

        :error ->
          attrs
      end
    end

    defp normalize_boolean_value(value) when is_binary(value) do
      case String.downcase(String.trim(value)) do
        truthy when truthy in ["true", "yes", "on", "1"] -> true
        falsy when falsy in ["false", "no", "off", "0"] -> false
        _ -> value
      end
    end

    defp normalize_boolean_value(value), do: value
  end

  defmodule Kubernetes do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:namespace, :string, default: "symphony-runs")
      # Required by the Kubernetes launcher; omitted here so a non-Kubernetes
      # install doesn't have to configure an image it never runs.
      field(:runner_image, :string)
      field(:agent_tools_image, :string)
      field(:cpu_request, :string, default: "500m")
      field(:cpu_limit, :string, default: "2")
      field(:memory_request, :string, default: "1Gi")
      field(:memory_limit, :string, default: "4Gi")
      field(:active_deadline_seconds, :integer, default: 21_600)
      # The uid/gid every runner container runs as (and the pod fsGroup).
      field(:run_as_user, :integer, default: 10_001)
      # Kueue LocalQueue the pod is labelled for; "" leaves the label off.
      field(:queue_name, :string, default: "symphony")
      # emptyDir size limits and the runner's ephemeral-storage; "" omits each.
      field(:workspace_size_limit, :string, default: "20Gi")
      field(:agent_tools_size_limit, :string, default: "1Gi")
      field(:ephemeral_storage_request, :string, default: "2Gi")
      field(:ephemeral_storage_limit, :string, default: "24Gi")
      # The agent-tools init container's ephemeral-storage request; "" omits it.
      field(:agent_tools_ephemeral_storage_request, :string, default: "256Mi")
      # [{env, secret, key}] references to existing secrets, injected by name.
      field(:secret_env, {:array, :map}, default: [])
      # The controller URL as a runner pod reaches it (a cluster Service), for
      # the /runner/v1 endpoints and the git mirror. Required by the launcher.
      field(:controller_url, :string)
      # The OTLP collector runner pods (the runner and its agents) export to,
      # such as an in-cluster collector Service; unset, pods use the telemetry
      # endpoints. A URL only: exporter credentials stay in the collector.
      field(:otlp_endpoint, :string)
      field(:otlp_protocol, :string, default: "http/protobuf")
      # How long a finished runner pod is kept for its logs before the janitor
      # deletes it, and how often the janitor sweeps.
      field(:finished_pod_retention_ms, :integer, default: 3_600_000)
      field(:janitor_interval_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :namespace,
          :runner_image,
          :agent_tools_image,
          :cpu_request,
          :cpu_limit,
          :memory_request,
          :memory_limit,
          :active_deadline_seconds,
          :run_as_user,
          :queue_name,
          :workspace_size_limit,
          :agent_tools_size_limit,
          :ephemeral_storage_request,
          :ephemeral_storage_limit,
          :agent_tools_ephemeral_storage_request,
          :secret_env,
          :controller_url,
          :otlp_endpoint,
          :otlp_protocol,
          :finished_pod_retention_ms,
          :janitor_interval_ms
        ],
        empty_values: []
      )
      |> update_change(:namespace, &normalize_namespace/1)
      |> update_change(:runner_image, &Schema.normalize_optional_string/1)
      |> update_change(:agent_tools_image, &Schema.normalize_optional_string/1)
      |> update_change(:queue_name, &Schema.normalize_optional_string/1)
      |> update_change(:workspace_size_limit, &Schema.normalize_optional_string/1)
      |> update_change(:agent_tools_size_limit, &Schema.normalize_optional_string/1)
      |> update_change(:ephemeral_storage_request, &Schema.normalize_optional_string/1)
      |> update_change(:ephemeral_storage_limit, &Schema.normalize_optional_string/1)
      |> update_change(:controller_url, &Schema.normalize_optional_string/1)
      |> update_change(:agent_tools_ephemeral_storage_request, &Schema.normalize_optional_string/1)
      |> validate_required([:namespace, :cpu_request, :cpu_limit, :memory_request, :memory_limit, :run_as_user])
      |> validate_format(:namespace, ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, message: "must be a DNS label such as symphony-runs")
      |> validate_format(:queue_name, ~r/^[A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?$/, message: "must be a label value such as symphony")
      |> validate_number(:active_deadline_seconds, greater_than: 0)
      |> validate_number(:run_as_user, greater_than: 0)
      |> validate_number(:finished_pod_retention_ms, greater_than_or_equal_to: 0)
      |> validate_number(:janitor_interval_ms, greater_than: 0)
      |> validate_format(:controller_url, ~r{^https?://[^\s/]+}, message: "must be an http(s) URL such as http://symphony.symphony.svc:4000")
      |> update_change(:otlp_endpoint, &Schema.normalize_optional_string/1)
      |> validate_format(:otlp_endpoint, ~r{^https?://[^\s/@]+(/\S*)?$}, message: "must be an http(s) URL without credentials such as http://otel-collector.symphony.svc:4318")
      |> validate_inclusion(:otlp_protocol, ["grpc", "http/protobuf", "http/json"])
      |> validate_change(:secret_env, &validate_secret_env/2)
    end

    defp normalize_namespace(namespace) when is_binary(namespace) do
      case Schema.normalize_optional_string(namespace) do
        nil -> nil
        trimmed -> String.downcase(trimmed)
      end
    end

    defp validate_secret_env(:secret_env, entries) do
      Enum.flat_map(entries, fn entry ->
        if valid_secret_env?(entry) do
          []
        else
          [secret_env: "entries must set non-empty env, secret and key"]
        end
      end)
    end

    defp valid_secret_env?(entry) when is_map(entry) do
      Enum.all?(["env", "secret", "key"], fn field ->
        value = Map.get(entry, field) || Map.get(entry, String.to_atom(field))
        is_binary(value) and String.trim(value) != ""
      end)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    alias SymphonyElixir.Config.Schema
    @effort_values ["low", "medium", "high", "xhigh", "max"]

    @primary_key false
    embedded_schema do
      field(:backend, :string)
      field(:default_effort, :string)
      field(:launcher, :string, default: "local")
      field(:runner_command, :string, default: "setsid {symphony} runner {spec} --i-understand-that-this-will-be-running-without-the-usual-guardrails")
      field(:runner_finish_flush_ms, :integer, default: 3_600_000)
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:tracker_task_timeout_ms, :integer, default: 60_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      embeds_one(:kubernetes, Kubernetes, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :backend,
          :default_effort,
          :launcher,
          :runner_command,
          :runner_finish_flush_ms,
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :tracker_task_timeout_ms,
          :max_concurrent_agents_by_state
        ],
        empty_values: []
      )
      |> update_change(:backend, &Schema.normalize_optional_string/1)
      |> update_change(:default_effort, &Schema.normalize_optional_effort/1)
      |> update_change(:launcher, &Schema.normalize_optional_string/1)
      |> update_change(:runner_command, &Schema.normalize_optional_string/1)
      |> validate_change(:backend, fn :backend, value ->
        if value in ["codex", "opencode", "claude"] do
          []
        else
          [backend: "must be one of: codex, opencode, claude"]
        end
      end)
      |> validate_change(:default_effort, fn :default_effort, value ->
        if value in @effort_values do
          []
        else
          [default_effort: "must be one of: #{Enum.join(@effort_values, ", ")}"]
        end
      end)
      |> validate_change(:launcher, fn :launcher, value ->
        if value in ["local", "process", "kubernetes"] do
          []
        else
          [launcher: "must be one of: local, process, kubernetes"]
        end
      end)
      |> validate_change(:runner_command, fn :runner_command, value ->
        if is_binary(value) and Enum.all?(["{symphony}", "{spec}", "{run_id}"], &String.contains?(value, &1)) do
          []
        else
          [runner_command: "must include {symphony}, {spec} and {run_id} placeholders"]
        end
      end)
      |> validate_number(:runner_finish_flush_ms, greater_than: 0)
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:tracker_task_timeout_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
      |> cast_embed(:kubernetes, with: &Kubernetes.changeset/2)
    end
  end

  defmodule OpenCode do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

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

    @type t :: %__MODULE__{}

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")
      # Sent with every new thread, so it wins over the model in ~/.codex/config.toml.
      field(:model, :string)

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
          :model,
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

    @type t :: %__MODULE__{}
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
      # Claude Code can take half a minute to start (plugins, MCP servers, hooks).
      field(:read_timeout_ms, :integer, default: 120_000)
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
        if value in @permission_modes do
          []
        else
          [permission_mode: "must be one of: #{Enum.join(@permission_modes, ", ")}"]
        end
      end)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

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

  defmodule ObservabilityClickHouse do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    # ClickHouse HTTP interface holding the OpenTelemetry collector's tables.
    embedded_schema do
      field(:url, :string)
      field(:user, :string)
      field(:password, :string)
      field(:database, :string, default: "otel")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      cast(schema, attrs, [:url, :user, :password, :database], empty_values: [])
    end
  end

  defmodule ObservabilityLangfuse do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    # Langfuse public REST API (basic auth with the project's key pair).
    embedded_schema do
      field(:url, :string)
      field(:public_key, :string)
      field(:secret_key, :string)
      # Base URL for links people open in a browser; nil = no UI links.
      field(:public_url, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      cast(schema, attrs, [:url, :public_key, :secret_key, :public_url], empty_values: [])
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema.{ObservabilityClickHouse, ObservabilityLangfuse}

    @primary_key false

    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
      # Read-side metrics and traces for the dashboard (see SymphonyElixir.Observability).
      field(:timeout_ms, :integer, default: 3_000)
      field(:cache_ttl_ms, :integer, default: 30_000)
      embeds_one(:clickhouse, ObservabilityClickHouse, on_replace: :update, defaults_to_struct: true)
      embeds_one(:langfuse, ObservabilityLangfuse, on_replace: :update, defaults_to_struct: true)
    end

    @fields [:dashboard_enabled, :refresh_ms, :render_interval_ms, :timeout_ms, :cache_ttl_ms]

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
      |> validate_number(:timeout_ms, greater_than: 0)
      |> validate_number(:cache_ttl_ms, greater_than_or_equal_to: 0)
      |> cast_embed(:clickhouse, with: &ObservabilityClickHouse.changeset/2)
      |> cast_embed(:langfuse, with: &ObservabilityLangfuse.changeset/2)
    end
  end

  defmodule Capacity do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:sample_interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:sample_interval_ms])
      |> validate_required([:sample_interval_ms])
      |> validate_change(:sample_interval_ms, fn :sample_interval_ms, value ->
        if value == 0 or (is_integer(value) and value >= 1_000) do
          []
        else
          [sample_interval_ms: "must be 0 (off) or at least 1000"]
        end
      end)
    end
  end

  defmodule GitMirror do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      # Concurrent `git upload-pack` processes the read-only mirror runs; a
      # request over the cap gets 503 with Retry-After.
      field(:max_concurrent, :integer, default: 8)
      # How long a mirror request may go without git producing output before
      # the git process is killed. There is no total deadline.
      field(:idle_timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:max_concurrent, :idle_timeout_ms], empty_values: [])
      |> validate_number(:max_concurrent, greater_than: 0)
      |> validate_number(:idle_timeout_ms, greater_than: 0)
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
      field(:otlp_traces_endpoint, :string)
      field(:otlp_traces_protocol, :string)
      field(:otlp_logs_endpoint, :string)
      field(:otlp_logs_protocol, :string)
      field(:otlp_metrics_endpoint, :string)
      field(:otlp_metrics_protocol, :string)
      field(:include_traces, :boolean, default: true)
      field(:include_metrics, :boolean, default: true)
      field(:include_logs, :boolean, default: true)
      field(:log_user_prompts, :boolean, default: false)
      field(:log_tool_details, :boolean, default: false)
      field(:resource_attributes, :map, default: %{})
      # Symphony's own run spans (SymphonyElixir.TraceExporter): on/off and the
      # exporter's bounds, so a slow collector costs dropped spans, not memory.
      field(:symphony_spans, :boolean, default: true)
      field(:span_max_queue_size, :integer, default: 2048)
      field(:span_max_batch_size, :integer, default: 512)
      field(:span_export_interval_ms, :integer, default: 5_000)
      field(:span_export_timeout_ms, :integer, default: 5_000)
    end

    @otlp_protocols ["grpc", "http/protobuf", "http/json"]

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :otlp_endpoint,
          :otlp_protocol,
          :otlp_traces_endpoint,
          :otlp_traces_protocol,
          :otlp_logs_endpoint,
          :otlp_logs_protocol,
          :otlp_metrics_endpoint,
          :otlp_metrics_protocol,
          :include_traces,
          :include_metrics,
          :include_logs,
          :log_user_prompts,
          :log_tool_details,
          :resource_attributes,
          :symphony_spans,
          :span_max_queue_size,
          :span_max_batch_size,
          :span_export_interval_ms,
          :span_export_timeout_ms
        ],
        empty_values: []
      )
      |> validate_number(:span_max_queue_size, greater_than: 0)
      |> validate_number(:span_max_batch_size, greater_than: 0)
      |> validate_number(:span_export_interval_ms, greater_than: 0)
      |> validate_number(:span_export_timeout_ms, greater_than: 0)
      |> validate_inclusion(:otlp_protocol, @otlp_protocols)
      |> validate_inclusion(:otlp_traces_protocol, @otlp_protocols)
      |> validate_inclusion(:otlp_logs_protocol, @otlp_protocols)
      |> validate_inclusion(:otlp_metrics_protocol, @otlp_protocols)
    end
  end

  defmodule ServerMcp do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # Off by default: /mcp answers 404 until this is true.
      field(:enabled, :boolean, default: false)
      # Optional hostname that serves only /mcp (e.g. mcp.symphony.example.com),
      # so a proxy route without browser sign-in in front (no IAP) can't reach
      # the dashboard even if it forwards every path.
      field(:host, :string)
      # Browser origins allowed to call /mcp. Agents don't send Origin; any
      # request that does must match one of these, or server.public_url.
      field(:allowed_origins, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :host, :allowed_origins], empty_values: [])
      |> update_change(:host, &normalize_host/1)
      |> validate_format(:host, ~r/^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$/, message: "must be a bare hostname such as mcp.symphony.example.com")
    end

    # Only strings reach this (cast already checked the type).
    defp normalize_host(host), do: host |> String.trim() |> String.downcase() |> then(&if(&1 == "", do: nil, else: &1))
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema.ServerMcp

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
      # false makes the dashboard read-only for everyone (kill switch).
      field(:controls, :boolean)
      # Dashboard sign-in: "local" (no sign-in) or "iap" (Google Identity-Aware
      # Proxy in front signs people in; permissions from Linear). "accounts" is
      # the old name for "iap". nil = local on loopback hosts, iap elsewhere.
      field(:auth, :string)
      # IAP's signed-header audiences, /projects/<number>/global/backendServices/<id>.
      # Several while the load balancer moves between backend services.
      field(:iap_audiences, {:array, :string}, default: [])
      # Optional bearer token for the JSON API and /metrics (e.g. Prometheus).
      field(:api_token, :string)
      # Behind a TLS-terminating proxy: trust X-Forwarded-For / X-Forwarded-Proto.
      field(:trust_proxy, :boolean, default: false)
      # The address people open, e.g. https://symphony.example.com, when it differs
      # from the listener (a proxy or load balancer in front). LiveView accepts
      # sockets from exactly this origin; Phoenix checks them before any proxy
      # header is read, so behind TLS termination nothing else can match.
      field(:public_url, :string)
      # Signs and encrypts session cookies. nil = generated once and kept in
      # ~/.symphony/secret_key_base so sessions survive restarts.
      field(:secret_key_base, :string)
      # The MCP endpoint for agents (/mcp, bearer tokens); see ServerMcp.
      embeds_one(:mcp, ServerMcp, on_replace: :update, defaults_to_struct: true)
    end

    @server_fields [
      :port,
      :host,
      :controls,
      :auth,
      :iap_audiences,
      :secret_key_base,
      :api_token,
      :trust_proxy,
      :public_url
    ]

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @server_fields, empty_values: [])
      |> validate_inclusion(:auth, ["local", "iap", "accounts"])
      |> validate_change(:public_url, &validate_public_url/2)
      |> validate_length(:api_token, min: 24)
      |> validate_length(:secret_key_base, min: 64)
      |> validate_number(:port, greater_than_or_equal_to: 0)
      |> cast_embed(:mcp, with: &ServerMcp.changeset/2)
    end

    defp validate_public_url(field, url) do
      %URI{scheme: scheme, host: host, path: path} = URI.parse(url)

      if scheme in ["http", "https"] and host not in [nil, ""] and path in [nil, "", "/"] do
        []
      else
        [{field, "must be an http(s) origin such as https://symphony.example.com"}]
      end
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
      # Optional brand logo (an SVG, PNG, JPEG, or WebP file) shown in the top bar.
      field(:logo, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:name, :logo], empty_values: [])
      |> update_change(:name, &Schema.normalize_optional_string/1)
      |> update_change(:logo, &Schema.normalize_optional_string/1)
    end
  end

  defmodule Log do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:dir, :string)
      field(:file_name, :string, default: "symphony.log")
      field(:max_bytes, :integer)
      field(:max_files, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dir, :file_name, :max_bytes, :max_files], empty_values: [])
      |> update_change(:dir, &Schema.normalize_optional_string/1)
      |> update_change(:file_name, &Schema.normalize_optional_string/1)
      |> validate_number(:max_bytes, greater_than: 0)
      |> validate_number(:max_files, greater_than: 0)
    end
  end

  embedded_schema do
    # USD per million tokens, keyed by "<backend>/<model>" or "<backend>":
    # %{"claude" => %{"input_per_mtok" => 3.0, "output_per_mtok" => 15.0}}
    field(:pricing, :map, default: %{})
    # Platform-owned environment catalog, keyed by name. Each entry owns the
    # security bounds (image prefixes, max resources) that a repo file may not widen.
    field(:environments, :map, default: %{})
    # Team defaults, keyed by Linear team key (e.g. PAY) -> %{"environment" => name}.
    field(:teams, :map, default: %{})
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:providers, Providers, on_replace: :update, defaults_to_struct: true)
    embeds_one(:sandbox, Sandbox, on_replace: :update, defaults_to_struct: true)
    embeds_one(:github_app, GitHubApp, on_replace: :update, defaults_to_struct: true)
    embeds_one(:accounts, Accounts, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:opencode, OpenCode, on_replace: :update, defaults_to_struct: true)
    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:capacity, Capacity, on_replace: :update, defaults_to_struct: true)
    embeds_one(:git_mirror, GitMirror, on_replace: :update, defaults_to_struct: true)
    embeds_one(:telemetry, Telemetry, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:instance, Instance, on_replace: :update, defaults_to_struct: true)
    embeds_one(:log, Log, on_replace: :update, defaults_to_struct: true)
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
    |> cast(attrs, [:pricing, :environments, :teams])
    |> validate_change(:pricing, &validate_pricing/2)
    |> validate_change(:environments, &validate_environments/2)
    |> validate_change(:teams, &validate_teams/2)
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:providers, with: &Providers.changeset/2)
    |> cast_embed(:sandbox, with: &Sandbox.changeset/2)
    |> cast_embed(:github_app, with: &GitHubApp.changeset/2)
    |> cast_embed(:accounts, with: &Accounts.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:opencode, with: &OpenCode.changeset/2)
    |> cast_embed(:claude, with: &Claude.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:capacity, with: &Capacity.changeset/2)
    |> cast_embed(:git_mirror, with: &GitMirror.changeset/2)
    |> cast_embed(:telemetry, with: &Telemetry.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:instance, with: &Instance.changeset/2)
    |> cast_embed(:log, with: &Log.changeset/2)
  end

  defp validate_pricing(:pricing, pricing) do
    Enum.flat_map(pricing, fn
      {key, %{} = rates} ->
        if Enum.all?(rates, &valid_pricing_rate?/1) do
          []
        else
          [pricing: "#{key} must set non-negative input_per_mtok / output_per_mtok / cached_input_per_mtok numbers, or openrouter_model"]
        end

      {key, _rates} ->
        [pricing: "#{key} must be a map of input_per_mtok / output_per_mtok / cached_input_per_mtok, or openrouter_model"]
    end)
  end

  defp valid_pricing_rate?({"openrouter_model", value}), do: is_binary(value) and String.trim(value) != ""

  defp valid_pricing_rate?({rate_key, value}) do
    rate_key in ["input_per_mtok", "output_per_mtok", "cached_input_per_mtok"] and is_number(value) and value >= 0
  end

  @environment_name_pattern ~r/^[a-z0-9][a-z0-9._-]{0,63}$/

  defp validate_environments(:environments, environments) when is_map(environments) do
    Enum.flat_map(environments, fn {name, entry} ->
      case environment_entry_error(name, entry) do
        nil -> []
        message -> [environments: message]
      end
    end)
  end

  defp environment_entry_error(name, entry) when is_binary(name) and name != "" do
    cond do
      not is_map(entry) ->
        "environment #{inspect(name)} must be a map"

      not is_binary(Map.get(entry, "image")) or String.trim(Map.get(entry, "image", "")) == "" ->
        "environment #{inspect(name)} needs an image"

      true ->
        environment_entry_list_error(name, entry)
    end
  end

  defp environment_entry_error(_name, _entry), do: "environment names must be non-empty strings"

  defp environment_entry_list_error(name, entry) do
    cond do
      not is_map(Map.get(entry, "resources", %{})) ->
        "environment #{inspect(name)} resources must be a map"

      not is_list(Map.get(entry, "services", [])) ->
        "environment #{inspect(name)} services must be a list"

      not string_list?(Map.get(entry, "allowed_images", [])) ->
        "environment #{inspect(name)} allowed_images must be a list of strings"

      not Enum.all?(Map.get(entry, "allowed_images", []), &String.ends_with?(&1, ["/", ":", "@"])) ->
        "environment #{inspect(name)} allowed_images entries must end in /, : or @"

      not valid_max_services?(Map.get(entry, "max_services")) ->
        "environment #{inspect(name)} max_services must be a non-negative integer"

      not is_map(Map.get(entry, "service_resources", %{})) ->
        "environment #{inspect(name)} service_resources must be a map"

      not string_list?(Map.get(entry, "egress_extra", [])) ->
        "environment #{inspect(name)} egress_extra must be a list of strings"

      true ->
        nil
    end
  end

  defp validate_teams(:teams, teams) when is_map(teams) do
    Enum.flat_map(teams, fn {key, team} ->
      cond do
        not is_binary(key) or String.trim(key) == "" ->
          [teams: "team keys must be non-empty strings"]

        not is_map(team) ->
          [teams: "team #{inspect(key)} must be a map"]

        not valid_environment_name?(Map.get(team, "environment")) ->
          [teams: "team #{inspect(key)} environment must be a catalog environment name"]

        true ->
          []
      end
    end)
  end

  defp valid_max_services?(nil), do: true
  defp valid_max_services?(value), do: is_integer(value) and value >= 0

  defp string_list?(value) when is_list(value), do: Enum.all?(value, &is_binary/1)
  defp string_list?(_value), do: false

  defp valid_environment_name?(nil), do: true
  defp valid_environment_name?(name) when is_binary(name), do: Regex.match?(@environment_name_pattern, name)
  defp valid_environment_name?(_name), do: false

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

    accounts = %{
      settings.accounts
      | store_root: resolve_path_value(settings.accounts.store_root, "~/.symphony/accounts", base_dir)
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

    observability = finalize_observability(settings.observability)

    log = %{
      settings.log
      | dir: resolve_optional_path_value(settings.log.dir, nil, base_dir),
        file_name: normalize_optional_string(settings.log.file_name) || "symphony.log"
    }

    github_app = %{
      settings.github_app
      | private_key:
          resolve_secret_setting(
            settings.github_app.private_key,
            System.get_env("GITHUB_APP_PRIVATE_KEY")
          ),
        base_url: resolve_optional_setting(settings.github_app.base_url) || "https://api.github.com"
    }

    %{
      settings
      | tracker: tracker,
        workspace: workspace,
        providers: providers,
        accounts: accounts,
        agent: agent,
        codex: codex,
        opencode: opencode,
        claude: claude,
        telemetry: telemetry,
        observability: observability,
        log: log,
        environments: normalize_environments(settings.environments),
        teams: normalize_teams(settings.teams),
        github_app: github_app
    }
  end

  defp normalize_environments(environments) when is_map(environments) do
    Map.new(environments, fn {name, entry} ->
      {name |> to_string() |> String.trim() |> String.downcase(), normalize_keys(entry)}
    end)
  end

  defp normalize_teams(teams) when is_map(teams) do
    Map.new(teams, fn {key, team} ->
      key = key |> to_string() |> String.trim() |> String.upcase()

      team =
        if is_map(team), do: normalize_keys(team), else: team

      {key, team}
    end)
  end

  # Secrets and URLs may be `$ENV_VAR` references; a missing variable leaves the field unset.
  defp finalize_observability(%{clickhouse: clickhouse, langfuse: langfuse} = observability) do
    clickhouse = %{
      clickhouse
      | url: resolve_optional_setting(clickhouse.url),
        user: resolve_optional_setting(clickhouse.user),
        password: resolve_optional_setting(clickhouse.password),
        database: resolve_optional_setting(clickhouse.database) || "otel"
    }

    langfuse = %{
      langfuse
      | url: resolve_optional_setting(langfuse.url),
        public_key: resolve_optional_setting(langfuse.public_key),
        secret_key: resolve_optional_setting(langfuse.secret_key),
        public_url: resolve_optional_setting(langfuse.public_url)
    }

    %{observability | clickhouse: clickhouse, langfuse: langfuse}
  end

  defp resolve_optional_setting(nil), do: nil

  defp resolve_optional_setting(value) when is_binary(value) do
    value |> resolve_env_value(nil) |> normalize_optional_string()
  end

  defp finalize_tracker_project(project, default_workspace_root, base_dir) do
    %{
      project
      | slug: normalize_optional_string(project.slug),
        repo: resolve_repo_value(project.repo, base_dir),
        workflow: resolve_optional_workflow_path_value(project.workflow, base_dir),
        prompt: resolve_optional_path_value(project.prompt, nil, base_dir),
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

  @spec normalize_optional_string(term()) :: term()
  def normalize_optional_string(nil), do: nil

  def normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_optional_string(value), do: value

  @spec normalize_optional_effort(term()) :: term()
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

  defp resolve_path_value(nil, default, _base_dir), do: default

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
    end
  end

  defp resolve_optional_workflow_path_value(nil, _base_dir), do: nil

  defp resolve_optional_workflow_path_value(value, _base_dir) when is_binary(value) do
    value
    |> resolve_env_value(nil)
    |> case do
      nil -> nil
      resolved when is_binary(resolved) -> normalize_optional_string(resolved)
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

  # symphony.yml may set `hooks` for every project (and each project its own).
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

  # embeds_many errors arrive as one map per item (empty for valid items).
  defp flatten_errors(errors, prefix) when is_list(errors) do
    errors
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{} = item_errors, index} -> flatten_errors(item_errors, "#{prefix}[#{index}]")
      {message, _index} -> [prefix <> " " <> message]
    end)
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
