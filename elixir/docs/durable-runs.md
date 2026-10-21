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
3. **Runner process.** Adds the `symphony runner <run spec file>` CLI, `RunHost.Remote` with
   the outbox, the controller's `/runner/v1` endpoints with tokens and epoch fencing, and
   command delivery for dashboard messages and steering.
4. **Process launcher.** `agent.launcher: local | process`. `process` starts runners with a
   command template; on the VM that is `systemd-run --user --unit=symphony-run-{run_id}
   --collect {symphony} runner {spec}`, outside `symphony.service`'s cgroup. It also adds
   cancellation (`systemctl --user stop`) and docs. An end-to-end test kills the controller
   mid-run, restarts it, and checks the run is adopted and completes once.
5. **Kubernetes launcher** (Phase 3): the runner is a pod's entrypoint.
