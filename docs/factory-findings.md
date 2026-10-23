# Software factory findings

In October 2026 we compared Symphony with the "software factory" model from Zach Lloyd's talk at
the AI Engineer World's Fair 2026 ("Software Engineering Is Becoming Factory Engineering"; the
slides are titled "Self-Improving Software Factories: The New Open Source Model"). Then we looked at
how other teams and vendors build these systems. This page records what we found.
[factory-roadmap.md](factory-roadmap.md) turns it into a plan.

The code was read at commit `e4f3513`; line numbers may have moved since. External sources are as
of October 2026. Vendor numbers are self-reported unless the text says otherwise, and claims we
only saw in secondary write-ups are marked *(secondary)*.

## Contents

- [The factory model](#the-factory-model)
- [Where Symphony stands](#where-symphony-stands)
- [What others do](#what-others-do)
- [Caveats](#caveats)

## The factory model

Lloyd's thesis is that engineers will spend less time building the product and more time building
and tuning the system that builds it. That system is the software development lifecycle made
explicit as a loop:

```
idea or bug → triage → spec → implement → verify → ship → monitor → back to the top
                        ↑            ↑           ↑
                  human reviews  human reviews  human reviews
                    the spec       the code      the product
```

Agents do the work between steps, and people step in at three gates. His detailed version
branches at triage into four outcomes: implement directly, write a spec, ask a person, or park it.
Monitoring agents file new issues, which closes the loop.

The talk names four components: automation, context and skills, humans in the loop, and
self-improvement. A few points from it shaped this review:

- **Specs come in two parts.** A product spec holds behaviours and invariants. A tech spec holds the
  architecture and the shape of the code.
- **Review is a risk decision.** An agent reviews every change, and a person reviews when the risk
  calls for it.
- **Verification happens from the user's side**, using computer use, with screenshots and video as
  evidence.
- **The factory is measured**: `efficiency = software shipped / (token cost + human cost)`.
- **Every skill gets an outer loop.** An observer agent reads how people corrected the skill's
  output and opens a PR that improves the skill, which a person reviews.

It was a vendor talk. Warp sells the platform it describes, and the talk showed no numbers on
quality or efficiency.

## Where Symphony stands

Symphony already is this kind of factory: it polls Linear, routes each issue through a team's flow
of stages, runs Codex, Claude Code or OpenCode in the agent stages, and stops at human stages and
approval gates. It is strong in the parts the talk calls hard to build, and thin in the parts the
talk says pay off over time.

### Already in place

| Talk | Symphony | Where |
|---|---|---|
| The factory floor is a graph of steps | Flows of `queue`, `agent`, `human`, `parked` and `done` stages, with transitions taken by an agent or a person under stated criteria | [`factory/definition.ex`](../elixir/lib/symphony_elixir/factory/definition.ex) |
| Humans at review gates | `human` stages, and `approval` on an agent stage that holds its move until a person decides | [MCP manual](../elixir/lib/symphony_elixir_web/mcp/manual.md), "People in the loop" |
| When to involve a person is a risk call | Earned autonomy: approvals are required until a stage has N approvals in a row, and a send-back resets the count | `Definition.requires_approval?/2` |
| Context and skills per step | Each stage carries instructions, a skill, shell checks, a harness, an effort level and an environment | [`factory/stage_prompt.ex`](../elixir/lib/symphony_elixir/factory/stage_prompt.ex) |
| Cloud sandboxes, many harnesses | Local, process and Kubernetes launchers; gVisor pods; durable runs that survive a controller restart | [architecture.md](architecture.md) |
| Governance and cost | `Policy`, team-scoped visibility, MCP tokens per person, cost by project, team, task, harness and stage | [architecture.md](architecture.md) |
| A factory dashboard | Live flow per team, what needs a person, per-issue transcripts, messages to running agents | [README](../README.md) |
| Outcome capture | `IssueReport` posts cost per stage and knock-back rounds when an issue is done | [`issue_report.ex`](../elixir/lib/symphony_elixir/issue_report.ex) |

### Gaps

1. **No self-improvement loop.**
   - A send-back records no reason. `review_issue` takes only `approve` or `send_back`, the
     dashboard button sends only the issue id, and `move_issue` has no reason field.
   - Moves record no actor: ledger entries are `[from, to, at]`.
   - Flows keep no history. A save overwrites the single document and bumps `version`, and
     approvals and stage toggles bump it too ([`factory/store.ex`](../elixir/lib/symphony_elixir/factory/store.ex)).
   - Nothing reads corrections and proposes a change to a stage's instructions or skill.
2. **No triage or spec stage.** The default flow is Todo → Implement → In Review → Merge → Done, with
   Rework and Blocked loops (`Definition.default_template/0`). The engine can already express
   triage and spec stages, but the base agent prompt
   ([`priv/prompts/agent.md`](../elixir/priv/prompts/agent.md)) assumes an implement stage: it
   requires a workpad, a reproduction, a PR and a feedback sweep. The hand-off section always says
   to commit and push.
3. **One agent implements, validates and judges its own work.** Nothing reviews the code
   independently, nothing verifies it from the user's side, and no evidence (screenshots, request
   captures) reaches the human gate. Nothing in Symphony uploads files; an agent would have to call
   Linear's `fileUpload` mutation itself through `linear_graphql`, which needs network access.
4. **No efficiency measure.**
   - Usage rows have no timestamps, so cost can't be split by period.
   - Runs don't record which flow version they ran under.
   - Approving a held move leaves no timestamp, so time spent waiting for approval is lost.
   - Transcripts are kept only in memory (400 entries per issue).
5. **No monitoring input.** Nothing turns a production event into an issue. Any alerting tool that
   files Linear issues would already feed the factory, but there is no lane for it. The MCP server
   can't create issues either.
6. **No memory across issues.** Stage comments, the branch, session resume and the transcript are
   all per issue.
7. **Retries are unbounded.**
   - The attempt counter has no maximum ([architecture.md](architecture.md), "Concepts"), and
     backoff levels off at 5 minutes.
   - A run that ends normally without writing `result.json` is dispatched again 1 second later with
     the attempt reset to 1, which repeats until the issue leaves an active state.
   - The only cost limit is a daily token budget per account.
   - We found this by reading `Orchestrator.schedule_after_run_exit/4` and
     `schedule_issue_retry/4`; we have not reproduced it yet.
8. **No evals for flows or skills.** If skills start changing, nothing measures whether a change
   helped.

Two limits matter for any verification stage:
- The Docker sandbox reuses an issue's first container whatever image a later stage asks for.
- Kubernetes runner pods ignore environments entirely.

So the tools a verifier needs (a browser, ffmpeg) have to be in the image the issue starts with.

## What others do

### Factories in production

- **Warp: cloud-factory-demo.** Lloyd's talk links a demo repo; this is almost certainly
  [warpdotdev-demos/cloud-factory-demo](https://github.com/warpdotdev-demos/cloud-factory-demo),
  matched on its README wording (we didn't decode the QR code).
  - Triage applies one label from a closed set: Ready to implement, Ready to spec, Needs info, Wait
    to implement.
  - Spec writes `specs/<issue>/PRODUCT.md` and `TECH.md` in a PR that a person reviews.
  - Review writes `review.json`, and a separate job posts it.
  - `verify-behavior` drives Chrome against the acceptance criteria in PRODUCT.md and attaches video
    and screenshots.
  - The outer loop, `improve-review-pr`, runs daily. It sorts feedback on the bot's reviews, makes
    minimal edits, may not touch the output schema, and opens a PR it never merges.
  - A sibling repo, [issue-triage-loop](https://github.com/warpdotdev-demos/issue-triage-loop),
    stamps each triage comment with the skill version and treats a maintainer relabel as ground
    truth.
- **Warp: factories in practice.**
  - Factories are versioned code with scorers that sample runs for task compliance, procedure
    compliance, verbosity and efficiency
    ([blog](https://www.warp.dev/blog/agent-self-improving-software-factories)).
  - WarpBench replays past tasks against a configuration. Cost per completed PR fell from about $80
    to about $30 and task compliance rose from 69% to 83%, with the merge rate unchanged
    ([case study](https://www.warp.dev/blog/warpbench-case-study-reduce-cost-per-pr)).
  - Rollout advice: start with low-risk chores (Sentry fixes, triage, docs) and a few "factory
    champions" ([blog](https://www.warp.dev/blog/rolling-out-software-factories)).
- **Uber.** The AI Engineer World's Fair talk
  ([page](https://ai.engineer/talks/17-YSUHo6Lk-agentic-sdlc-at-uber-building-blocks-ubers)) and a
  [blog post](https://www.uber.com/us/en/blog/efficient-software-factory/) describe building blocks
  rather than one pipeline:
  - a model gateway, an MCP gateway, dev pods;
  - a skills marketplace whose entries pass lint checks and an eval before release.
  - Their cloud agent stops at a draft PR and runs an inner loop first: static analysis, a simulator
    screenshot compared against the Figma design, integration checks in staging.
  - Review has two tiers: a cheap model first, then a reasoning model.
  - Review outcomes become labelled data for skills.
  - They report that more than 70% of PRs are attributed to agents, that usage grew 7x with flat
    spend, and they track cost per merged PR, revert rate and MTTR.
- **Upstream Symphony.** [SPEC.md](https://raw.githubusercontent.com/openai/symphony/main/SPEC.md)
  is still a scheduler and runner with no stages and no persisted state. Recent upstream work adds
  a generic tracker interface with GitHub, Jira, Asana and GitLab adapters, opt-in labels for
  dispatch, and surfacing input-blocked sessions
  ([commits](https://github.com/openai/symphony/commits/main)).
- **Commercial platforms.**
  - GitHub's cloud agent never approves or merges its own PR, and an agent-authored PR needs one
    extra approval ([docs](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/risks-and-mitigations)).
  - Cursor attaches video, screenshots and logs to PRs, though users report artifacts that fail to
    post or don't play ([blog](https://cursor.com/blog/agent-computer-use)).
  - Jules runs a "planning critic" before code and reports 9.5% fewer failures
    ([changelog](https://jules.google/docs/changelog/2026-01-26-1)).

### Triage and specs

- **No reliable figure exists** for how many real issues are ready for an agent.
- **Matt Pocock's triage skill** ([aihero.dev](https://www.aihero.dev/skills-triage)) is a useful
  pattern:
  - States: needs-triage, needs-info, ready-for-agent, ready-for-human (with the reason an agent
    can't do it) and wontfix.
  - It does a shallow reproduction before asking anything.
  - It records rejected requests so later triage catches repeats.
- **Evidence on issue quality.**
  - Issues that led to merged Copilot PRs were shorter and well scoped, and pointed at the code;
    external dependencies went with lower merge rates
    ([arXiv 2512.21426](https://arxiv.org/abs/2512.21426)).
  - Models are poor at noticing that an issue is underspecified, and asking the reporter improves
    results by up to 74% ([Ambig-SWE](https://arxiv.org/pdf/2502.13069)).
- **Where specs live.** Warp, Spec Kit and Kiro keep specs as files in the repo, reviewed in a PR,
  with a separate always-loaded "constitution" or steering file
  ([Böckeler](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)).
- **How specs are written.**
  - Warp's PRODUCT.md is a numbered list of testable behaviours, and TECH.md cites them by number
    ([skill](https://github.com/warpdotdev/common-skills/blob/main/.agents/skills/write-product-spec/SKILL.md)).
  - Kiro writes requirements in EARS form and links tests to requirement IDs
    ([docs](https://kiro.dev/docs/specs/feature-specs/)).
  - Anthropic keeps acceptance criteria in JSON where only a `passes` field may change, because
    models tamper with Markdown more readily
    ([post](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)).
- **Specs scale down.**
  - Kiro has a quick spec without approval gates.
  - Warp skips specs for trivial fixes.
  - Claude Code's guidance is "if you could describe the diff in one sentence, skip the plan".
  - Over-spec'd small bugs are a known failure.
- No controlled study yet shows that specs raise merge or resolve rates.

### Review and verification

- **Reviewer quality comes from capability, tools and a separate role, more than from a different
  vendor.**
  - In one small study a stronger reviewer improved a weaker model's drafts, while a weaker
    reviewer made a stronger model's drafts worse ([arXiv 2607.21656](https://pith.science/paper/2607.21656)).
  - OpenAI's reviewer caught more with repo access and code execution than with the diff alone
    ([post](https://alignment.openai.com/scaling-code-verification/)).
- **The common shape is find, then verify each finding, then rank, then post.**
  - Claude Code Review posts three severities, never approves or blocks, and reads its rules from
    the base branch only ([docs](https://code.claude.com/docs/en/code-review)).
  - OpenAI posts a comment only when its expected value is positive, so nitpicks often aren't
    posted.
- **Precision is measured by whether findings get acted on.**
  - Authors changed code after 52.7% of OpenAI's comments.
  - Cursor Bugbot reports that 78% of its comments are resolved by merge, and builds rules from
    downvotes, replies and bugs people caught that it missed ([post](https://cursor.com/blog/bugbot-learning)).
  - Independent benchmarks disagree with each other.
- **Verification.**
  - Telling an agent to test as a user would, with browser automation, sharply improved
    Anthropic's results.
  - Playwright MCP records video and traces and has assertion tools
    ([repo](https://github.com/microsoft/playwright-mcp)).
  - Replayable artifacts (scripts, traces, HTTP captures) can be checked later. A video alone can't.
- **Oversized PRs.** "Too large to review" is a rejection reason seen only for agent PRs
  ([arXiv 2602.04226](https://arxiv.org/html/2602.04226v1)).

### Self-improvement

- **Systems that work pair a structured signal with a written reason**, and wait for a pattern to
  repeat:
  - Warp's loop reads label changes plus the maintainer's explanation.
  - Greptile asks for the reason behind a downvote
    ([docs](https://www.greptile.com/docs/code-review/training-the-learning-system)).
  - Devin suggests updates to existing knowledge as well as new items
    ([docs](https://docs.devin.ai/product-guides/knowledge)).
- **Small edits beat rewrites.**
  - ACE grows a context as a playbook of small deltas to avoid "context collapse"
    ([arXiv 2510.04618](https://arxiv.org/abs/2510.04618)).
  - GEPA's reflective prompt evolution beats RL baselines with far fewer rollouts
    ([arXiv 2507.19457](https://arxiv.org/abs/2507.19457)).
  - Reported results on coding skills come from the authors only
    ([gskill](https://github.com/gepa-ai/gepa)).
- **More instructions can hurt.**
  - Repository context files tended to lower task success and raised cost by more than 20%
    ([arXiv 2602.11988](https://arxiv.org/abs/2602.11988)).
  - Instruction-following degrades as rules pile up ([arXiv 2507.11538](https://arxiv.org/abs/2507.11538)).

  An observer has to be able to delete rules as well as add them.
- **Evaluating a change.**
  - Anthropic suggests 20 to 50 tasks from real failures, several trials each, and picking a winner
    on held-out cases ([post](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents),
    [skill-creator](https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md)).
  - Live before/after comparisons need volume. By our calculation, detecting a knock-back rate
    falling from 30% to 20% needs about 290 issues per version.

### Metrics

- **Merge rate alone misleads.**
  - DORA 2025 found AI raises throughput and instability together
    ([summary](https://www.infoq.com/news/2025/09/dora-state-of-ai-in-dev-2025)).
  - Faros saw merged PRs up 98% while review time rose 91% *(secondary)*.
  - Of rejected agent PRs in one dataset, only 36% were clear agent failures
    ([arXiv 2605.22534](https://www.alphaxiv.org/abs/2605.22534.md)).
- **Tokens are a small share of cost.** LinearB puts token spend under 4% of loaded developer cost
  even at P90 ([report](https://linearb.io/resources/ai-engineering-productivity-gap)), so human
  time dominates any efficiency formula.
- **Count only work that sticks.** A useful cost measure counts PRs that merge and survive a churn
  window ([Unblocked](https://getunblocked.com/blog/cost-per-merged-pr)).

### Autonomy and risk

- **Rolling trust instead of a streak.** AWS's graduated autonomy scores agents over a rolling
  window of 50 actions, promotes with a margin, keeps an independent safety floor, and demotes
  immediately on a breach
  ([blog](https://aws.amazon.com/blogs/architecture/closing-the-ai-agent-trust-gap-with-graduated-autonomy/)).
  A plain streak is weak evidence: ten approvals in a row only bound the failure rate below about
  30% at 95% confidence.
- **Skipping review for low-risk changes.**
  - Vercel auto-approves PRs a classifier marks low risk, and reports no reverts across 671 such
    PRs *(from search snippets; the page didn't load)*.
  - Ona has the AI approve while a person clicks merge, to keep a SOC 2 approval event, and treats
    a model swap as a material change ([story](https://ona.com/stories/auto-approving-low-risk-prs)).
  - Whether an AI approval satisfies SOC 2 change management is unresolved with auditors.

### Linear's agent API

Linear models agent work as sessions with activities: thoughts, actions, questions for a person
(elicitations) and responses. A session can also carry a plan checklist, external URLs for the PR,
and team guidance with edit history ([docs](https://linear.app/developers/agent-interaction)).

That maps closely onto Symphony:
- a stage run is a session;
- an approval or needs-info is an elicitation;
- the stage checklist is the plan.

## Caveats

- Most numbers above are self-reported by vendors, or come from single studies with small samples.
  The academic merge-rate datasets disagree with each other. Use them as rough priors and compare
  Symphony against its own history.
- Several sources were read only through secondary summaries or search snippets, and are marked
  as such.
- The software factory model comes from a vendor. The loop, the human gates, and the habit of
  learning from corrections don't depend on any vendor's platform.
