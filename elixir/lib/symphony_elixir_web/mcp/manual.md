# Symphony manual

## Overview

Symphony is an agent factory. It watches Linear for issues and runs coding agents (Codex,
Claude Code, OpenCode) on them, each issue in its own workspace and sandbox. Agents take an
issue from a plan to an open pull request, and people stay in charge where the team chooses:
approving a plan, reviewing a PR, unblocking stuck work.

You talk to Symphony through this MCP server: see what the factory is doing, read an issue's
history and agent transcript, change the flows issues move through, move issues by hand, message
the agent on an issue, and (as an admin) choose which Linear projects Symphony works on and in
which GitHub repos. Everything you do here is done as you, with your permissions, and is
recorded with your name and token.

Start with `symphony_status` and `list_flows` for the live state. The sections people ask about
most: **Set up a new project**, **How Symphony picks the repo**, **Working across repos**.

## Concepts

| Term | Meaning |
| --- | --- |
| Project | A Linear project Symphony listens to (`list_projects`), mapped to one **primary** GitHub repo and optionally more repos (`repos`). |
| Home repo | The one repo an issue is worked in: its workspace, branch, commits and PR are there. See **How Symphony picks the repo**. |
| Reference repos | The project's other repos, checked out read-only beside the home repo under `.symphony/repos/<name>`. |
| Flow | The stages issues move through and the moves between them. An issue follows its project's own flow if it has one, else its team's, else the organisation default (`DEFAULT`). |
| Stage | A step in a flow, e.g. Todo, Implement, In Review. In Linear a stage is the issue's workflow state plus, where states are shared, a `factory/<stage>` label. |
| Stage kind | `queue` (waiting for an agent), `agent` (an agent works it), `human` (waits for a person; agents never touch it), `parked` (on hold, e.g. Blocked), `done`. |
| Transition | An allowed move between two stages, with **who** makes it (`agent` or `human`) and **when** (its criteria). |
| Stage settings | Per agent stage: `harness` (codex, claude, opencode), `effort`, `instructions`, `skill`, `checks`, `environment`, and the runtime controls `paused`, `max_agents`, `approval`. |
| Autopilot | Earned autonomy for a flow: every agent stage needs approval until it has earned a streak of approvals in a row; a send-back resets it. |
| Labels | `factory/<stage>` (stage), `repo/<name>` (home repo), `codex` / `claude` / `opencode` (harness for this issue), `thinking/<level>` (effort), the approval label (default `needs-approval`, a held move), and optionally the `require_label` the install dispatches on. |

The default flow: **Todo** (queue) -> **Implement** (agent, In Progress) -> **In Review**
(human) -> **Merge** (agent) -> **Done**, with **Rework** (agent) for a fresh approach and
**Blocked** (parked, In Progress + `factory/blocked`) for stuck work.

## Set up a new project

What only the people who run Symphony can do (its config file, `symphony.yml`): the Linear API
key and GitHub credentials, workspace `hooks` (e.g. installing dependencies), custom agent
`prompt` files, the `environments` catalog and `teams` defaults. Everything below is MCP.

**1. GitHub.** Make sure Symphony's GitHub access (its GitHub App installation, or the token it
runs with) covers **every** repo the project will use, with contents and pull-request write
access: any of them can be an issue's home repo. Agents push `symphony/<issue>` branches and open
PRs, so branch protection must allow that; they never push to the default branch. The repos need
no Symphony files. Optional: a `.symphony/environment.yaml` in a repo to pick an image or
services from the catalog for issues worked there.

**2. Linear.** Create the project in the team(s) whose people will file issues. The team's
workflow needs the states its flow uses (default flow: Todo, In Progress, In Review, Done), and
Symphony's Linear account must see the team. You don't create labels: Symphony creates the
`factory/*` stage labels, the approval (and require) label, and for a multi-repo project the
`repo` label group with one `repo/<name>` label per repo, in each of the project's teams.

**3. Add it** (admin token with write scope):

```json
add_project {
  "project": "https://linear.app/acme/project/storefront-0a1b2c3d4e5f",
  "repo": "acme/web",
  "default_branch": "main",
  "repos": [
    {"repo": "acme/api", "name": "api", "description": "REST API and database migrations"}
  ]
}
```

`repo` is the primary repo, named after its last path segment (`web`); each of `repos` is named
by `name` (default: its last path segment). Write a `description` for each repo: agents read it
to decide where a problem belongs. Optional: `backend` (default harness), `environment` (a
catalog entry), `workflow` (a legacy repo `WORKFLOW.md`; leave it out). Calling `add_project`
again for the same project **replaces** its settings, so always pass the full `repos` list.
Check the result with `list_projects`.

**4. Choose the flow** (optional). `list_flows` shows which flow the project's team uses. To
give this project its own: `get_flow` with `scope: "project:0a1b2c3d4e5f"` (it returns the
inherited definition), edit it, then `save_flow` with the same scope and the `version` you read.
Stage changes: `set_stage_control`; earned autonomy: `set_autopilot`. Add human checkpoints as
described in **People in the loop**.

**5. File an issue** in the project, in the flow's queue state (Todo; not Backlog), with a
`repo/<name>` label if it isn't for the primary repo. If the install sets a `require_label`, add
that too.

**What happens next.** Right after `add_project`, Symphony reads the project's name and teams
from Linear and creates the missing labels. On the next poll (every 30 s by default, or call
`refresh`) it sees the issue in a queue stage and dispatches it: it resolves the home repo (a bad
repo label stops here, with a comment), syncs its cache of that repo from GitHub (the first time
this clones it: this is where missing GitHub access shows up, in `symphony_status` and
`get_issue`), creates the workspace on `symphony/<issue>`, checks out the other repos under
`.symphony/repos/`, runs the setup hooks, and starts the agent for the first agent stage.

## How Symphony picks the repo

Symphony applies these rules, in order, every time an issue is dispatched:

1. **Project.** The issue's Linear project must be one Symphony listens to (`list_projects`);
   otherwise the issue isn't worked at all. Its repos are the project's primary `repo` and its
   `repos`. There is always exactly one primary: the `repo` the project was added with.
2. **Repo labels.** Symphony looks at the issue's labels that start with `repo/` (case doesn't
   matter):
   - **none**: the home repo is the **primary** repo;
   - **one**, naming one of the project's repos (the primary's name or a `repos` name): the home
     repo is **that repo**;
   - **one that names no repo of the project**: the issue is **not worked**. Symphony comments
     `## Repo label problem` on it once, listing the project's repos, and no agent starts until
     the label is fixed or the repo is added to the project;
   - **two or more**: likewise not worked, with the same comment: one issue changes one repo.

   Repo names: the primary is named after its last path segment, lowercased (`acme/Web-App` is
   `web-app`); each of `repos` has its `name` (default: its own last segment). `list_projects`
   shows them.
3. **Workspace.** The workspace is a checkout of the home repo on `symphony/<issue>`; every
   other repo of the project is checked out read-only under `.symphony/repos/<name>`.
4. **Re-checked every run.** If the home repo has changed since the workspace was made (the label
   was changed, or the issue moved to another project), Symphony replaces the workspace with a
   fresh checkout of the new home repo before the run.

The home repo also decides the agent's GitHub token (when Symphony uses its GitHub App, the
token can push to the home repo only), the repo whose `.symphony/environment.yaml` is used, and
where the PR is opened.

| Case | What happens |
| --- | --- |
| No `repo/` label | Primary repo. |
| Single-repo project | Always its repo; no `repo` labels are created. A `repo/<name>` label naming another repo stops the issue (rule 2). |
| Multi-repo project, no label | The primary, which is the project's `repo`: there's no project without one. |
| Label names a repo not in the project | Not worked; `## Repo label problem` comment. Fix the label, remove it, or add the repo (`add_project` with the full `repos` list). |
| Two repo labels | Not worked; comment. Keep one; split the work into one issue per repo. |
| Label changed after the workspace exists | The next run starts in a fresh checkout of the new repo, on a new `symphony/<issue>` branch there. Unpushed changes in the old workspace are lost; the old branch and any PR stay in the old repo for a person to close. A run already going finishes in the old repo. |
| Issue moved to another Symphony project | Its repos are now the new project's: rules 1 and 2 apply again (its old `repo/` label may now be a problem), and it gets a fresh workspace. |
| Issue moved to a project Symphony doesn't listen to | No longer picked up. |
| Repo not in any project | No issue can be worked there. Add it to a project's `repos` (or add a project for it). |

## Working across repos

**Rule: an issue changes only its home repo.** An agent can read every repo of its project but
commits, pushes and opens a PR only in its home repo. A change that needs two repos is two
issues, one per repo, linked as blocking.

**What the agent sees.** The home repo checkout, and each other repo of the project at
`.symphony/repos/<name>`, detached at its default branch. The reference checkouts are reset at
the start of every run to Symphony's copy of that branch (fetched from GitHub when older than a
minute, and kept warm in the background), so they show what is merged, never open PRs. Edits
there are thrown away and are kept out of the home repo's `git status`. The prompt's
**Repositories** section lists the repos with their descriptions and these rules. On Kubernetes
runner pods the same checkouts come from Symphony's read-only git mirror, which serves a run
only the repos of its own project.

**Worked example.** Project *Storefront*: primary `acme/web` (`web`), and `acme/api` (`api`).

1. WEB-12 "Checkout shows the wrong tax" has no repo label, so it's worked in `acme/web`.
2. The agent finds the API returns the wrong tax: it reads `.symphony/repos/api` to locate the
   cause, but doesn't change it. Instead it creates **WEB-13** in Linear: same project and team,
   in the flow's queue state (Todo), assigned like WEB-12, labelled `repo/api` (and the
   `require_label` if the install has one), with a description of what must change in `acme/api`,
   the evidence (errors, files, lines), how to verify it, and a link to WEB-12.
3. It links WEB-13 as **blocking** WEB-12, pushes whatever WEB-12 has on its branch, and ends its
   stage with the move to **Blocked**, saying in its summary that WEB-13 blocks it.
4. WEB-12 waits in Blocked (agents never touch a parked stage). On the next poll Symphony picks
   up WEB-13, in `acme/api` because of its label, on its own branch `symphony/WEB-13`, with
   `acme/web` as its reference. It goes through the flow like any issue: PR in `acme/api`,
   review, merge, Done.
5. On the first poll after **every** issue blocking WEB-12 is completed (Linear state type
   *completed*, i.e. Done), Symphony comments `## Unblocked` on WEB-12, listing each blocker with
   its link, PRs and stage summaries, and moves WEB-12 back to the stage it was blocked from
   (else the first agent stage Blocked leads to: Implement in the default flow).
6. WEB-12's next run reads that comment, finds `.symphony/repos/api` refreshed with the merged
   fix, and finishes in `acme/web`: its PR there.

The two PRs are separate, one per repo, each attached to its own Linear issue; the Linear
blocking link is what ties them. Symphony doesn't order deployments: if the web change needs the
API change live, say so in the issues.

**When unblocking doesn't happen.** A cancelled blocker keeps the issue Blocked for a person; so
does a Blocked issue with no blocking links (blocked on access or information). Symphony unblocks
an issue once per set of blockers: moving it back to Blocked by hand keeps it there. The flow
needs a move from the parked stage to an agent or queue stage.

**When the needed repo isn't in the project.** The agent can't see or change it: it describes
the change in its workpad and summary and moves its issue to Blocked. An admin adds the repo with
`add_project` (same project and `repo`, the full `repos` list plus the new one, with a
description); Symphony creates its `repo/<name>` label. Then file the issue for it (or let the
next run do it) and move the blocked issue on with `move_issue`.

## An issue's life

1. Someone files an issue in a project Symphony listens to, in the flow's queue stage.
2. On the next poll Symphony picks it up (see **How Symphony picks the repo**) and starts an
   agent for the first agent stage, with the issue, Symphony's agent prompt, the stage's
   instructions and the moves it may make.
3. The agent works, commits and pushes on `symphony/<issue>`, and ends its stage with a result: a
   summary (posted on the issue as a comment) and the move it chose. Symphony makes the move in
   Linear: the new state and stage label.
4. The next agent stage reads the earlier summaries. A failed test or review sends it back (e.g.
   In Review -> Implement).
5. At a `human` stage the issue waits until a person moves it on, from Linear, the dashboard or
   `move_issue`.
6. A stuck agent moves the issue to Blocked and says what it needs; a person resolves it and
   moves it back, unless it's blocked by other issues, which Symphony handles (see **Working
   across repos**).

Agents never merge PRs unless their stage's instructions say so (the default Merge stage does,
after a person approved the PR), and never push to the default branch.

## What agents are told

Each stage's prompt is built from three parts:

1. **The agent prompt**: the issue (identifier, title, description, state, labels, link) and
   Symphony's standing instructions: one `## Symphony Workpad` comment edited in place;
   reproduce before changing code; treat the issue's Validation/Test Plan as required; file
   out-of-scope work as a Backlog issue linked `related`; sync with the base branch, validate
   before every push, open the PR with the `symphony` label and attach it to the issue, sweep PR
   feedback; never change the issue's state or labels; what to do when blocked.
2. **The stage section**, from the flow: the stage's instructions, skill, checks, the moves the
   agent may make, and how to finish.
3. **The repositories section**, for a multi-repo project: the rules in **How Symphony picks the
   repo** and **Working across repos**, the home repo, the other repos with their paths and
   descriptions, and the exact steps to file a blocking issue.

| What | Where | Through MCP? |
| --- | --- | --- |
| Stage instructions, skill, checks, moves, harness, effort, environment, approval | the flow | yes: `get_flow` + `save_flow`, `set_stage_control` |
| A project's repos and their descriptions | `add_project` (or the config file) | yes, for projects added through MCP |
| A project's default harness and environment | `add_project` `backend`, `environment` | yes |
| Container image and services for a repo | the catalog, plus the home repo's `.symphony/environment.yaml` | no |
| Workspace setup hooks | config file `hooks` (projects added through MCP get the top-level ones) | no |
| The agent prompt itself | built in; a config-file project can set its own `prompt` | no |

## People in the loop

A flow decides where people step in:

- **Human stage**: e.g. In Review. The agent's move ends there; a person moves it on
  (`move_issue`) along a `human` transition, e.g. approve to Merge or send back to Implement.
- **Approval on an agent stage** (`set_stage_control`, `field: approval`): the agent's move out
  of the stage is held, with the approval label, until a person approves it or sends it back
  (`review_issue`). `list_issues` with `awaiting_approval: true` lists them.
- **Autopilot** (`set_autopilot`): approval on every agent stage until it has earned `streak`
  approvals in a row.
- **Blocked**: waits for a person, unless it's blocked by other Linear issues (see **Working
  across repos**).
- **Messages**: `send_agent_message` reaches the agent in its running turn (Codex) or at the start
  of the next one.

To add a checkpoint: add a stage of kind `human` (its own label, usually in the In Review state),
point the agent stage's transition at it, and add `human` transitions out of it.

## Using this MCP

**Tokens.** Create and revoke them on the dashboard's **MCP tokens** page (top-right menu,
`/account/mcp`). A token has scopes `read` (look) and optionally `write` (change), and can be
limited to chosen teams or `project:<slug>` scopes. It never does more than your account may,
and stops working when your account is disabled or loses that access.

**Who can do what.**

| Action | Needs |
| --- | --- |
| Read tools | any token; you see the teams and projects you have access to (`list_projects` lists all) |
| Flow edits (`save_flow`, `set_stage_control`, `set_autopilot`, `reset_flow`) | `write`; members their teams' flows and their projects' flows, admins any (including `DEFAULT`) |
| `move_issue`, `review_issue`, `send_agent_message` | `write`; members issues of their teams or granted projects. Members make `human` moves, admins any move |
| `refresh` | `write` |
| `add_project`, `remove_project` | `write` and admin |

Write tools are refused while the server's controls are switched off. Flow changes apply to the
next stage an agent starts; running agents finish their turn. Flow saves are version-checked.

## MCP tool reference

Read (scope `read`):

| Tool | Arguments | What it does |
| --- | --- | --- |
| `get_manual` | `section` (optional) | This manual, or one section. Also the resources `symphony://manual` and `symphony://manual/<section>`. |
| `symphony_status` | none | Agents running and retrying (issue, stage, harness, turns, tokens, latest event), capacity, polling, rate limits, pending restart. |
| `list_flows` | none | The flows you can see (default, teams, projects), which flow each uses, version, stage ids, whether you may edit it. |
| `get_flow` | `scope`: `DEFAULT`, a team key, or `project:<slug>` | A flow's definition (stages, settings, transitions, autopilot), the issues in each stage, and its `version`. |
| `list_issues` | `scope`, `stage`, `awaiting_approval` (all optional) | Issues Symphony tracks, with stage, flow and whether a move is held for approval. |
| `get_issue` | `identifier` (e.g. `WEB-12`) | Stage, previous stage, move history, live session or retry, and messages to its agent. |
| `get_transcript` | `identifier`, `limit` (default 50, max 200) | The newest transcript entries: messages, thinking, commands with output, edits, tool calls, turns. |
| `list_projects` | none | The projects Symphony listens to: primary `repo`, `repos`, branch, harness, environment, `source` (`config` or `mcp`) and whether it's active. |

Write (scope `write`):

| Tool | Arguments | What it does |
| --- | --- | --- |
| `save_flow` | `scope`, `base_version`, `definition` | Replaces a flow's definition. On a version conflict nothing is written; re-read and redo. Missing `factory/*` labels are created. |
| `set_stage_control` | `scope`, `stage`, `field` (`paused`, `max_agents`, `backend`, `effort`, `approval`), `value` | Changes one runtime control of a stage; `null` clears it. |
| `set_autopilot` | `scope`, `enabled`, `streak` | Turns earned autonomy on or off; resets every stage's streak. |
| `reset_flow` | `scope` | Deletes a team's or project's own flow so it inherits again. |
| `move_issue` | `issue` (identifier or id), `to` (stage id) | Moves an issue along a connection of its flow. |
| `review_issue` | `issue`, `verdict` (`approve` or `send_back`) | Decides a move held for approval. |
| `send_agent_message` | `identifier`, `text` (max 8000) | Messages the agent on an issue. |
| `refresh` | none | Polls Linear now instead of at the next tick. |
| `add_project` | `project` (URL or slug id), `repo` (`owner/name`), optional `default_branch`, `backend`, `environment`, `workflow`, `repos` (each `repo`, optional `name`, `default_branch`, `description`) | Admins: listen to a Linear project from the next poll, or replace its settings. Creates its labels in Linear. |
| `remove_project` | `project` | Admins: stop listening to a project added through MCP; running agents finish, nothing new starts. |

Projects in the config file can't be changed or removed here; projects added here can only point
at GitHub repos and can't set hooks or prompts.

## Recipes

**Explain what's happening.** `symphony_status`, then `list_issues`; for one issue `get_issue`
and `get_transcript`.

**Make an issue work in repo X.** X must be one of the project's repos (`list_projects`). Label
the issue `repo/<name of X>` and remove any other `repo/` label, ideally before it's picked up.
If X isn't in the project, an admin adds it: `add_project` with the same `project` and `repo`
and the full `repos` list including X.

**Give a project another repo.** `list_projects` to read its current `repos`, then `add_project`
with the same `project`, `repo` and every existing repo plus the new one (with a `description`).

**Change what agents are told.** `get_flow`, edit the stage's `instructions` (or `skill`,
`checks`), `save_flow` with the `version` you read.

**Pause a stage.** `set_stage_control` with `field: "paused"`, `value: true`; `false` to resume.

**Require approval for a stage.** `set_stage_control` with `field: "approval"`, `value: true`;
then `review_issue` the held moves (`list_issues` with `awaiting_approval: true`).

**Unblock an issue.** `get_issue` to read why, fix the cause, then `move_issue` to a stage its
Blocked transitions allow. Issues blocked by other issues come back by themselves.

**Follow work across repos.** The Blocked issue's summary names its blocker; `get_issue` and
`get_transcript` on the blocker show its progress. `move_issue` either one to take over.

**Tell an agent something.** `send_agent_message` with the identifier and your text.

## Guardrails

- Agents work only in their workspace and sandbox, on `symphony/<issue>` branches, and never push
  to the default branch.
- An agent changes only its issue's home repo; the other repos are read-only references, and with
  Symphony's GitHub App its token can push to the home repo only.
- Agents make only the moves their stage allows; people approve where the flow says so.
- Your token can do what you can do in Symphony, never more.
- Flow saves are version-checked, so two editors can't silently overwrite each other.

## Troubleshooting

- **Why did it work in the wrong repo?** The home repo comes from the issue's `repo/` label at
  dispatch, else the primary (**How Symphony picks the repo**). An unlabelled issue goes to the
  primary. Fix the label: the next run starts over in the right repo (close the stray PR by
  hand).
- **How do I make it work in repo X?** See the recipe **Make an issue work in repo X**.
- **Can one issue change two repos?** No. File one issue per repo and link them as blocking; the
  agent does this itself when it finds the fix belongs elsewhere (**Working across repos**).
- **An issue has a `## Repo label problem` comment.** Its `repo/` label names no repo of its
  project, or it has two. Fix the label or add the repo; the next poll picks it up.
- **An issue isn't picked up.** Check its project is in `list_projects`, it's in a `queue` or
  `agent` stage (not Backlog, human, parked or done), the stage isn't paused, it carries the
  install's `require_label` if there is one, its repo label is valid, and capacity isn't full
  (`symphony_status`).
- **The agent can't see another repo.** Only the project's repos are checked out; add the repo to
  the project.
- **A Blocked issue didn't move back.** Every blocker must be completed (a cancelled one keeps it
  Blocked) and linked as *blocking* (not related); the flow needs a move from Blocked to an agent
  stage; and an issue moved back to Blocked by hand after Symphony unblocked it stays there.
- **An agent keeps failing in a loop.** Read the summaries (`get_issue`) and transcript
  (`get_transcript`); guide it with `send_agent_message` or move it to Blocked.
- **`save_flow` refused.** A version conflict means someone saved first: `get_flow` again and
  redo your change. Validation errors name the field to fix.
- **"Only admins..." or "Only this team's members..."** Your account or your token's limits don't
  cover that team, project or action.
