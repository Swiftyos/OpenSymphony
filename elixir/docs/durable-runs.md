# Durable runs: agent runs that outlive the controller

Status: design, implemented in steps (below). Goal: restarting or deploying Symphony never
kills a running agent, and no run state is lost. This is Phase 2 of moving Symphony to
Kubernetes; on the VM it removes the need for drain-then-restart deploys.

## Today

`Orchestrator` starts each run as a `Task` under `SymphonyElixir.TaskSupervisor`
(`AgentRunner.run/3`) and monitors it. The agent CLIs (Codex, Claude Code, OpenCode) are OS
child processes of the BEAM, opened as Ports. A restart therefore kills every run. The run
talks to the controller in-process:

| Need | Today |
|---|---|
| Runtime info (workspace, host) | `send(orchestrator, {:worker_runtime_info, ...})` |
| Agent events (tokens, activity, rate limits) | `send(orchestrator, {:codex_worker_update \| :agent_worker_update, ...})` |
| Transcript | `Transcript.record/3`, `note/2`, `turn_started/2` (ETS in the controller) |
| Dashboard messages | `AgentInbox.register_runner/2`, `take_queued/1`, `queued?/1`, steering via its Registry |
| Session resume | `SessionStore.get/put/delete` |
| Run finished | the Task's `:DOWN` reason |
| Linear writes | `Tracker` / `StageResult` directly |

## Target

A run is a **runner**, a separate OS process (`symphony runner`) started by a **launcher**.
Each runner owns its agent CLIs and its turn loop, and survives controller restarts. It talks
to the controller only through a **run host** interface:

- In-process (`RunHost.Local`): today's calls. Used by the `local` launcher and in tests.
- Over HTTP (`RunHost.Remote`): `POST /runner/v1/runs/:id/events` (batched, at-least-once,
  deduplicated by `(run_id, attempt, seq)`), `GET /runner/v1/runs/:id/commands?after=` (long
  poll), `GET/PUT/DELETE /runner/v1/runs/:id/session`. Each run has a bearer token (an HMAC of
  run id and epoch under a controller secret). A request with a stale epoch gets `409`, and the
  runner stops: that is the fencing.

The controller keeps a **run registry** (`~/.symphony/runs.json` through `StateStore`). It
holds run id, issue, attempt, epoch, launcher reference, started_at and last_seen_at. On start
the orchestrator adopts every registered run still alive. Each adopted run goes back into
`running`, with heartbeats in place of a process monitor. A run whose heartbeat lapses past
`agent.stall_timeout_ms` is treated as `:DOWN` (stalled), and its attempt is retried.

Runners keep an **outbox** (`<run dir>/outbox.jsonl`) of unacknowledged events. While the
controller is down they keep working and buffer. When it is back they replay the outbox, and
the controller applies each event once.

Linear writes stay in the runner (on the VM it has the same Linear key). They are idempotent
(see "Idempotent Linear writes" in README.md), so a replay after a crash is safe. On
Kubernetes they move behind a tool gateway.

## Steps

1. **Run host seam (no behaviour change).** `AgentRunner` and the backends talk to the
   controller only through a `SymphonyElixir.RunHost` behaviour passed in opts, defaulting
   to `RunHost.Local`, which makes exactly today's calls.
   Done: `SymphonyElixir.RunHost` (behaviour), `SymphonyElixir.RunHost.Local`
   (`AgentRunner` builds it from its update recipient unless `run_host:` is given, and
   threads it to the backends as `run_host:` in `run_turn` opts).
2. **Run registry and adoption.** Covers run ids, attempts, epochs, the registry document and
   heartbeat-based liveness. The orchestrator records dispatch and completion, and on start
   adopts live runs. It still uses the local launcher.
   Done: `SymphonyElixir.RunLauncher` (behaviour and `launcher/0`),
   `SymphonyElixir.RunLauncher.Local`, `SymphonyElixir.RunRegistry` (`runs.json`), and the
   orchestrator's dispatch/completion recording and `recover_runs/1` (runs cut off by a
   restart are retried within a second with their next attempt).
3. **Runner protocol.** This step adds the runner protocol, still exercised in-process. It has
   four parts:
   - **Run spec.** The controller writes `<state root>/runs/<run_id>/spec.json` (0600). It holds:
     - run id, epoch, attempt and worker host
     - the issue
     - the backend and effort
     - the account by id
     - the controller URL
     - the run token
     The runner re-resolves its issue config and route from the same `symphony.yml` or
     `WORKFLOW.md`.
   - **Runner mode.** `symphony runner <spec>` boots a reduced application: config store,
     task supervisor and the outbox sender, with no orchestrator, HTTP server or dashboard. It
     then runs `AgentRunner.run/3` with `RunHost.Remote` and exits.
   - **`RunHost.Remote`.**
     - *Fire-and-forget calls* (runtime info, agent updates, transcript notes, turn starts) are
       appended to the outbox. A sender process posts them in batches.
     - *Calls that need an answer* (session get/put/delete; inbox take, queued?, get,
       mark-delivered; Codex turn) are synchronous HTTP calls with a short retry. If the
       controller is unreachable, session and inbox reads degrade to nil or empty.
     - *Pure helpers* (`prompt_section`, `steer_text`) are called directly.
     - *Steering:* a command long-poll delivers `{:agent_inbox, id}` to the process that
       registered for the issue in the runner.
     - *Payloads:* agent events carry atoms and DateTimes, so event payloads are Erlang terms.
       They are sent as `term_to_binary` (base64) and decoded with `[:safe]`. The runner and
       controller run the same release.
   - **Controller endpoints** (`/runner/v1/runs/:run_id/...`).
     - *Auth:* a bearer token equal to `HMAC(secret_key_base, run_id <> ":" <> epoch)`. A stale
       epoch (not the issue's current one in the registry) gets `409`.
     - *Events:* are deduplicated by `seq` and turned into today's orchestrator messages and
       `Transcript` calls. A `finished` event (`normal` or an error) goes to the run's watcher
       (step 4).
4. **Process launcher and watchers.** This step makes runs real processes:
   - **Launcher.** It is selected with `agent.launcher: local | process`. `process` starts
     `symphony runner <spec>` with a command template. The default template detaches the runner
     with `setsid`. On the VM the template is `systemd-run --user
     --unit=symphony-run-{run_id} --collect {symphony} runner {spec}`, outside
     `symphony.service`'s cgroup.
   - **Watchers.** Each process run has a watcher process in the controller (under a
     DynamicSupervisor). The orchestrator monitors that watcher, so its existing `:DOWN`
     handling is unchanged.
     - The watcher exits with the reason from the run's `finished` event.
     - If the runner disappears without one, it exits with `:runner_lost`.
     - Heartbeat events reset the stall clock.
   - **Adoption.** On start, `recover_runs/1` adopts each registered run whose
     `launcher.alive?(ref)`: it starts a watcher and puts the run back in `running`.
   - **Cancellation** stops the systemd unit, or kills the process group.
   - **End-to-end test.** It kills the controller mid-run, restarts it, and checks that the run
     is adopted and completes once.
5. **Kubernetes launcher** (Phase 3): the runner is a pod's entrypoint.
