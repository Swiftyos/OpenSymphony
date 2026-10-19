# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches the configured unattended agent backend inside the workspace
4. Sends a workflow prompt to that backend
5. Keeps the backend working on the issue until the work is done

Supported backends today are Codex, OpenCode, and Claude Code.

During unattended agent sessions, Symphony also bootstraps a workspace-local Linear integration so
that repo skills can make raw Linear GraphQL calls without storing secrets in the repo. OpenCode
gets a generated custom tool, and Claude Code gets a generated workspace-local MCP server.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## Features

- Multi-backend orchestration with Codex, OpenCode, and Claude Code.
- Multi-project routing from one Symphony instance to multiple repos and repo-local `WORKFLOW.md`
  files.
- Per-project backend defaults in `symphony.yml`.
- Per-ticket backend switching through Linear labels like `codex`, `claude`, and `opencode`.
- Per-ticket thinking/effort switching through Linear labels like `thinking/high` and
  `thinking/max`.
- Repo-local workflow prompts and hooks, with global runtime settings kept in `symphony.yml`.
- Workspace-local Linear tooling so agents can comment on issues and run GraphQL operations without
  committing secrets into the repo.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `symphony.yml` somewhere outside your repo or into an ops/config repo.
4. Copy this directory's `WORKFLOW.md` into each repo Symphony should operate on.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize `symphony.yml` with your Linear, backend, and project-routing config.
6. Customize each copied repo-local `WORKFLOW.md` with that repo's hooks, prompt, and local agent
   overrides.
   - To get a Linear project's slug, right-click the project and copy its URL. The slug is part of
     the URL.
   - Configure the exact Linear workflow states listed in the `Linear setup` section below.
7. Follow the instructions below to install the required runtime dependencies and start the service.
8. For a concrete two-project walkthrough, see [`SETUP.md`](./SETUP.md).

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./symphony.yml
```

## Configuration

Pass a custom config path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/symphony.yml
```

If no path is passed, Symphony defaults to `./symphony.yml`.

Passing a `WORKFLOW.md` path explicitly still works as a legacy single-project mode.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service and overrides `server.port`
  (default: disabled)

`symphony.yml` is the global runtime config. Repo-local `WORKFLOW.md` files contain YAML front
matter for project-local workflow settings plus a Markdown body used as the agent session prompt.

Minimal example:

```yaml
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
providers:
  openrouter_api_key: $OPENROUTER_API_KEY
workspace:
  root: ~/code/workspaces
instance:
  name: staging-west
server:
  port: 4000
agent:
  backend: codex
  default_effort: medium
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
claude:
  command: claude
  permission_mode: bypassPermissions
opencode:
  command: opencode serve --hostname 127.0.0.1 --port 0
  agent: build
projects:
  - linear_project: "project-a"
    repo: git@github.com:your-org/project-a.git
    workflow: /absolute/path/to/project-a/WORKFLOW.md
```

```md
---
hooks:
  after_create: |
    mise trust
    mise exec -- mix deps.get
agent:
  default_effort: medium
  max_turns: 20
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Multi-project routing example:

```yaml
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
workspace:
  root: ~/code/workspaces
agent:
  backend: codex
codex:
  command: codex app-server
claude:
  command: claude
  permission_mode: bypassPermissions
opencode:
  command: opencode serve --hostname 127.0.0.1 --port 0
  agent: build
projects:
  - linear_project: "project-a"
    repo: ./dev/project-a
    workflow: ./dev/project-a/WORKFLOW.md
    workspace_root: ./dev/project-a-workspaces
    backend: codex
  - linear_project: "project-b"
    repo: ./dev/project-b
    workflow: ./dev/project-b/WORKFLOW.md
    backend: claude
```

Provider switching example:

```text
Default config:
- agent.backend: codex
- projects["project-b"].backend: claude

Per-ticket behavior:
- no backend label on a project-b issue -> Claude Code
- label the same issue with `codex` -> Codex
- label the same issue with `opencode` -> OpenCode
```

Notes:

- If a value is missing, defaults are used.
- `projects` lets Symphony poll multiple Linear projects and route each issue by its
  `project.slugId`.
- `projects[].repo` is optional. When set, Symphony clones that repo into a brand-new workspace
  before running `hooks.after_create`.
- `projects[].workflow` is required in `symphony.yml` and must point at the repo-local
  `WORKFLOW.md` Symphony should use for that Linear project.
- `projects[].workspace_root` is optional. When omitted, Symphony uses
  `workspace.root/<project-slug>/<issue-identifier>` for multi-project workflows so different
  projects do not collide under the shared root.
- `projects[].backend` is optional. When omitted, Symphony falls back to `agent.backend`.
- In multi-project mode, repo-local `WORKFLOW.md` files may define `hooks.*`,
  `agent.default_effort`, `agent.max_turns`, and the prompt body only.
- `tracker.project_slug` remains the legacy single-project shorthand when you explicitly start
  Symphony with a `WORKFLOW.md` path.
- `agent.backend` accepts `codex`, `opencode`, or `claude`. If omitted, Symphony infers the
  backend from a single configured provider block; ambiguous or empty provider config falls back to
  `codex`.
- `agent.default_effort` accepts `low`, `medium`, `high`, or `max`. If unset, each backend uses its
  own default reasoning level.
- `opencode.command` defaults to `opencode serve --hostname 127.0.0.1 --port 0`.
- `opencode.agent` defaults to `build`.
- `opencode.model` is optional and must use `provider/model` format when set.
- `claude.command` defaults to `claude`.
- `claude.model` is optional.
- `claude.permission_mode` defaults to `bypassPermissions`.
- Claude Code supports both local runs and SSH workers. Each local or remote worker must already
  have working Claude credentials, and the first Claude bootstrap assumes `node` is available so
  Symphony can generate a workspace-local MCP server.
- Codex uses the public `max` effort setting and maps it to Codex's `xhigh` launcher setting.
- `agent.max_turns` caps how many back-to-back unattended turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- OpenCode v1 is local-only in Symphony. `worker.ssh_hosts` and
  `worker.max_concurrent_agents_per_host` are rejected during config validation.
- OpenCode stays local-only even when other backends use SSH workers. A ticket labeled `opencode`
  runs locally on the orchestrator host.
- OpenCode permissions are handled automatically for a limited unattended allowlist inside the
  issue workspace. Requests outside the workspace, `external_directory`, unknown permissions, and
  interactive questions are rejected.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use repo-local `hooks.after_create` to bootstrap a fresh workspace after Symphony clones the
  configured repo. You can also omit `projects[].repo` and do the clone inside `hooks.after_create`
  yourself if that fits your setup better.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- `providers.openrouter_api_key` reads from `OPENROUTER_API_KEY` when unset or when value is `$OPENROUTER_API_KEY`.
- `accounts.enabled` turns on managed Codex/Claude account rotation. Managed accounts live under
  `accounts.store_root` (default `~/.symphony/accounts`) and are selected per worker run with
  usage-aware round robin.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `opencode.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
providers:
  openrouter_api_key: $OPENROUTER_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
opencode:
  command: "$OPENCODE_BIN serve --hostname 127.0.0.1 --port 0"
  agent: build
  model: openai/gpt-5.3
projects:
  - linear_project: project-a
    workflow: $PROJECT_A_WORKFLOW
```

- If `symphony.yml` is missing or has invalid YAML at startup, Symphony does not boot.
- In multi-project mode, if a route's `WORKFLOW.md` is missing or invalid, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good config and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard, Prometheus
  metrics, and JSON API at `/`, `/metrics`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and
  `/api/v1/refresh`.

## Backend support

### Managed Accounts

When account rotation is enabled, add accounts one at a time from the same shell where the provider
CLI is available:

```bash
./bin/symphony accounts login codex personal --email you@example.com
claude
./bin/symphony accounts import claude work --email you@company.com
./bin/symphony accounts list
```

Codex accounts use an isolated `CODEX_HOME`. For Claude, the most reliable SSH flow is to sign in
or switch accounts with the Claude CLI directly, then import the active Claude auth/config into the
managed account with `accounts import claude <id>`. Repeat the direct Claude login plus import for
each account id. If your direct Claude CLI uses a non-default config directory, pass it explicitly:

```bash
./bin/symphony accounts import claude work --email you@company.com --from "$CLAUDE_CONFIG_DIR"
```

Claude `accounts login` is still available for token-based onboarding: it runs `setup-token` and
stores the emitted OAuth token for later injection via `CLAUDE_CODE_OAUTH_TOKEN`. If you already
have a token, avoid browser login with `--token-stdin`, `--token-file <path>`, or
`--token-env <VAR>`. If an account is already maxed out, pause it before starting Symphony:

```bash
./bin/symphony accounts pause codex personal --reason "daily quota exhausted"
./bin/symphony accounts resume codex personal
```

During dispatch, Symphony skips paused, disabled, cooling-down, rate-limited, over-budget, and
already-in-use accounts before rotating through the rest. If every account for a backend is
unavailable, the issue stays in retry/backoff until an account becomes usable.

Each account directory also gets `usage_periods.csv` when Codex or Claude reports a `session` or
`weekly` rate-limit reset. Rows include the reset transition, usage percentage, weekly percentage
where applicable, and local token totals accumulated during that provider period.

To feed the local Grafana `Account Usage` dashboard, run Symphony with `--port 4000` or
`--port 4001` (or set `server.port` to one of the ports scraped by vmagent). The observability
stack scrapes both ports by default so multiple Symphony instances on the same host can export
metrics side-by-side, each tagged with its own `instance_name` label. When the observability
stack runs in Docker, also set `server.host: 0.0.0.0` so `vmagent` can reach
`host.docker.internal:<port>/metrics`. Otherwise the quota and billing-cycle panels stay empty
even though the endpoint works from your local browser.

### Codex

- Supports unattended work through the Codex app server.
- Uses the public `low`, `medium`, `high`, and `max` effort settings; `max` maps to Codex's
  launcher-specific `xhigh` setting internally.

### Claude Code

- Supports local runs and SSH worker hosts.
- Boots a workspace-local MCP server so repo skills can talk to Linear safely during agent runs.
- Uses `claude.command`, optional `claude.model`, and `claude.permission_mode`.

### OpenCode

- Supports unattended work through `opencode serve`.
- Runs local-only in Symphony today, even if other backends use SSH workers.
- Gets a generated workspace-local Linear tool for issue comments and GraphQL operations.
- Uses `opencode.command`, `opencode.agent`, and optional `opencode.model`.

## Linear setup

Symphony works with Linear's default workflow states; no custom states are
required:

- `Backlog`, `Todo`, `In Progress`, `In Review`, `Done`, `Canceled`, `Duplicate`

Sub-stages within a state are carried by labels. Create a label group named
`factory` (team or workspace level) with these children:

| Label               | Used with     | Meaning                                       | Set by |
| ------------------- | ------------- | --------------------------------------------- | ------ |
| `factory/implement` | `In Progress` | Build, validate, open PR (also the default)   | agent  |
| `factory/rework`    | `In Progress` | Reviewer requested a full reset               | human  |
| `factory/merge`     | `In Progress` | Approved; agent lands the PR then marks Done  | human  |
| `factory/blocked`   | `In Progress` | Parked; Symphony will not dispatch it         | either |

The lifecycle is `Todo` -> `In Progress` (implement) -> `In Review` (human) ->
`In Progress` + `factory/merge` -> `Done`, with `factory/rework` as the loop back.
A Linear label group only allows one child per issue, so an issue is never in two
stages at once. Flat labels named `factory/<stage>` also work.

Relevant `tracker` settings (defaults shown):

```yaml
tracker:
  active_states: [Todo, In Progress]
  stage_label_prefix: factory # label group name
  paused_stages: [blocked, review] # stages that are never dispatched
```

When an issue's stage changes between turns (for example `rework` -> `implement`),
the running agent finishes its turn and Symphony re-dispatches it with a fresh
first-turn prompt. Workflow prompts can read `{{ issue.stage }}` and
`{{ factory.label_prefix }}`.

Default terminal states recognized by Symphony are:

- `Backlog`
- `Closed`
- `Cancelled`
- `Canceled`
- `Duplicate`
- `Done`

## Workspace isolation

Each issue gets its own standalone git clone, made from a shared per-repo cache
(objects are hardlinked, so clones are cheap). Clones share no refs, index locks,
or checked-out-branch state, so concurrent agents cannot block each other's
`git fetch`, `git checkout main`, or merges. If an issue's workspace is recreated
and its `symphony/<ISSUE>` branch already exists on the remote, the new clone
resumes that branch instead of resetting it. A workspace whose bootstrap or
`after_create` hook fails is deleted so the next attempt starts clean.

### Docker sandbox

Set `sandbox.kind: docker` to run each issue's hooks and agent process inside its
own container:

```yaml
sandbox:
  kind: docker
  image: symphony-agent:latest # must provide bash, git, gh, and codex/claude (+ node for Claude)
  env: [GH_TOKEN, ANTHROPIC_API_KEY, OPENAI_API_KEY] # passed through by name
  mounts: ["~/.gitconfig:/root/.gitconfig:ro"]
  # network: bridge
  # run_args: ["--cpus", "4", "--memory", "8g"]
```

The container is created on first use, bind-mounts the workspace and the managed
accounts store at their host paths, persists across runs for the same issue (so
installed dependencies and services survive), and is removed with the workspace.
Git bootstrap still runs on the host. OpenCode and SSH worker hosts are not yet
supported with the sandbox; Symphony refuses those runs with an explicit error.

## Label routing

Symphony lowercases Linear label names before matching, so label routing is case-insensitive even
though the documented labels below are shown in their exact lowercase form.

Built-in backend routing labels:

- `codex`
- `claude`
- `opencode`

Built-in thinking routing labels:

- `thinking/low`
- `thinking/medium`
- `thinking/high`
- `thinking/max`

Routing behavior:

- If exactly one backend label is present, Symphony uses that backend for the ticket.
- If no backend label is present, Symphony falls back to `agent.backend`.
- If multiple backend labels are present, Symphony logs a warning and falls back to `agent.backend`.
- If exactly one thinking label is present, Symphony uses that effort for the ticket.
- If no thinking label is present, Symphony falls back to `agent.default_effort`.
- If multiple thinking labels are present, Symphony logs a warning and falls back to
  `agent.default_effort` when set.
- Legacy `effort/*` labels are still accepted for compatibility.

Selection precedence:

- Backend precedence is `agent.backend`, then `projects[].backend`, then a backend label on the
  Linear issue.
- Effort precedence is global `agent.default_effort`, then repo-local `WORKFLOW.md`
  `agent.default_effort`, then a Linear thinking label.

Example:

- A `project-b` issue can default to Claude Code because `projects[].backend` is `claude`.
- Adding a `codex` label switches just that one ticket to Codex.
- Adding `thinking/max` keeps the same ticket on its chosen backend but increases reasoning effort.

## Web dashboard

Open `http://127.0.0.1:<server.port>/`. The page is laid out in the order an operator needs it.

![Dashboard overview](../.github/media/dashboard-overview.png)

- **Top bar**: live or offline, agents in use vs capacity, next poll.
- **Headline numbers**: spend, tokens in/out, live agents, shipped issues, and how often
  review sent work back.
- **Flow**: the factory as a live diagram. Each node is a Linear state plus `factory/*`
  stage, edge weights are observed transitions, and dashed edges are loops back for rework.
  Colored dots on a node are the agents running there, by harness.
- **Needs you**: the only things waiting on a human. That means issues in review (oldest first),
  blocked issues, retries with their error, and accounts that are limited or exhausted.
- **Live sessions**: what each agent is doing now, with its stage, harness, thinking level,
  runtime, latest update, and tokens.
- **Spend**: cost or tokens grouped by project, team (the Linear key, for example `PAY`), or
  task, split by harness. Hover a bar for input and output tokens, or switch to the table view.

### Steering the factory from the diagram

Click a stage to manage it. Its controls replace the Needs-you column so the whole diagram
stays visible. `#stage=<name>` in the URL deep-links to a stage.

![Stage controls](../.github/media/dashboard-stage-controls.png)

For agent stages (Todo, Implement, Rework, Merge) you can:

- **Pause dispatch**: no new agents start in that stage, and running ones finish their turn.
- **Cap concurrency**: the most agents allowed in that stage at once.
- **Pick the harness and thinking level**: the default for that stage. An issue's own `codex`,
  `claude`, `thinking/*` labels still win.

Each stage also lists its issues with one-click moves that write back to Linear (state plus
stage label). In review, that means **Approve & merge** or **Send to rework**:

![Review actions](../.github/media/dashboard-review-actions.png)

Stage settings persist in `~/.symphony/factory_controls.json`. Changes apply instantly in the
UI and roll back with a message if the server rejects them.

Who can do what comes from Linear (see below). `server.controls: false` makes the page
read-only for everyone.

### Sign-in and permissions

There are no Symphony accounts to manage. People sign in with their own **Linear personal
API key**, and Symphony asks Linear who they are, which teams they're in, and whether they're
an admin:

![Sign in](../.github/media/dashboard-sign-in.png)

| Who (in Linear)               | Can                                                            |
| ----------------------------- | -------------------------------------------------------------- |
| Workspace admin               | Everything, including stage controls for the whole factory     |
| Team member                   | Move that team's issues (approve, rework, block, …)            |
| Guest                         | View only                                                      |
| Anyone outside the workspace  | Can't sign in (must match the organization of `tracker.api_key`) |

- Changes are made **as the signed-in person** using their key, so Linear's history shows who
  approved or blocked what.
- The key is stored only in an encrypted, HTTP-only session cookie (30 days). Profiles and
  team memberships are re-read from Linear every 10 minutes.
- Session cookies are signed with `server.secret_key_base` (or `SYMPHONY_SECRET_KEY_BASE`). If
  neither is set, Symphony generates one at `~/.symphony/secret_key_base`, so sessions survive
  restarts.
- The JSON API and `/metrics` accept a session or `Authorization: Bearer <Linear API key>`,
  so a Prometheus scraper can use a key from a service account.

Sign-in mode follows where the server listens. On a loopback address (the default
`127.0.0.1`) there is no sign-in: you are the local operator. On any other address, Linear
sign-in is required. Override this with `server.auth: local | linear`.

### Cost

Token usage is recorded per project, team, task, harness, and model in
`~/.symphony/usage.json`, so totals survive restarts. Add rates (USD per million tokens) to
price it, keyed by harness or `harness/model`:

```yaml
pricing:
  claude:
    input_per_mtok: 3
    output_per_mtok: 15
  codex/gpt-5.4:
    input_per_mtok: 1.25
    output_per_mtok: 10
```

Without `pricing`, the dashboard still shows tokens and marks cost as unpriced.

### Under the hood

- LiveView at `/`; the JSON API under `/api/v1/*` (its state payload includes a `factory`
  section with flow, usage, and controls).
- The diagram and spend explorer render client-side from a single payload, so grouping,
  filtering, hover, and opening stages run in the browser. With a 2,000-row usage history,
  these take 0.5 to 0.9 ms (median).
- Bandit HTTP server; dependency-free embedded JS and CSS.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `symphony.yml`: global runtime config and Linear project routing
- `WORKFLOW.md`: repo-local workflow contract for a single routed project
- `../.codex/`: repository-local skills and setup helpers used by the workflow

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `opencode serve --hostname 127.0.0.1 --port 0` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`

`make e2e` currently targets the local-only OpenCode flow.

The live test creates a temporary Linear project and issue, writes a temporary `symphony.yml` plus
repo-local `WORKFLOW.md`, runs a real agent turn, verifies the workspace side effect, requires
OpenCode to comment on and close the Linear issue, then marks the project completed so the run
remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch Codex, Claude Code, or OpenCode in your repo, give it the URL to the Symphony repo, and ask
it to set things up for you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
