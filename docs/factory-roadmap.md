# Factory roadmap

This is the plan for growing Symphony from a factory that runs agents into one that also checks its
own work, measures itself and learns from corrections. The evidence behind it is in
[factory-findings.md](factory-findings.md). Nothing here is built yet.

## Contents

- [How we'll work](#how-well-work)
- [Next steps](#next-steps)
- [Milestones](#milestones)
- [Target flow](#target-flow)
- [What we'll measure](#what-well-measure)
- [Decisions and open questions](#decisions-and-open-questions)
- [Not yet](#not-yet)

## How we'll work

- **Each milestone ships on its own and is useful by itself.** If we stop after any milestone,
  what we built still pays for itself.
- **Pilot before platform.** Try a flow with what Symphony can already do. Build engine features
  only for what the pilot shows actually hurts.
- **Collect data before automating.** Record why work gets sent back, and what happens after merge,
  before building anything that learns from it.
- **Start with one team and low-risk work** (docs, small bugs, fixes from monitoring alerts), then
  widen. This is Warp's rollout advice, and it keeps a broken flow from costing much.
- **Compare against our own baseline.** Vendor numbers aren't comparable with each other, let alone
  with us.
- **People approve every change to the factory itself**: flows, skills and autonomy levels.

## Next steps

These need little or no code and can start now.

1. **Merge these docs** so the plan has one home.
2. **Make the two open decisions:**
   - where specs live;
   - which team and project run the pilot.

   See [open questions](#decisions-and-open-questions).
3. **Start M0** with a test that reproduces the endless retry. The findings came from reading the
   code, so confirm them first.
4. **Record send-back reasons by hand, starting today.** When you send work back, add a Linear
   comment: `Sent back (<category>): <why>`. Categories:
   - agent error
   - spec unclear
   - environment or workflow
   - preference
   - other

   This gives the later learning loop its first data, and it tests whether the categories fit
   before we build them into the dashboard.
5. **Take a baseline for the pilot team** from what Symphony already reports:
   - issues reaching Done per week;
   - knock-back rounds from the factory report posted on each finished issue;
   - cost by stage on the insights page.
6. **Experiment with the pilot flow before building anything.** Over MCP (`get_flow`, `save_flow`),
   give the pilot project its own flow with:
   - a human spec-review checkpoint;
   - a code-review agent stage with its own instructions and a different harness from Implement.

   Write down where the implement-shaped base prompt gets in the way. That list is the input for M2.

## Milestones

| | Milestone | Ships | Done when | Size | Needs |
|---|---|---|---|---|---|
| M0 | Stop runaway runs | Retry and time limits, with a parked stage and a comment when they run out | An issue that fails forever stops after N runs and says why | Small | none |
| M1 | Record why | Reasons on send-backs, an event log, flow history | Every pilot send-back has a reason the next agent reads; flow edits can be listed and reverted | Medium | none |
| M2 | Pilot the full flow | Stage roles and the "full factory" template | One team has run about 20 low-risk issues through it, and we've read every send-back | Medium | M1 |
| M3 | Scorecard | Weekly factory numbers per team, stage and flow revision | The pilot's numbers sit next to its baseline | Medium | M1 |
| M4 | Evidence and review artifacts | Uploaded evidence, posted review findings, locked acceptance criteria | A reviewer can approve from the evidence table without rerunning anything | Medium to large | M2 |
| M5 | Learning loop | Proposed flow and skill changes, approved by a person | A proposal backed by repeated corrections has been applied and its effect measured | Large | M1, M3 |
| M6 | Rolling trust | A trust score per stage instead of an approval streak | Autonomy is earned and lost from recent results, and logged in shadow for risk lanes | Medium | M1, M3 |

Sizes are rough and only meant for comparison. M3 and M4 can swap places if the pilot shows that
evidence is the bigger pain.

### M0: stop runaway runs

**Why.**
- The attempt counter has no maximum, and backoff levels off at 5 minutes.
- A run that ends without writing `result.json` is dispatched again a second later with the attempt
  reset to 1.
- An issue that fails the same way every time keeps spending tokens until a person notices.

**Scope.**
- Separate retry budgets per cause: crash or stall, no result, CI failure, review loop.
- When a budget runs out:
  - post a `## Factory stopped` comment (reason, last error, attempts, cost);
  - move the issue to a parked stage it can reach;
  - if the flow has none, hold it out of dispatch until its stage changes.
- A time limit per stage.
- An optional cost ceiling per issue, with warnings at 50% and 80%.
- When a status is unknown, stop rather than carry on.

**Where.**
- `Orchestrator.schedule_after_run_exit/4` and `schedule_issue_retry/4`
- `RetryStore`
- `Config.Schema`

### M1: record why

**Why.** Every later step depends on knowing what happened and why. Today a send-back carries no
reason, a move records no actor, and a flow edit overwrites the previous version.

**Scope.**
- **Reasons.** `review_issue` and `move_issue` take a reason, required for send-backs and backward
  moves. The dashboard asks for one. The reason has a category and free text, and it goes into the
  Linear move comment so the next agent reads it.
- **Event log.** A `FactoryLog` stored through `StateStore`, recording:
  - moves, with actor, reason, flow revision, skill revision and model;
  - approvals held and decided;
  - rejected stage results;
  - run ends, with cost;
  - runs stopped by M0;
  - moves people make directly in Linear;
  - issues reopened after Done.

  The `UsageLedger` move tuples stay as they are, because the MCP tools and the reload code depend
  on their shape.
- **Flow history.** A content `revision` that only edits bump. Approvals and stage toggles leave it
  alone, unlike today's `version`. Each edit is snapshotted, and new MCP tools read the history and
  revert to a revision.

### M2: pilot the full flow

**Why.** Today's base prompt assumes every agent stage implements and opens a PR, so triage, spec,
review and verify stages fight it.

**Scope.**
- A `role` field on stages (implement, triage, spec, review, verify) that picks the base prompt
  body. The hand-off text only tells code-writing roles to commit and push.
- A built-in "full factory" template that a team adopts through MCP (`apply_template`).
  `DEFAULT` doesn't change.
- Instructions and skills for each new stage, taken from the patterns in the findings:
  - triage reproduces and searches before deciding;
  - specs number their behaviours;
  - review only loops back on blocking findings;
  - verify maps each criterion to evidence.
- For now, evidence is linked from the PR description.
- The pilot's image includes Playwright, a browser and ffmpeg. Per-stage images don't work yet.

**Out of scope.** Uploads, `review.json` and locked criteria all wait for M4.

### M3: scorecard

**Scope.** A `FactoryMetrics` module over the event log, by team, stage, flow revision and model:
- shipped issues;
- cycle time;
- time waiting at human stages and for approval;
- people's touches by type, with estimated minutes;
- token cost;
- knock-back rate and first-pass yield per stage;
- reopens within 7 and 30 days;
- runs stopped by M0.

It's shown on `/insights` and through an MCP `factory_metrics` tool. Every number shows its sample
size, and no verdict is drawn below a minimum.

### M4: evidence and review artifacts

**Scope.**
- **Evidence.** `result.json` can list files under `.symphony/evidence/`. Symphony checks the type
  and size, uploads them to Linear, and adds an evidence table to the stage comment. Videos are
  checked to make sure they actually play.
- **Review findings.** The review stage writes `review.json` (find, verify each finding, rank).
  Symphony posts it to the PR as a review that never approves or blocks. Only blocking findings send
  work back, for at most two rounds; after that a person decides.
- **Locked criteria.** Approving a spec snapshots its acceptance criteria into `criteria.json`.
  Later stages may only change each criterion's status and evidence, and Symphony rejects results
  that change anything else.
- **PR size guard.** A check that sends oversized PRs back to be split.

### M5: learning loop

**Scope.**
- **Proposals.** A proposal is a set of typed edits (add, change or delete a rule in a stage's
  instructions, skill, checks or transition criteria), with links to the corrections behind it.
  Proposals live in the flow store. A person approves one in the dashboard or over MCP, which
  applies it as a new flow revision.
- **Observer.** An `improve-flow` skill for a coding agent, run weekly. It reads corrections per
  stage and proposes only when the same correction has come up at least three times from at least
  two people. One person's preferences become a team note instead. It looks for rules to delete as
  well as rules to add, and never edits a stage's output format.
- **Effect.** Each applied proposal shows the stage's numbers before and after its revision.

### M6: rolling trust

**Scope.**
- A new autopilot mode: acceptance over the last N decided moves of a stage, using a lower
  confidence bound with a minimum sample.
- It promotes and demotes with a margin between the two, so a stage doesn't flap.
- It demotes immediately on a revert or incident.
- It starts over when the stage's flow revision or model changes.
- Streak mode stays for existing flows.
- For each human review we log whether the change would have qualified to skip it, which is the
  data a future risk lane needs.

## Target flow

The "full factory" template that M2 adds (opt-in):

| Stage | Kind | What happens |
|---|---|---|
| Todo | queue | Waiting to be picked up |
| Triage | agent | Reproduces or investigates, checks for duplicates, and picks one exit with a reason: implement, spec, needs info, ready for a person, later, or close |
| Needs info | human | The reporter answers; the issue goes back to Triage |
| Ready for a person | human | The work needs judgement or access an agent lacks |
| Later | parked | Valid but not now; re-triaged when picked up |
| Closed | done | Duplicate, already done, or rejected; recorded so triage catches repeats |
| Spec | agent | Writes the product spec (numbered behaviours, acceptance criteria) and, when needed, the tech spec. Small issues get a short spec |
| Spec review | human | A person approves the spec or sends it back with a reason |
| Implement | agent | Builds and checks the change, opens the PR, and keeps a decision log |
| Code review | agent | Reviews the diff against the spec. Blocking findings go back to Implement, at most twice |
| Verify | agent | Proves each acceptance criterion from the user's side and attaches the evidence |
| Review | human | A person reviews the PR, the evidence and the decision log |
| Rework, Merge, Blocked, Done | as today | |

Some rules hold whatever the autonomy level:
- an agent never approves its own PR;
- each run pushes to one branch;
- review and verify instructions come from the flow, never from the branch under review.

## What we'll measure

| From | Numbers |
|---|---|
| Now (baseline) | Issues done per week, knock-back rounds per issue, cost per stage |
| M0 | Runs stopped by a limit, and why |
| M1 | Send-backs by category and stage |
| M3 | The full scorecard (see M3), per team, stage, flow revision and model |
| M5 | Each proposal's effect on its stage |

We won't reduce the factory to one efficiency number. Tokens are a small share of what work costs,
and one number invites gaming. The scorecard keeps throughput, quality, cost and people's time side
by side.

## Decisions and open questions

**Decided**
- The full flow is an opt-in template. `DEFAULT` stays as it is.
- Improvements to flows and skills arrive as proposals in the flow store, approved by a person.
- Verification covers web UIs, backend APIs, and libraries and CLIs.
- Autopilot gets a rolling-trust mode (M6).
- The replay bench and Linear agent sessions come later.

**Open**
- **Where do specs live?** Repo files reviewed in a PR (`specs/<issue>/PRODUCT.md` and `TECH.md`,
  as Warp, Spec Kit and Kiro do), or the spec stage's comment on the Linear issue? Repo files are
  versioned with the code and can be checked against the diff. A comment is easier to read in
  Linear.
- **Which team and project run the pilot?**
- **Which model reviews by default?** The findings suggest the strongest available, which isn't
  necessarily one from a different vendor.
- **Who may approve factory proposals?** Team admins, or admins only?

## Not yet

| Idea | Why it waits |
|---|---|
| Replay bench (rerun past issues against a new flow revision before approving it) | The strongest way to judge a change, but a large build. Live numbers from M3 come first |
| Linear agent sessions | They fit the stage model well, but they change how people interact with the factory. Better after the flow has settled |
| Skipping human review for low-risk changes | Needs M6's shadow data first, plus an answer on SOC 2 change approval |
| Per-stage container images | The Docker sandbox reuses an issue's first container, and Kubernetes pods ignore environments; fixing both is its own project |
| An observer that runs inside the factory | Needs Symphony to create Linear issues, which it can't today. Running the observer from a coding agent comes first |
| Keeping transcripts after a restart | Only needed once the observer wants more than reasons and comments |
| Moving onto upstream Symphony's tracker interface | Would make upstream merges cheaper. Worth doing separately |
