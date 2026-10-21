# Symphony manual

## Overview

Symphony is an agent factory. It watches Linear for issues and runs coding agents (Codex,
Claude Code, OpenCode) on them, each issue in its own isolated workspace and sandbox. Agents
take an issue from a plan to an open pull request, and people stay in charge at the points the
team chooses: approving a plan, reviewing a PR, unblocking stuck work.

You talk to Symphony through this MCP server. You can see what the factory is doing, read an
issue's history and agent transcript, change the flow issues move through, move issues by
hand, message the agent working on an issue, and (as an admin) choose which Linear projects
Symphony works on. Everything you do here is done as you, with your permissions, and is
recorded with your name and the token you used.

To answer "what is this?", start here; for the live state, call `symphony_status` and
`list_flows`.

## Concepts

- **Issue**: a Linear issue. Symphony works an issue when its Linear project is one Symphony
  listens to (see `list_projects`) and its current stage is one agents run.
- **Project**: a Linear project mapped to a GitHub repo, and optionally more repos. An issue's
  agent works in a fresh clone of its repo, on the branch `symphony/<issue identifier>`, and
  Symphony gives every stage its base instructions (its built-in agent prompt, or the project's
  own prompt) and runs the project's setup hooks; the repo needs no Symphony files. In
  a multi-repo project an issue's repo is the one its `repo/<name>` label names (else the
  primary), and the other repos are checked out read-only beside it.
- **Flow**: the stages issues move through and the connections between them. Each team has a
  flow, and a project may have its own. An issue follows its project's flow if it has one,
  otherwise its team's, otherwise the organisation's default flow.
- **Stage**: a step in a flow, such as Plan, Implement or Review. In Linear a stage is the
  issue's workflow state plus a `factory/<stage>` label, so several stages can share one
  state. Every stage has a **kind**:
  - `queue`: waiting for an agent to pick the issue up;
  - `agent`: an agent works it;
  - `human`: waiting on a person; agents never touch it;
  - `parked`: deliberately on hold (Blocked);
  - `done`: finished.
- **Transition**: an allowed move between two stages, with **who** makes it (`agent` or
  `human`) and **when** (its criteria). Agents can only make the agent moves their stage lists;
  people can make any move a person is allowed to, and admins can force agent moves.
- **Stage settings**: an agent stage names its **harness** (codex, claude, opencode), its
  thinking **effort**, its instructions (and optionally a skill and checks), and runtime
  controls: **paused** (no new agents start there), **max_agents** (a concurrency cap) and
  **approval** (a person must approve every move an agent makes out of it).
- **Autopilot (earned autonomy)**: when a flow turns it on, every agent stage needs approval
  until it has earned a streak of approvals in a row; a send-back resets the count.
- **Labels**: besides the `factory/*` stage labels, an issue labelled `codex`, `claude` or
  `opencode` runs on that harness, and `thinking/<level>` sets the effort, overriding the
  stage's defaults.

## An issue's life

1. Someone files an issue in a project Symphony listens to. It starts in the flow's queue
   stage (usually Todo).
2. On its next poll Symphony picks it up and starts an agent for the first agent stage. The
   agent gets the issue, Symphony's agent prompt, its stage's instructions, and the
   moves it may make.
3. The agent works, commits and pushes on `symphony/<issue>`, and ends its stage by writing a
   result: a summary (posted on the Linear issue as a comment) and the move it chose.
   Symphony makes that move in Linear: the new state and stage label.
4. The next agent stage picks the issue up and reads the earlier stages' summaries. A failed
   test or review sends it back along a loop (for example Test back to Implement).
5. At a `human` stage the issue waits. A person reads the summary or the PR and moves the
   issue on, from Linear or the dashboard or with `move_issue` here.
6. If an agent is stuck (missing access, unclear requirements) it moves the issue to Blocked
   and says what it needs; a person resolves it and moves it back.
7. If the fix belongs in another of the project's repos, the agent files an issue for that repo,
   links it as blocking, and moves its own issue to Blocked. When every blocker is done,
   Symphony moves the issue back to Implement with a comment saying what the blockers changed.

Agents never merge pull requests unless their flow's instructions say so, and they never push
to the default branch.

## What agents are told

Everything an agent is told comes from Symphony; a repo needs no Symphony files. Each stage's
prompt is built from three parts, in this order:

1. **The agent prompt**: the issue (identifier, title, description, state, labels, link) and
   Symphony's standing instructions for unattended work:
   - one `## Symphony Workpad` comment on the issue, edited in place, with the plan, acceptance
     criteria, validation and notes;
   - reproduce before changing code; treat the issue's Validation or Test Plan as required;
   - file out-of-scope work as a new Backlog issue in the same project, linked `related`;
   - sync with the base branch, validate before every push, open the PR with the `symphony`
     label, attach it to the issue, and sweep PR feedback until none is left;
   - never change the issue's state or labels (Symphony does that), and what to do when blocked.
   This is Symphony's built-in prompt unless the project has its own (see below).
2. **The stage section**, from the issue's flow: the stage's instructions, its skill, the checks
   Symphony runs before moving the issue, every move the agent may make from it, and how to
   finish (write a result with a move and a summary).
3. **The repositories section**, for a project with more than one repo: which repo this issue
   is worked in, where the others are, and how to block on another repo.

Where each part is changed:

| What | Where | Through MCP? |
| --- | --- | --- |
| Stage instructions, skill, checks, moves, harness, effort, approval | the flow | yes: `get_flow` + `save_flow`, `set_stage_control` |
| Workspace setup hooks (install dependencies, etc.) | Symphony's config file, top-level `hooks` or the project's `hooks` | no |
| The agent prompt itself | built in; a project in the config file can set `prompt` to its own template | no |
| A project's repos | the config file, or `add_project` with `repos` | yes, for projects added through MCP |

Projects added through MCP use the built-in prompt and the config file's top-level hooks. A
project in the config file can still name a repo `WORKFLOW.md` (`workflow`) whose prompt and
agent settings replace Symphony's; that is optional and kept for older setups.

## Projects and repos

A project maps one Linear project to one or more GitHub repos. The first is the **primary**
repo, named after its last path segment (`acme/payments-api` is `payments-api`); others have
the name they were given (`repos[].name`, default their own last segment).

- **An issue is worked in one repo, its home repo**: the one its `repo/<name>` label names, else
  the primary. Symphony creates the `repo` label group, with a label per repo, in each of the
  project's teams. Set the label when filing the issue: an issue whose workspace already exists
  keeps the repo it started in.
- The workspace is a clone of the home repo on `symphony/<issue>`; commits, the branch and the PR
  go there only.
- The project's other repos are checked out read-only under `.symphony/repos/<name>`, at their
  default branch, refreshed at the start of every run (changes there are thrown away), so the
  agent can read them.
- **Blocking on another repo.** When the fix belongs elsewhere, the agent creates an issue for
  that repo (in Todo, same project and team, with its `repo/<name>` label and a description of
  what to change, the evidence and how to verify), links it as **blocking** its own issue,
  pushes its work, and moves its own issue to Blocked.
- **Unblocking.** On every poll, an issue in a parked stage (such as Blocked) whose blockers are
  all **completed** is moved back to work: to the stage it was blocked from when the flow
  connects the two, else to the first agent stage Blocked leads to (Implement in the default
  flow). First Symphony comments `## Unblocked` on it, listing each blocker with its link, its
  PRs and its Agent Factory summaries; the next run starts from that comment, with the other
  repos refreshed.
- A blocker that was **cancelled**, or a Blocked issue with **no** blocking links, still waits for
  a person. Symphony unblocks an issue once per set of blockers, so moving it back to Blocked by
  hand keeps it there.

## People in the loop

A flow decides where people step in. Common gates:

- **Plan review**: an agent posts a plan; a person approves it (move to Implement) or comments
  and sends it back to Plan.
- **Human review**: after the AI review, a person reviews the PR, merges it, and moves the issue
  to Done, or comments and sends it back to Implement.
- **Approval on a stage**: the agent's move out of the stage is held (the issue carries an
  approval label) until a person approves it or sends it back (`review_issue`).
- **Blocked**: needs a person, unless the issue is blocked by other Linear issues: then Symphony
  moves it back to work once they are all done (a cancelled one still needs a person).

To find work waiting on you: `list_issues` (each issue shows its stage), or
`list_issues` with `awaiting_approval: true` for held moves.

## Using this MCP

Every tool is limited to what your token allows. Read tools look; write tools change things
and need a read-and-write token.

Read:
- `get_manual`: this manual, or one section of it.
- `symphony_status`: agents running and retrying, capacity, polling, rate limits, restarts.
- `list_flows`: the flows you can see, which flow each team or project uses, and whether you
  may edit it.
- `get_flow`: a flow's full definition (stages, settings, transitions), the issues in each
  stage, and its version.
- `list_issues`: issues Symphony tracks, by flow, stage, or waiting for approval.
- `get_issue`: one issue's stage, move history, live session and messages to its agent.
- `get_transcript`: what an issue's agents did: messages, commands with output, edits, turns.
- `list_projects`: the Linear projects Symphony listens to, their primary repo and other `repos`,
  and where each was defined (config file or MCP).

Write:
- `save_flow`: replace a flow's definition. Pass the `version` you read; if someone saved since,
  nothing is written and you get the current version back to redo your change.
- `set_stage_control`: pause a stage, cap its agents, set its harness or effort, or turn on
  approval, without editing the whole flow.
- `set_autopilot`: turn earned autonomy on or off for a flow.
- `reset_flow`: drop a team's or project's own flow so it inherits again.
- `move_issue`: move an issue along a connection in its flow.
- `review_issue`: approve or send back an issue whose move is held for approval.
- `send_agent_message`: tell the agent on an issue something; it arrives in the running turn
  (Codex) or at the start of the next one.
- `refresh`: poll Linear now instead of waiting for the next tick.
- `add_project` / `remove_project` (admins): choose which Linear projects Symphony works on, and
  their repos (`repos`). Adding a project that already exists updates it.

What you can see and change follows your Linear teams: members work in their teams' flows and
issues, admins in everything. Tokens can be narrowed further to chosen teams or projects.
Changes to flows apply to the next stage an agent starts; running agents finish their turn.

## Recipes

**Explain what's happening right now.** `symphony_status`, then `list_issues`; for one issue,
`get_issue` and `get_transcript`.

**Start working a new repo.**
1. Make sure Symphony's GitHub access can push and open PRs on the repo. The repo needs no
   Symphony files.
2. If its workspaces need setup (installing dependencies, say), that goes in the `hooks` of
   Symphony's config file; ask whoever runs Symphony. Projects added here get the top-level hooks.
3. Create a Linear project for it in the team whose flow should apply.
4. `add_project` with the project's URL and the repo (`owner/name`), plus `repos` if its work
   spans several.
5. File an issue in the project; it starts on the next poll.

**Change what agents are told.** For one stage: `get_flow`, edit that stage's `instructions` (or
its skill or checks), `save_flow`. It applies from the next stage an agent starts. The standing
instructions in the agent prompt (workpad, PRs, follow-ups) are Symphony's; a project in the
config file can replace them with its own prompt file.

**Change a flow.** `get_flow`, edit the `definition` (stages, their settings and instructions,
transitions), then `save_flow` with the `version` you read. Stage ids are lowercase letters,
digits and dashes; every stage needs a Linear state, and stages sharing a state need different
labels. Missing `factory/*` labels are created in Linear for you.

**Add a human checkpoint.** Add a stage of kind `human` (its own label, usually in the In Review
state), point the agent stage's transition at it, and add `human` transitions out of it (for
example approve to the next stage, send back to the previous one).

**Stop agents in one stage for a while.** `set_stage_control` with `field: paused`,
`value: true`; set it back to `false` to resume.

**Unblock an issue.** Read why with `get_issue`, fix the cause (access, a clarified
description), then `move_issue` to the stage its Blocked transitions allow. An issue blocked by
other issues is moved back automatically once they are all done.

**Give a project more repos.** `add_project` again with the same project and repo plus `repos`
(each `repo` as owner/name, optionally `name`, `default_branch` and a `description` saying what
lives there, which agents read when deciding where a problem belongs). For a project in the
config file, add `repos:` there. Then label issues `repo/<name>` to have them worked in that
repo; unlabelled issues go to the primary.

**Follow work that spans repos.** The Blocked issue's summary comment (and its links in
Linear) names the issue blocking it; `get_issue` and `get_transcript` on that blocker show its
progress. When the last blocker is done the Blocked issue moves back by itself, with an
`## Unblocked` comment, and `get_issue` on it shows the move. To take over instead,
`move_issue` it yourself.

**Tell an agent something.** `send_agent_message` with the issue identifier and your message.

## Guardrails

- Agents work only in their own workspace and sandbox, on `symphony/<issue>` branches, and never
  push to the default branch.
- Agents can only make the moves their stage allows; people approve where the flow says so.
- Your MCP token can do what you can do in Symphony, never more, and stops working if your
  account is disabled or loses the access it was limited to. Create and revoke tokens on the
  dashboard's **MCP tokens** page (top-right menu, `/account/mcp`).
- Flow saves are version-checked, so two editors can't silently overwrite each other.
- Projects defined in Symphony's config file can't be changed through MCP; projects added
  through MCP can only point at GitHub repositories, and can't set hooks or prompts (those run
  on Symphony's machines, so they stay in its config file).
- An agent changes only its issue's home repo; it reads the project's other repos and asks for
  changes there through a blocking issue.

## Troubleshooting

- **An issue isn't being picked up.** Check its project is in `list_projects`, its stage is a
  `queue` or `agent` stage (not human, parked or done), the stage isn't paused, and capacity
  isn't full (`symphony_status`).
- **An agent keeps failing in a loop.** Read the latest summaries with `get_issue` and the
  transcript with `get_transcript`; send guidance with `send_agent_message` or move the issue
  to Blocked.
- **A Blocked issue didn't move back.** Check its links in Linear and its history with
  `get_issue`: every blocker must be completed (a cancelled one keeps it Blocked), the blockers
  must be linked as *blocking* it (not just related), its flow needs a connection from Blocked
  to an agent stage, and an issue someone moved back to Blocked by hand after Symphony unblocked
  it stays there. `move_issue` it on.
- **An issue was worked in the wrong repo.** Its `repo/<name>` label picks the repo when its
  workspace is first made. Fix the label, then file a fresh issue (or ask an admin to clear the
  old workspace) so it starts in the right repo.
- **`save_flow` refused.** A version conflict means someone saved first: re-read with
  `get_flow` and redo your change. Validation errors name the field to fix.
- **"Only admins…" or "Only this team's members…".** Your account (or your token's limits)
  doesn't cover that team, project or action.
