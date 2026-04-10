# Symphony Setup

This guide walks through a practical multi-project setup using placeholder project names you can replace with your own:

- Linear project `project-a` routes to `~/dev/project-a`
- Linear project `project-b` routes to `~/dev/project-b`
- `codex` is the default backend
- `claude` and `opencode` are also configured and available through labels or per-project defaults

The key split is:

- `symphony.yml` is the global Symphony runtime config
- each repo gets its own `WORKFLOW.md`

## 1. Prerequisites

You should have:

- a Linear personal API key
- `codex` installed and authenticated
- optionally `claude` and `opencode` installed if you want those backends available
- two local repos already cloned

Example local repos:

```bash
~/dev/project-a
~/dev/project-b
```

Set your Linear token:

```bash
export LINEAR_API_KEY=your_linear_api_key
```

If you use [mise](https://mise.jdx.dev/), install the Elixir toolchain:

```bash
cd /path/to/symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
```

## 2. Add `WORKFLOW.md` to each repo

Each project repo should contain its own `WORKFLOW.md`.

Start by copying the example from this directory:

```bash
cp /path/to/symphony/elixir/WORKFLOW.md ~/dev/project-a/WORKFLOW.md
cp /path/to/symphony/elixir/WORKFLOW.md ~/dev/project-b/WORKFLOW.md
```

In multi-project mode, each repo-local `WORKFLOW.md` may define:

- `hooks.*`
- `agent.default_effort`
- `agent.max_turns`
- the Markdown prompt body

It should not define global runtime settings like Linear auth, polling, backend commands, or worker config. Those now live in `symphony.yml`.

Minimal example:

```md
---
hooks:
  after_create: |
    if command -v mise >/dev/null 2>&1 && [ -f mise.toml ]; then
      mise trust
      mise install
    fi
agent:
  default_effort: medium
  max_turns: 20
---

You are working on Linear issue `{{ issue.identifier }}`.

Project: {{ issue.project_name }} ({{ issue.project_slug }})
Title: {{ issue.title }}

{{ issue.description }}
```

Customize each repo's `WORKFLOW.md` with that repo's build, test, and delivery expectations.

## 3. Create a global `symphony.yml`

Put `symphony.yml` somewhere outside your app repos, or in a dedicated ops/config repo.

Example:

```bash
mkdir -p ~/ops/symphony
```

Create `~/ops/symphony/symphony.yml`:

```yaml
tracker:
  kind: linear
  endpoint: https://api.linear.app/graphql
  api_key: $LINEAR_API_KEY
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done

polling:
  interval_ms: 5000

workspace:
  root: ~/work/symphony-workspaces

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
  - linear_project: project-a
    repo: ~/dev/project-a
    workflow: ~/dev/project-a/WORKFLOW.md
    workspace_root: ~/work/symphony-workspaces/project-a
    backend: codex

  - linear_project: project-b
    repo: ~/dev/project-b
    workflow: ~/dev/project-b/WORKFLOW.md
    workspace_root: ~/work/symphony-workspaces/project-b
    backend: claude
```

How this works:

- Symphony polls Linear once using the global `tracker` config
- when it sees a ticket in Linear project `project-a`, it uses the `project-a` repo and workflow
- when it sees a ticket in Linear project `project-b`, it uses the `project-b` repo and workflow
- if a ticket has no backend label, Symphony uses the route backend, then falls back to `agent.backend`

Backend precedence for a ticket, from lowest to highest, is:

1. `agent.backend` in `symphony.yml`
2. `projects[].backend`
3. backend routing label on the Linear ticket such as `codex`, `claude`, or `opencode`

Effort precedence, from lowest to highest, is:

1. global `agent.default_effort` in `symphony.yml`
2. repo-local `WORKFLOW.md` `agent.default_effort`
3. thinking label on the Linear ticket such as `thinking/high`

If you prefer to keep the global config beside the repos, relative paths also work. They resolve relative to the directory containing `symphony.yml`.

## 4. Make sure the Linear projects and states match

The `projects[].linear_project` value must match the Linear project slug (`project.slugId`), not just the display name.

Symphony expects these workflow states in Linear:

- `Backlog`
- `Todo`
- `In Progress`
- `Human Review`
- `Merging`
- `Rework`
- `Done`

For the example config above, active states are:

- `Todo`
- `In Progress`
- `Merging`
- `Rework`

## 5. Start Symphony

From the Elixir app directory:

```bash
cd /path/to/symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ~/ops/symphony/symphony.yml
```

If you omit the config path, Symphony defaults to `./symphony.yml` in the current directory:

```bash
mise exec -- ./bin/symphony
```

Passing a `WORKFLOW.md` path explicitly still works, but that is the legacy single-project mode:

```bash
mise exec -- ./bin/symphony /path/to/a/single/WORKFLOW.md
```

## 6. Verify routing

A simple smoke test:

1. Create a Linear issue in the `project-a` project.
2. Start Symphony with your `symphony.yml`.
3. Confirm Symphony creates or reuses a workspace under `~/work/symphony-workspaces/project-a/...`.
4. Confirm the prompt and hooks come from `~/dev/project-a/WORKFLOW.md`.
5. Repeat with an issue in `project-b` and confirm it routes to the other repo and workflow.

If you add a backend label like `opencode` to a ticket, that label overrides the project's default backend for that issue.

## 7. Common mistakes

- The Linear project slug in `projects[].linear_project` does not match the actual Linear project slug.
- `projects[].workflow` points to a file that does not exist.
- Repo-local `WORKFLOW.md` includes global config like `tracker`, `worker`, `codex`, `claude`, or `opencode`.
- `LINEAR_API_KEY` is missing in the shell where Symphony starts.
- A repo path contains spaces and is not quoted in YAML.

If your repo path contains spaces, quote it:

```yaml
projects:
  - linear_project: project-a
    repo: "~/dev/project a"
    workflow: "~/dev/project a/WORKFLOW.md"
```

## 8. Recommended file layout

One reasonable layout looks like this:

```text
~/ops/symphony/symphony.yml
~/dev/project-a/WORKFLOW.md
~/dev/project-b/WORKFLOW.md
~/work/symphony-workspaces/
```

That keeps the global orchestration config separate from the repo-owned workflow files.
