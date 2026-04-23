defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Accounts, Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        settings = Config.settings!()
        running = Enum.map(snapshot.running, &running_entry_payload/1)
        retrying = Enum.map(snapshot.retrying, &retry_entry_payload/1)

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: running,
          retrying: retrying,
          agent_totals: snapshot.agent_totals,
          rate_limits: Map.get(snapshot, :rate_limits),
          polling: Map.get(snapshot, :polling),
          accounts: account_usage_payload(running, settings),
          projects: project_usage_payload(running, retrying, settings),
          telemetry: telemetry_payload(settings),
          capacity: capacity_payload(settings)
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      issue_title: issue_title_from_entries(running, retry),
      issue_url: issue_url_from_entries(running, retry),
      project: project_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        agent_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_title: Map.get(entry, :issue_title),
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      project_id: Map.get(entry, :project_id),
      project_slug: Map.get(entry, :project_slug),
      project_name: Map.get(entry, :project_name),
      labels: Map.get(entry, :labels, []),
      backend: Map.get(entry, :backend),
      effort: Map.get(entry, :effort),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      account: Map.get(entry, :account),
      account_id: Map.get(entry, :account_id),
      account_email: Map.get(entry, :account_email),
      account_state: Map.get(entry, :account_state),
      account_credential_kind: Map.get(entry, :account_credential_kind),
      account_reset_at: Map.get(entry, :account_reset_at),
      account_failure_reason: Map.get(entry, :account_failure_reason),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_agent_event,
      last_message: summarize_message(entry.last_agent_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_agent_timestamp),
      tokens: %{
        input_tokens: entry.agent_input_tokens,
        output_tokens: entry.agent_output_tokens,
        total_tokens: entry.agent_total_tokens
      },
      progress: progress_payload(entry.state, :running)
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_title: Map.get(entry, :issue_title),
      issue_url: Map.get(entry, :issue_url),
      project_id: Map.get(entry, :project_id),
      project_slug: Map.get(entry, :project_slug),
      project_name: Map.get(entry, :project_name),
      labels: Map.get(entry, :labels, []),
      state: "retrying",
      backend: Map.get(entry, :backend),
      effort: Map.get(entry, :effort),
      account: nil,
      account_id: nil,
      account_email: nil,
      account_state: nil,
      account_credential_kind: nil,
      account_reset_at: nil,
      account_failure_reason: nil,
      session_id: nil,
      turn_count: 0,
      started_at: nil,
      last_event: "retrying",
      last_message: entry.error,
      last_event_at: nil,
      tokens: %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0
      },
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      progress: progress_payload("retrying", :retrying)
    }
  end

  defp running_issue_payload(running) do
    %{
      issue_title: Map.get(running, :issue_title),
      issue_url: Map.get(running, :issue_url),
      project: project_from_entry(running),
      backend: Map.get(running, :backend),
      effort: Map.get(running, :effort),
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      account: Map.get(running, :account),
      account_id: Map.get(running, :account_id),
      account_email: Map.get(running, :account_email),
      account_state: Map.get(running, :account_state),
      account_credential_kind: Map.get(running, :account_credential_kind),
      account_reset_at: Map.get(running, :account_reset_at),
      account_failure_reason: Map.get(running, :account_failure_reason),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_agent_event,
      last_message: summarize_message(running.last_agent_message),
      last_event_at: iso8601(running.last_agent_timestamp),
      tokens: %{
        input_tokens: running.agent_input_tokens,
        output_tokens: running.agent_output_tokens,
        total_tokens: running.agent_total_tokens
      },
      progress: progress_payload(running.state, :running)
    }
  end

  defp retry_issue_payload(retry) do
    %{
      issue_title: Map.get(retry, :issue_title),
      issue_url: Map.get(retry, :issue_url),
      project: project_from_entry(retry),
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      progress: progress_payload("retrying", :retrying)
    }
  end

  defp account_usage_payload(running, settings) do
    running_counts = running_account_counts(running)
    host_auth_running_count = Map.get(running_counts, {"host", "host-auth"}, 0)

    settings
    |> configured_account_summaries()
    |> Kernel.++(Enum.flat_map(running, &running_account_summary/1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&account_key/1)
    |> Enum.map(fn account ->
      account_usage_entry(account, Map.get(running_counts, account_key(account), 0))
    end)
    |> maybe_add_host_auth_account(host_auth_running_count)
    |> Enum.sort_by(fn account -> {account.backend, account.id} end)
  end

  defp configured_account_summaries(%{accounts: %{enabled: true}} = settings) do
    case Accounts.list(nil, settings) do
      {:ok, accounts} ->
        Enum.map(accounts, fn account ->
          account
          |> Accounts.account_summary()
          |> Map.put(:daily_token_budget, Map.get(account, :daily_token_budget))
          |> Map.put(:monthly_token_budget, Map.get(account, :monthly_token_budget))
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp configured_account_summaries(_settings), do: []

  defp running_account_summary(entry) do
    cond do
      is_map(Map.get(entry, :account)) ->
        [Map.get(entry, :account)]

      is_binary(Map.get(entry, :account_id)) ->
        [
          %{
            backend: Map.get(entry, :backend),
            id: Map.get(entry, :account_id),
            email: Map.get(entry, :account_email),
            state: Map.get(entry, :account_state),
            credential_kind: Map.get(entry, :account_credential_kind),
            latest_reset_at: Map.get(entry, :account_reset_at),
            failure_reason: Map.get(entry, :account_failure_reason)
          }
        ]

      true ->
        []
    end
  end

  defp running_account_counts(running) do
    Enum.reduce(running, %{}, fn entry, counts ->
      key =
        case Map.get(entry, :account_id) do
          account_id when is_binary(account_id) and account_id != "" ->
            {Map.get(entry, :backend) || "unknown", account_id}

          _ ->
            {"host", "host-auth"}
        end

      Map.update(counts, key, 1, &(&1 + 1))
    end)
  end

  defp account_usage_entry(account, running_count) do
    token_totals = map_value(account, :token_totals) || %{}
    daily_tokens = token_period_total(token_totals, "daily")
    monthly_tokens = token_period_total(token_totals, "monthly")
    daily_budget = positive_integer(map_value(account, :daily_token_budget))
    monthly_budget = positive_integer(map_value(account, :monthly_token_budget))
    rate_limits = map_value(account, :latest_rate_limits)

    %{
      backend: map_value(account, :backend) || "unknown",
      id: map_value(account, :id) || "unknown",
      label: account_label(account),
      email: map_value(account, :email),
      state: map_value(account, :state) || "unknown",
      credential_kind: map_value(account, :credential_kind),
      worker_host: map_value(account, :worker_host),
      running_count: running_count,
      token_totals: token_totals,
      total_tokens: token_period_total(token_totals, "total"),
      daily_tokens: daily_tokens,
      monthly_tokens: monthly_tokens,
      daily_token_budget: daily_budget,
      monthly_token_budget: monthly_budget,
      daily_budget_percent: percent_of(daily_tokens, daily_budget),
      monthly_budget_percent: percent_of(monthly_tokens, monthly_budget),
      latest_rate_limits: rate_limits,
      rate_limit_buckets: rate_limit_bucket_payloads(rate_limits),
      latest_reset_at: map_value(account, :latest_reset_at),
      exhausted_until: map_value(account, :exhausted_until),
      paused_until: map_value(account, :paused_until),
      failure_reason: map_value(account, :failure_reason)
    }
  end

  defp account_key(account), do: {map_value(account, :backend) || "unknown", map_value(account, :id) || "unknown"}

  defp account_label(account) do
    cond do
      is_binary(map_value(account, :email)) and map_value(account, :email) != "" -> map_value(account, :email)
      is_binary(map_value(account, :id)) and map_value(account, :id) != "" -> map_value(account, :id)
      true -> "unknown"
    end
  end

  defp maybe_add_host_auth_account(accounts, 0), do: accounts

  defp maybe_add_host_auth_account(accounts, running_count) do
    host_account =
      account_usage_entry(
        %{
          backend: "host",
          id: "host-auth",
          state: "active",
          credential_kind: "host_auth"
        },
        running_count
      )

    [host_account | accounts]
  end

  defp project_usage_payload(running, retrying, settings) do
    issue_entries =
      Enum.map(running, &Map.put(&1, :status, :running)) ++
        Enum.map(retrying, &Map.put(&1, :status, :retrying))

    issue_groups = Enum.group_by(issue_entries, &project_group_key/1)

    settings
    |> Config.linear_project_routes()
    |> Enum.map(&configured_project_payload/1)
    |> Kernel.++(Enum.map(issue_groups, fn {key, entries} -> issue_project_payload(key, entries) end))
    |> Enum.uniq_by(&project_key/1)
    |> Enum.map(fn project -> project_usage_entry(project, Map.get(issue_groups, project_key(project), [])) end)
    |> Enum.sort_by(fn project -> {not project.configured?, String.downcase(project.name || project.slug || "")} end)
  end

  defp configured_project_payload(route) do
    slug = Map.get(route, :slug)

    %{
      slug: slug,
      name: project_name_from_slug(slug),
      repo: Map.get(route, :repo),
      workflow: Map.get(route, :workflow),
      backend: Map.get(route, :backend),
      default_branch: Map.get(route, :default_branch),
      workspace_root: Map.get(route, :workspace_root),
      configured?: true
    }
  end

  defp issue_project_payload("__unassigned__", _entries) do
    %{
      slug: nil,
      name: "Unassigned",
      repo: nil,
      workflow: nil,
      backend: nil,
      default_branch: nil,
      workspace_root: nil,
      configured?: false
    }
  end

  defp issue_project_payload(slug, entries) do
    sample = List.first(entries) || %{}

    %{
      slug: slug,
      name: Map.get(sample, :project_name) || project_name_from_slug(slug),
      repo: nil,
      workflow: nil,
      backend: nil,
      default_branch: nil,
      workspace_root: nil,
      configured?: false
    }
  end

  defp project_usage_entry(project, issues) do
    %{
      project
      | backend: project.backend || dominant_issue_value(issues, :backend),
        workspace_root: project.workspace_root || dominant_issue_value(issues, :workspace_path)
    }
    |> Map.merge(%{
      issue_count: length(issues),
      running_count: Enum.count(issues, &(Map.get(&1, :status) == :running)),
      retrying_count: Enum.count(issues, &(Map.get(&1, :status) == :retrying)),
      total_tokens: Enum.reduce(issues, 0, &(&2 + token_total_from_entry(&1))),
      issues: Enum.map(issues, &project_issue_ref/1)
    })
  end

  defp project_issue_ref(entry) do
    %{
      issue_identifier: Map.get(entry, :issue_identifier),
      issue_title: Map.get(entry, :issue_title),
      issue_url: Map.get(entry, :issue_url),
      state: Map.get(entry, :state) || to_string(Map.get(entry, :status)),
      status: Map.get(entry, :status),
      backend: Map.get(entry, :backend),
      effort: Map.get(entry, :effort),
      account_id: Map.get(entry, :account_id),
      progress: Map.get(entry, :progress)
    }
  end

  defp project_group_key(%{project_slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp project_group_key(_entry), do: "__unassigned__"

  defp project_key(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp project_key(_project), do: "__unassigned__"

  defp project_name_from_slug(slug) when is_binary(slug) and slug != "" do
    slug
    |> String.replace(["-", "_"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp project_name_from_slug(_slug), do: "Unassigned"

  defp dominant_issue_value([], _key), do: nil

  defp dominant_issue_value(issues, key) do
    issues
    |> Enum.map(&Map.get(&1, key))
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp telemetry_payload(settings) do
    telemetry = settings.telemetry

    %{
      enabled: telemetry.enabled,
      otlp_endpoint: telemetry.otlp_endpoint,
      otlp_protocol: telemetry.otlp_protocol,
      otlp_traces_endpoint: telemetry.otlp_traces_endpoint,
      otlp_traces_protocol: telemetry.otlp_traces_protocol,
      otlp_logs_endpoint: telemetry.otlp_logs_endpoint,
      otlp_logs_protocol: telemetry.otlp_logs_protocol,
      otlp_metrics_endpoint: telemetry.otlp_metrics_endpoint,
      otlp_metrics_protocol: telemetry.otlp_metrics_protocol,
      include_traces: telemetry.include_traces,
      include_metrics: telemetry.include_metrics,
      include_logs: telemetry.include_logs
    }
  end

  defp capacity_payload(settings) do
    %{
      max_concurrent_agents: settings.agent.max_concurrent_agents,
      max_concurrent_sessions_per_account: settings.accounts.max_concurrent_sessions_per_account,
      accounts_enabled: settings.accounts.enabled,
      active_states: settings.tracker.active_states,
      terminal_states: settings.tracker.terminal_states
    }
  end

  defp progress_payload(state, status) do
    %{
      label: progress_label(state, status),
      percent: progress_percent(state, status),
      tone: progress_tone(state, status)
    }
  end

  defp progress_label(_state, :retrying), do: "Backoff"

  defp progress_label(state, _status) when is_binary(state) and state != "", do: state
  defp progress_label(_state, _status), do: "Running"

  defp progress_percent(_state, :retrying), do: 38

  defp progress_percent(state, _status) do
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["done", "closed", "cancel", "duplicate"]) -> 100
      String.contains?(normalized, ["merging", "merge"]) -> 88
      String.contains?(normalized, ["review"]) -> 74
      String.contains?(normalized, ["progress", "running", "active"]) -> 58
      String.contains?(normalized, ["blocked", "error", "failed"]) -> 28
      String.contains?(normalized, ["todo", "queued", "pending"]) -> 18
      true -> 44
    end
  end

  defp progress_tone(_state, :retrying), do: "warning"

  defp progress_tone(state, _status) do
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["done", "closed"]) -> "complete"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "warning"
      true -> "active"
    end
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_agent_timestamp),
        event: running.last_agent_event,
        message: summarize_message(running.last_agent_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_agent_message(message)

  defp issue_title_from_entries(running, retry),
    do: (running && Map.get(running, :issue_title)) || (retry && Map.get(retry, :issue_title))

  defp issue_url_from_entries(running, retry),
    do: (running && Map.get(running, :issue_url)) || (retry && Map.get(retry, :issue_url))

  defp project_from_entries(running, retry) do
    project_from_entry(running) || project_from_entry(retry)
  end

  defp project_from_entry(nil), do: nil

  defp project_from_entry(entry) do
    %{
      id: Map.get(entry, :project_id),
      slug: Map.get(entry, :project_slug),
      name: Map.get(entry, :project_name) || project_name_from_slug(Map.get(entry, :project_slug))
    }
  end

  defp token_total_from_entry(%{tokens: %{total_tokens: total}}), do: integer_value(total)
  defp token_total_from_entry(_entry), do: 0

  defp token_period_total(token_totals, key) do
    token_totals
    |> map_value(key)
    |> case do
      %{} = period -> integer_value(map_value(period, :total_tokens))
      _ -> 0
    end
  end

  defp rate_limit_bucket_payloads(rate_limits) when is_map(rate_limits) do
    [
      {"session", map_value(rate_limits, :session) || map_value(rate_limits, :primary)},
      {"weekly", map_value(rate_limits, :weekly) || map_value(rate_limits, :secondary)}
    ]
    |> Enum.filter(fn {_name, bucket} -> is_map(bucket) end)
    |> Enum.map(fn {name, bucket} -> rate_limit_bucket_payload(name, bucket) end)
  end

  defp rate_limit_bucket_payloads(_rate_limits), do: []

  defp rate_limit_bucket_payload(name, bucket) do
    limit = integer_or_nil(map_value(bucket, :limit))
    remaining = integer_or_nil(map_value(bucket, :remaining))
    used = used_limit(limit, remaining)

    %{
      bucket: name,
      limit: limit,
      remaining: remaining,
      used: used,
      usage_percent: percent_of(used, limit),
      reset_at: map_value(bucket, :reset_at) || map_value(bucket, :resetAt),
      reset_in_seconds: integer_or_nil(map_value(bucket, :reset_in_seconds) || map_value(bucket, :reset_after_seconds))
    }
  end

  defp used_limit(limit, remaining) when is_integer(limit) and is_integer(remaining), do: max(0, limit - remaining)
  defp used_limit(_limit, _remaining), do: 0

  defp percent_of(_value, nil), do: nil
  defp percent_of(_value, limit) when limit <= 0, do: nil
  defp percent_of(value, limit), do: Float.round(value * 100 / limit, 1)

  defp positive_integer(value) do
    case integer_or_nil(value) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp integer_value(value), do: integer_or_nil(value) || 0

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(value) when is_float(value), do: round(value)

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp map_value(nil, _key), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
