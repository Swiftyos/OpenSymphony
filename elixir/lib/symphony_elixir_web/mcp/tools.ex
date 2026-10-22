defmodule SymphonyElixirWeb.Mcp.Tools do
  @moduledoc """
  The tools Symphony offers over MCP: watching the factory, and changing it the
  way a person can from the dashboard.

  Every call runs as the token's account with that account's permissions
  (`SymphonyElixir.Auth`), trimmed the same way as the dashboard
  (`SymphonyElixirWeb.Visibility`). Flow and stage changes also need
  `server.controls`.

  `call/3` returns `{:ok, result}` for the tool's structured result or
  `{:error, message}` for a tool-level failure (bad input, not allowed), which
  the protocol layer reports as an `isError` result.
  """

  require Logger

  alias SymphonyElixir.{
    AgentInbox,
    Auth,
    Config,
    FactoryControls,
    IssueMoves,
    LabelSync,
    Orchestrator,
    ProjectRoutes,
    Transcript,
    UsageLedger
  }

  alias SymphonyElixir.Factory.Store
  alias SymphonyElixirWeb.{Endpoint, FactoryPresenter, ObservabilityPubSub, Presenter, Visibility}
  alias SymphonyElixirWeb.Mcp.Manual

  @type context :: %{user: Auth.User.t(), actor: String.t(), via: String.t()}

  @max_transcript 200
  @control_fields ["paused", "max_agents", "backend", "effort", "approval"]

  @tools [
    %{
      name: "get_manual",
      scope: "read",
      description:
        "Symphony's manual: what Symphony is, its concepts, how to set up a new project, how Symphony picks the repo an issue is worked in, working across repos (blocking issues, unblocking), an issue's life, what agents are told and where that is configured, where people step in, tokens, every tool here, recipes and troubleshooting. Call it first when asked what this is or how it works.",
      properties: %{
        section: %{
          type: "string",
          enum: Manual.sections(),
          description: "One section only; leave out for the whole manual."
        }
      },
      required: []
    },
    %{
      name: "symphony_status",
      scope: "read",
      description: "Overview of the factory: agents running and retrying (issue, stage, harness, turns, tokens, latest event), capacity, polling, rate limits, and whether a restart is pending.",
      properties: %{},
      required: []
    },
    %{
      name: "list_flows",
      scope: "read",
      description: "The factory flows you can see (the default flow, teams, and Linear projects), which flow each one uses, its version, and whether you may edit it.",
      properties: %{},
      required: []
    },
    %{
      name: "get_flow",
      scope: "read",
      description:
        "A flow's full definition (stages with their Linear state, label, agent instructions, harness, controls; transitions; autopilot) plus the issues in each stage. Pass `version` back to save_flow when you change it (0 for a team or project that still inherits its flow: saving gives it its own).",
      properties: %{scope: %{type: "string", description: "DEFAULT, a team key such as PAY, or project:<slug>."}},
      required: ["scope"]
    },
    %{
      name: "list_issues",
      scope: "read",
      description: "Issues Symphony is tracking that you can see, with their stage, flow, and whether they are waiting for approval.",
      properties: %{
        scope: %{type: "string", description: "Only issues on this flow (team key or project:<slug>)."},
        stage: %{type: "string", description: "Only issues in this stage id."},
        awaiting_approval: %{type: "boolean", description: "Only issues held for a person's approval."}
      },
      required: []
    },
    %{
      name: "get_issue",
      scope: "read",
      description: "One issue: its live agent session or retry (if any), stage, move history, and messages to its agent.",
      properties: %{identifier: %{type: "string", description: "Issue identifier, e.g. PAY-12."}},
      required: ["identifier"]
    },
    %{
      name: "get_transcript",
      scope: "read",
      description: "The newest entries of an issue's agent transcript: agent messages, thinking, commands with output, edits, tool calls, turns.",
      properties: %{
        identifier: %{type: "string", description: "Issue identifier, e.g. PAY-12."},
        limit: %{type: "integer", minimum: 1, maximum: @max_transcript, description: "How many of the newest entries (default 50)."}
      },
      required: ["identifier"]
    },
    %{
      name: "save_flow",
      scope: "write",
      destructive: true,
      description:
        "Replace a flow's definition (as returned by get_flow, edited). `base_version` must be the version you read; if someone saved since, nothing is written and the current definition is returned so you can redo your change.",
      properties: %{
        scope: %{type: "string", description: "DEFAULT, a team key, or project:<slug>."},
        base_version: %{type: "integer", description: "The `version` from get_flow."},
        definition: %{type: "object", description: "The whole definition: `stages` and `transitions` (and optionally `autopilot`)."}
      },
      required: ["scope", "base_version", "definition"]
    },
    %{
      name: "set_stage_control",
      scope: "write",
      description:
        "Change one runtime control on an agent stage: paused (boolean), max_agents (integer or null), backend (codex, claude, opencode or null), effort (thinking level or null), approval (boolean: hold the agent's moves for a person).",
      properties: %{
        scope: %{type: "string", description: "DEFAULT, a team key, or project:<slug>."},
        stage: %{type: "string", description: "Stage id."},
        field: %{type: "string", enum: @control_fields},
        value: %{description: "The new value."}
      },
      required: ["scope", "stage", "field", "value"]
    },
    %{
      name: "set_autopilot",
      scope: "write",
      description: "Earned autonomy for a flow: when enabled, each agent stage needs approval until `streak` approvals in a row. Resets every stage's count.",
      properties: %{
        scope: %{type: "string"},
        enabled: %{type: "boolean"},
        streak: %{type: "integer", minimum: 1}
      },
      required: ["scope", "enabled", "streak"]
    },
    %{
      name: "reset_flow",
      scope: "write",
      destructive: true,
      description: "Delete a team's or project's own flow so it inherits again (a project its team's flow, a team the default flow).",
      properties: %{scope: %{type: "string"}},
      required: ["scope"]
    },
    %{
      name: "move_issue",
      scope: "write",
      description: "Move an issue to another stage of its flow. The move must be a connection in the flow; members can make the person-made connections, admins any.",
      properties: %{
        issue: %{type: "string", description: "Identifier (PAY-12) or Linear issue id."},
        to: %{type: "string", description: "Target stage id."}
      },
      required: ["issue", "to"]
    },
    %{
      name: "review_issue",
      scope: "write",
      description: "Decide on an issue held for approval: approve keeps the agent's move, send_back returns it to the stage it came from.",
      properties: %{
        issue: %{type: "string", description: "Identifier (PAY-12) or Linear issue id."},
        verdict: %{type: "string", enum: ["approve", "send_back"]}
      },
      required: ["issue", "verdict"]
    },
    %{
      name: "send_agent_message",
      scope: "write",
      description: "Send a message to the agent working on an issue: steered into a running Codex turn, otherwise put at the top of the next turn.",
      properties: %{
        identifier: %{type: "string", description: "Issue identifier, e.g. PAY-12."},
        text: %{type: "string", maxLength: 8000}
      },
      required: ["identifier", "text"]
    },
    %{
      name: "refresh",
      scope: "write",
      description: "Poll Linear and reconcile now instead of waiting for the next tick.",
      properties: %{},
      required: []
    },
    %{
      name: "list_projects",
      scope: "read",
      description:
        "The Linear projects Symphony listens to for issues, and the GitHub repo each one's issues are worked in. `source` is `config` (symphony.yml, change it there) or `mcp` (added with add_project).",
      properties: %{},
      required: []
    },
    %{
      name: "add_project",
      scope: "write",
      description:
        "Admins: make Symphony listen to a Linear project and work its issues in its GitHub repos, from the next poll. `repo` is the primary repo; `repos` are the others. Each issue is worked in exactly one repo: the one its repo/<name> label names, else the primary. Symphony creates the Linear labels. Issues follow the project's flow, else its team's; the repos need no Symphony files, but Symphony's GitHub access must be able to push and open PRs on every one. Adding an existing project replaces its settings, so pass the full repos list.",
      properties: %{
        project: %{type: "string", description: "The Linear project's URL or slug id (e.g. 0a1b2c3d4e5f)."},
        repo: %{type: "string", description: "GitHub repository as owner/name, e.g. acme/widgets."},
        workflow: %{type: "string", description: "Optional: a WORKFLOW.md in the repo whose prompt and agent settings replace Symphony's. Leave it out to use Symphony's."},
        default_branch: %{type: "string", description: "Branch PRs target (default main)."},
        backend: %{type: "string", enum: ["codex", "claude", "opencode"], description: "Default harness (stage settings and labels still win)."},
        repos: %{
          type: "array",
          description:
            "Other GitHub repos this project's issues may need work in (replaces the stored list). An issue labelled repo/<name> is worked in that repo; a label naming no repo of the project stops the issue with a comment. Agents read the other repos (checked out under .symphony/repos/<name>) and file a blocking issue for the repo that needs a change.",
          items: %{
            type: "object",
            properties: %{
              repo: %{type: "string", description: "GitHub repository as owner/name."},
              name: %{type: "string", description: "Short name for the repo/<name> label (default: the repo's name)."},
              default_branch: %{type: "string", description: "Branch PRs target (default main)."},
              description: %{type: "string", description: "What lives in this repo, so agents know when a problem belongs there."}
            },
            required: ["repo"]
          }
        },
        environment: %{type: "string", description: "Platform catalog environment for this project's runs (stage and team defaults still win)."}
      },
      required: ["project", "repo"]
    },
    %{
      name: "remove_project",
      scope: "write",
      destructive: true,
      description: "Admins: stop listening to a Linear project added with add_project. Issues already running finish; no new ones start. Projects from symphony.yml can't be removed here.",
      properties: %{project: %{type: "string", description: "The Linear project's URL or slug id."}},
      required: ["project"]
    }
  ]

  @tool_names MapSet.new(@tools, & &1.name)

  @doc """
  Tool descriptors for `tools/list`. Every token gets all of them; its
  account's permissions decide what each call may do.
  """
  @spec list() :: [map()]
  def list do
    Enum.map(@tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        inputSchema: %{type: "object", properties: tool.properties, required: tool.required, additionalProperties: false},
        annotations: %{
          readOnlyHint: tool.scope == "read",
          destructiveHint: Map.get(tool, :destructive, false),
          openWorldHint: false
        }
      }
    end)
  end

  @spec known?(String.t()) :: boolean()
  def known?(name), do: MapSet.member?(@tool_names, name)

  @spec call(String.t(), map(), context()) :: {:ok, map()} | {:error, String.t()}
  def call(name, args, ctx) when is_map(args) do
    tool = Enum.find(@tools, &(&1.name == name))

    result = if is_nil(tool), do: {:error, "Unknown tool #{name}."}, else: run(name, args, ctx)

    Logger.info(
      "MCP tool call tool=#{name} user=#{ctx.user.username || ctx.user.id} via=#{inspect(ctx.via)} " <>
        "outcome=#{if match?({:ok, _}, result), do: "ok", else: "error"}"
    )

    result
  end

  # Read tools.

  defp run("get_manual", args, _ctx) do
    case args["section"] do
      nil ->
        {:ok, %{manual: Manual.text(), sections: Manual.sections()}}

      section ->
        case Manual.section(to_string(section)) do
          {:ok, text} -> {:ok, %{section: section, manual: text}}
          :error -> {:error, "No such section. Sections: #{Enum.join(Manual.sections(), ", ")}."}
        end
    end
  end

  defp run("symphony_status", _args, ctx) do
    with {:ok, payload} <- state(ctx) do
      {:ok,
       payload
       |> Map.take([:generated_at, :counts, :running, :retrying, :capacity, :polling, :rate_limits, :delayed_restart, :agent_totals])
       |> Map.update(:running, [], fn entries -> Enum.map(entries, &session_summary/1) end)
       |> Map.update(:retrying, [], fn entries -> Enum.map(entries, &session_summary/1) end)}
    end
  end

  defp run("list_flows", _args, ctx) do
    with {:ok, %{factory: factory}} <- state(ctx) do
      flows =
        Enum.map(factory.teams, fn entry ->
          definition = factory.definitions[entry.key] || %{}

          entry
          |> Map.take([:key, :kind, :name, :slug, :teams, :custom])
          |> Map.merge(%{
            uses: definition["source"],
            version: if(definition["inherited"], do: 0, else: definition["version"]),
            stages: Enum.map(definition["stages"] || [], & &1["id"]),
            editable: controls_enabled?() and Auth.can_edit_factory?(ctx.user, entry.key)
          })
        end)

      {:ok, %{flows: flows, controls_enabled: controls_enabled?()}}
    end
  end

  defp run("get_flow", args, ctx) do
    with {:ok, scope} <- string_arg(args, "scope"),
         {:ok, %{factory: factory}} <- state(ctx),
         true <- readable_scope?(ctx.user, factory, scope) || {:error, "No flow #{scope} that you can see."} do
      key = normalize_scope(scope)
      definition = factory.definitions[key] || Store.get(scope)
      flow = factory.flows[key] || %{nodes: %{}, edges: %{}}

      {:ok,
       %{
         scope: definition["team"],
         uses: definition["source"],
         inherited: definition["inherited"],
         # An inherited flow isn't this scope's yet: its first save is on top of 0.
         version: if(definition["inherited"], do: 0, else: definition["version"]),
         definition: Map.drop(definition, ["team", "source", "inherited"]),
         issues_by_stage: Map.new(flow.nodes, fn {stage, node} -> {stage, Enum.map(node.issues, &issue_summary/1)} end),
         transitions_observed: flow.edges,
         editable: controls_enabled?() and Auth.can_edit_factory?(ctx.user, definition["team"])
       }}
    end
  end

  defp run("list_issues", args, ctx) do
    with {:ok, %{factory: factory}} <- state(ctx) do
      scope = args["scope"]
      stage = args["stage"]

      issues =
        for {key, flow} <- factory.flows,
            is_nil(scope) or (is_binary(scope) and key == normalize_scope(scope)),
            {stage_id, node} <- flow.nodes,
            is_nil(stage) or stage_id == stage,
            issue <- node.issues,
            args["awaiting_approval"] != true or issue.awaiting do
          issue |> issue_summary() |> Map.merge(%{flow: key, stage: stage_id})
        end

      {:ok, %{issues: Enum.sort_by(issues, & &1.identifier), count: length(issues)}}
    end
  end

  defp run("get_issue", args, ctx) do
    with {:ok, identifier} <- identifier_arg(args),
         :ok <- visible(ctx.user, identifier) do
      # Visible through a project grant only: no session details (they may
      # name hosts and accounts of the issue's team).
      session =
        with {:ok, payload} <- Presenter.issue_payload(identifier, orchestrator(), snapshot_timeout_ms()),
             {:ok, visible} <- Visibility.filter_issue(payload, ctx.user, identifier) do
          visible
        else
          _ -> nil
        end

      ledger = Enum.find(UsageLedger.snapshot().flow.issues, &(&1.issue == identifier))

      {:ok,
       ledger
       |> ledger_summary()
       |> Map.merge(%{
         identifier: identifier,
         session: session,
         messages: identifier |> AgentInbox.messages() |> Enum.map(&message_summary/1)
       })}
    end
  end

  defp run("get_transcript", args, ctx) do
    with {:ok, identifier} <- identifier_arg(args),
         :ok <- visible(ctx.user, identifier),
         {:ok, limit} <- limit_arg(args) do
      entries = Transcript.entries(identifier)
      {:ok, %{identifier: identifier, total: length(entries), entries: Enum.take(entries, -limit)}}
    end
  end

  # Write tools.

  defp run("save_flow", args, ctx) do
    with {:ok, scope} <- string_arg(args, "scope"),
         {:ok, version} <- integer_arg(args, "base_version"),
         {:ok, definition} <- map_arg(args, "definition"),
         :ok <- can_edit(ctx.user, scope) do
      case Store.put(scope, definition, version, ctx.actor) do
        {:ok, saved} ->
          IssueMoves.sync_stage_labels(saved["team"], saved)
          ObservabilityPubSub.broadcast_update()
          {:ok, %{saved: true, version: saved["version"], definition: saved}}

        {:error, {:conflict, current}} ->
          {:error, "Someone saved this flow since version #{version}; it is now version #{current["version"]}. " <> "Re-read it with get_flow and apply your change again."}

        {:error, [_ | _] = errors} ->
          {:error, "The definition isn't valid: " <> Enum.join(errors, "; ")}

        {:error, reason} ->
          {:error, IssueMoves.describe_error(reason)}
      end
    end
  end

  defp run("set_stage_control", args, ctx) do
    with {:ok, scope} <- string_arg(args, "scope"),
         {:ok, stage} <- string_arg(args, "stage"),
         {:ok, field} <- string_arg(args, "field"),
         true <- field in @control_fields || {:error, "field must be one of #{Enum.join(@control_fields, ", ")}."},
         true <- Map.has_key?(args, "value") || {:error, "value is required (use null to clear)."},
         :ok <- can_edit(ctx.user, scope) do
      case FactoryControls.put({scope, stage}, field, args["value"], ctx.actor) do
        {:ok, controls} ->
          ObservabilityPubSub.broadcast_update()
          {:ok, %{scope: scope, stage: stage, controls: controls}}

        {:error, {:invalid_control, _field, _value, message}} ->
          {:error, "Invalid #{field}: #{message}"}

        {:error, reason} ->
          {:error, IssueMoves.describe_error(reason)}
      end
    end
  end

  defp run("set_autopilot", args, ctx) do
    with {:ok, scope} <- string_arg(args, "scope"),
         true <- is_boolean(args["enabled"]) || {:error, "enabled must be true or false."},
         {:ok, streak} <- integer_arg(args, "streak"),
         :ok <- can_edit(ctx.user, scope) do
      case Store.put_autopilot(scope, args["enabled"], streak, ctx.actor) do
        {:ok, saved} ->
          ObservabilityPubSub.broadcast_update()
          {:ok, %{scope: saved["team"], version: saved["version"], autopilot: saved["autopilot"]}}

        {:error, [message | _]} ->
          {:error, message}

        {:error, reason} ->
          {:error, IssueMoves.describe_error(reason)}
      end
    end
  end

  defp run("reset_flow", args, ctx) do
    with {:ok, scope} <- string_arg(args, "scope"),
         :ok <- can_edit(ctx.user, scope) do
      case Store.reset_team(scope) do
        :ok ->
          ObservabilityPubSub.broadcast_update()
          {:ok, %{scope: scope, reset: true, now_uses: Store.get(scope)["source"]}}

        {:error, reason} ->
          {:error, IssueMoves.describe_error(reason)}
      end
    end
  end

  defp run("move_issue", args, ctx) do
    with {:ok, issue} <- string_arg(args, "issue"),
         {:ok, to} <- string_arg(args, "to"),
         :ok <- controls_on() do
      case IssueMoves.move(ctx.user, issue, to, actor: ctx.actor, via: ctx.via) do
        :ok -> {:ok, %{moved: true, issue: issue, to: to}}
        {:error, reason} -> {:error, IssueMoves.describe_error(reason)}
      end
    end
  end

  defp run("review_issue", args, ctx) do
    with {:ok, issue} <- string_arg(args, "issue"),
         {:ok, verdict} <- verdict_arg(args),
         :ok <- controls_on() do
      case IssueMoves.review(ctx.user, issue, verdict, actor: ctx.actor, via: ctx.via) do
        :ok -> {:ok, %{reviewed: true, issue: issue, verdict: args["verdict"]}}
        {:error, reason} -> {:error, IssueMoves.describe_error(reason)}
      end
    end
  end

  defp run("send_agent_message", args, ctx) do
    with {:ok, identifier} <- identifier_arg(args),
         :ok <- visible(ctx.user, identifier),
         true <- can_message?(ctx.user, identifier) || {:error, "You can't message the agent on this issue."},
         {:ok, text} <- string_arg(args, "text") do
      case AgentInbox.send_message(identifier, text, ctx.actor) do
        {:ok, message} -> {:ok, %{sent: true, message: message_summary(message)}}
        {:error, :message_too_long} -> {:error, "The message is longer than 8000 characters."}
        {:error, _reason} -> {:error, "Messaging is unavailable right now."}
      end
    end
  end

  defp run("list_projects", _args, _ctx) do
    file_slugs = Config.settings!().tracker.projects |> List.wrap() |> MapSet.new(& &1.slug)
    stored = ProjectRoutes.list()
    stored_slugs = MapSet.new(stored, & &1.slug)
    # Stored routes are live in multi-project mode unless symphony.yml has the same project.
    live? = Config.startup_mode() == :global

    from_config =
      Config.linear_project_routes()
      |> Enum.reject(&(MapSet.member?(stored_slugs, &1.slug) and not MapSet.member?(file_slugs, &1.slug)))
      # Legacy single-project routes are plain maps without every key.
      |> Enum.map(&(&1 |> Map.take([:repo, :workflow, :default_branch, :backend, :environment]) |> Map.merge(%{project: &1.slug, repos: extra_repos(&1), source: "config", active: true})))

    from_mcp =
      Enum.map(stored, fn route ->
        route
        |> Map.take([:repo, :workflow, :default_branch, :backend, :repos, :environment, :added_by, :added_at])
        |> Map.merge(%{project: route.slug, source: "mcp", active: live? and not MapSet.member?(file_slugs, route.slug)})
      end)

    {:ok, %{projects: from_config ++ from_mcp}}
  end

  defp run("add_project", args, ctx) do
    with :ok <- admin_controls(ctx.user),
         {:ok, slug} <- project_arg(args),
         :ok <- not_in_config(slug),
         {:ok, route} <- ProjectRoutes.put(Map.put(args, "slug", slug), ctx.actor) do
      # The project's name (for the dashboard) and its teams' labels come from Linear.
      if Config.settings!().tracker.kind == "linear",
        do: Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn -> LabelSync.sync_projects([route.slug]) end)

      Orchestrator.request_refresh_async()
      ObservabilityPubSub.broadcast_update()

      {:ok,
       %{
         added: Map.take(route, [:slug, :repo, :workflow, :default_branch, :backend, :repos, :environment]),
         note:
           "Symphony polls this project from now on. Before filing issues: " <>
             if(route.workflow, do: "#{route.repo} needs #{route.workflow} on #{route.default_branch}, and ", else: "") <>
             "Symphony's GitHub access needs push and pull-request rights on #{Enum.join([route.repo | Enum.map(route.repos, & &1.repo)], ", ")}." <>
             repo_label_note(route)
       }}
    end
  end

  defp run("remove_project", args, ctx) do
    with :ok <- admin_controls(ctx.user),
         {:ok, slug} <- project_arg(args),
         :ok <- not_in_config(slug) do
      case ProjectRoutes.delete(slug) do
        :ok ->
          ObservabilityPubSub.broadcast_update()
          {:ok, %{removed: slug}}

        {:error, :not_found} ->
          {:error, "Symphony isn't listening to a project #{slug} added through MCP."}
      end
    end
  end

  defp run("refresh", _args, _ctx) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} -> {:ok, payload}
      {:error, :unavailable} -> {:error, "The orchestrator is unavailable."}
    end
  end

  # Helpers.

  # Adding a project lets agents work in a new repo, so it's for admins only.
  defp admin_controls(user) do
    with :ok <- controls_on() do
      if Auth.can_control?(user), do: :ok, else: {:error, "Only admins can change which projects Symphony listens to."}
    end
  end

  # A Linear project URL ends in its slug id: .../project/<name>-<slug id>.
  defp project_arg(args) do
    with {:ok, value} <- string_arg(args, "project") do
      slug = value |> String.trim_trailing("/") |> String.split("/") |> List.last() |> String.split("-") |> List.last()
      if Regex.match?(~r/^[a-z0-9]{6,32}$/i, slug), do: {:ok, String.downcase(slug)}, else: {:error, "project must be a Linear project URL or its slug id."}
    end
  end

  defp not_in_config(slug) do
    from_file = Config.settings!().tracker.projects |> List.wrap() |> Enum.any?(&(&1.slug == slug))
    if from_file, do: {:error, "Project #{slug} is set in symphony.yml; change it there."}, else: :ok
  end

  defp state(ctx) do
    case Presenter.state_payload(orchestrator(), snapshot_timeout_ms(), teams: Enum.map(ctx.user.teams, & &1.key)) do
      %{error: %{message: message}} -> {:error, "Symphony's state isn't available: #{message}"}
      payload -> {:ok, Visibility.filter_payload(payload, ctx.user)}
    end
  end

  defp session_summary(entry) do
    Map.take(entry, [
      :issue_identifier,
      :issue_title,
      :issue_url,
      :state,
      :project_slug,
      :backend,
      :model,
      :effort,
      :turn_count,
      :last_event,
      :last_message,
      :started_at,
      :last_event_at,
      :tokens,
      :attempt,
      :due_at,
      :error
    ])
  end

  defp issue_summary(issue) do
    %{
      identifier: issue.issue,
      id: issue.id,
      title: issue.title,
      url: issue.url,
      project: issue.project,
      team: issue.team,
      agent: issue.backend,
      awaiting_approval: issue.awaiting,
      from: issue.from,
      to: issue[:to],
      knockbacks: issue[:knockbacks]
    }
  end

  # Where Symphony last saw the issue in its flow; empty when it hasn't.
  defp ledger_summary(nil), do: %{stage: nil, previous_stage: nil, awaiting_approval: false, moves: []}

  defp ledger_summary(ledger) do
    %{
      stage: ledger.node,
      previous_stage: ledger.from,
      awaiting_approval: ledger.awaiting_approval,
      title: ledger.title,
      url: ledger.url,
      project: ledger.project,
      moves: Enum.map(ledger.moves, &move_summary/1)
    }
  end

  # `by: "external"`: made outside the factory (in Linear, or by an integration).
  defp move_summary([from, to, at]), do: %{from: from, to: to, at_ms: at}
  defp move_summary([from, to, at, by]), do: %{from: from, to: to, at_ms: at, by: by}

  defp message_summary(message), do: Map.take(message, [:id, :author, :text, :at, :status, :delivered_at, :delivery])

  # Anyone may read a flow listed for them, and editors any flow they may edit.
  defp readable_scope?(user, factory, scope) do
    key = normalize_scope(scope)
    Enum.any?(factory.teams, &(&1.key == key)) or Auth.can_edit_factory?(user, key)
  end

  defp normalize_scope("project:" <> slug), do: "project:" <> String.trim(slug)
  defp normalize_scope(scope), do: scope |> String.trim() |> String.upcase()

  defp can_edit(user, scope) do
    with :ok <- controls_on() do
      if Auth.can_edit_factory?(user, normalize_scope(scope)),
        do: :ok,
        else: {:error, IssueMoves.describe_error(:not_team_editor)}
    end
  end

  defp controls_on, do: if(controls_enabled?(), do: :ok, else: {:error, IssueMoves.describe_error(:controls_disabled)})

  defp controls_enabled?, do: FactoryPresenter.controls_enabled?(Config.settings!())

  # An issue is visible by its team (as on the dashboard) or, for project
  # grants such as project-limited tokens, by the project Symphony saw it in.
  defp visible(user, identifier) do
    if Visibility.filter_issue(%{}, user, identifier) != :hidden or in_granted_project?(user, identifier),
      do: :ok,
      else: {:error, "Issue #{identifier} not found."}
  end

  defp can_message?(user, identifier), do: Auth.can_message_agent?(user, identifier) or in_granted_project?(user, identifier)

  defp in_granted_project?(user, identifier) do
    case Enum.find(UsageLedger.snapshot().flow.issues, &(&1.issue == identifier)) do
      %{project: project} when is_binary(project) -> project in Auth.movable_projects(user)
      _ -> false
    end
  end

  defp string_arg(args, key) do
    case args[key] do
      value when is_binary(value) -> if String.trim(value) == "", do: {:error, "#{key} is required."}, else: {:ok, String.trim(value)}
      nil -> {:error, "#{key} is required."}
      _value -> {:error, "#{key} must be a string."}
    end
  end

  defp identifier_arg(args) do
    with {:ok, identifier} <- string_arg(args, "identifier") do
      if Regex.match?(~r/^[A-Za-z0-9]+-\d+$/, identifier), do: {:ok, String.upcase(identifier)}, else: {:error, "identifier must look like PAY-12."}
    end
  end

  defp integer_arg(args, key) do
    case args[key] do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, "#{key} must be an integer."}
    end
  end

  defp map_arg(args, key) do
    case args[key] do
      value when is_map(value) -> {:ok, value}
      _value -> {:error, "#{key} must be an object."}
    end
  end

  defp limit_arg(args) do
    case Map.get(args, "limit", 50) do
      limit when is_integer(limit) and limit >= 1 -> {:ok, min(limit, @max_transcript)}
      _limit -> {:error, "limit must be a positive integer."}
    end
  end

  defp verdict_arg(%{"verdict" => "approve"}), do: {:ok, :approved}
  defp verdict_arg(%{"verdict" => "send_back"}), do: {:ok, :sent_back}
  defp verdict_arg(_args), do: {:error, "verdict must be approve or send_back."}

  defp orchestrator, do: Endpoint.config(:orchestrator) || Orchestrator

  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000

  defp repo_label_note(%{repos: [_ | _] = repos} = route) do
    " Issues are worked in #{route.repo} unless labelled " <> Enum.map_join(repos, " or ", &"repo/#{&1.name} (#{&1.repo})") <> "."
  end

  defp repo_label_note(_route), do: ""

  defp extra_repos(route) do
    for repo <- Config.project_repos(route), not repo.primary, do: Map.take(repo, [:name, :repo, :default_branch, :description])
  end
end
