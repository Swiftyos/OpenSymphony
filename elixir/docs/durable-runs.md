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
   Done: `SymphonyElixir.RunToken` (HMAC run tokens), `SymphonyElixir.RunSpec`
   (`runs/<run_id>/spec.json`), `SymphonyElixir.RunEvents` (base64 Erlang-term payloads),
   `SymphonyElixirWeb.RunnerAuth` and `SymphonyElixirWeb.RunnerController` (the
   `/runner/v1/runs/:run_id/...` endpoints), `SymphonyElixir.RunnerCommands` (steering queues
   and per-run event/finished bookkeeping), `SymphonyElixir.RunnerCommandPoller`,
   `SymphonyElixir.RunOutbox`, `SymphonyElixir.RunHost.Remote`, `SymphonyElixir.Runner` (the
   reduced runner application and `symphony runner <spec.json>`), and the orchestrator's
   `{:run_finished, ...}` handler (logs until step 4 wires watchers). AgentInbox pushes
   messages to `RunnerCommands` for runners registered as remote; the local path is unchanged.
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
   - **Repo access.** A runner pod has no repo cache. The controller serves each
     project cache read-only at `/git/<run_id>/<repo-key>` over git smart HTTP,
     authenticated by the run token (bearer or HTTP basic with the token as the
     password). The key names a configured repo's cache, never a path. A run may
     read only its own issue's project repo; a run without a project slug may
     read it only when exactly one repo is configured. Receive-pack is refused.
     The endpoint serves the cache as it is, never changes it, and asks the
     background refresher to catch up when it is stale; it never fetches from
     GitHub in the request. Responses stream chunked with an idle timeout
     (`git_mirror.idle_timeout_ms`), git is killed on timeout or disconnect, and
     `git_mirror.max_concurrent` caps concurrent upload-packs (`503` when full).
     The controller adds `git_mirror_url` and `target_branch` to the spec with
     `RunSpec.attach_git_mirror/2`; the runner builds its workspace with
     `SymphonyElixir.GitMirror.clone_commands/3` (init, fetch
     `refs/remotes/origin/*` from the mirror, resume or create the issue
     branch).
   Built:
   - `SymphonyElixir.Kube` is the API client (create/get/delete a pod; create/patch/delete
     a Secret or ConfigMap) over the in-cluster service account or explicit credentials,
     with `Req` `plug:` injection for tests. In-cluster it decodes `ca.crt` into DER
     certificates (`cacerts:`, `verify: :verify_peer`, HTTPS hostname checking against
     the API server host) and re-reads the token file on every request, so a rotated
     projected token is picked up without a restart.
   - **Controller credentials.** The `symphony-controller` service account has
     `automountServiceAccountToken: false`, so the controller Deployment must project a
     token itself, at the standard path (`/var/run/secrets/kubernetes.io/serviceaccount`)
     with `token`, `ca.crt` (from the `kube-root-ca.crt` ConfigMap) and, optionally,
     `namespace`:

     ```yaml
     volumes:
       - name: kube-api-access
         projected:
           sources:
             - serviceAccountToken: {path: token, expirationSeconds: 3600}
             - configMap: {name: kube-root-ca.crt, items: [{key: ca.crt, path: ca.crt}]}
     # container: volumeMounts: [{name: kube-api-access, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true}]
     ```

     The kubelet rotates that token; the client reads it per request. A 401/403 that
     lasts more than five minutes makes the run's monitor exit
     `{:pod_monitor_unauthorized, reason}` instead of retrying forever.
   - `SymphonyElixir.RunLauncher.Kubernetes.PodSpec` renders the run's Secret, ConfigMap
     and pod to the shape the GKE admission policy enforces: `gvisor`, the
     `symphony-runner` service account without a token, the `agents-sandbox` node selector
     and toleration, non-root containers that drop `ALL`, the `symphony.n8n.io/run-id`
     label, and only `run-<run-id>` Secrets and ConfigMaps mounted.
     - **Names.** Resources are `run-<hex(run id)>`: run ids are case-sensitive base64url,
       so lowercasing them could collide. The run-id label is the same hex value and the
       original id is in the `symphony.n8n.io/run-id` annotation. An id whose hex would
       not fit a 63-character label uses `h` plus a SHA-256 prefix.
     - **User.** The pod runs as `agent.kubernetes.run_as_user` (default `10001`) for
       `runAsUser`, `runAsGroup` and `fsGroup`; both images declare `USER 10001:10001`.
       The Secret carries `spec.json` at mode `0440`: the kubelet makes the file group
       `fsGroup`, so uid 10001 can read it while it stays unreadable to others.
     - **Runner config.** The ConfigMap holds the controller's effective config file
       (`symphony.yml` in global mode, `WORKFLOW.md` in legacy mode), mounted read-only at
       `/etc/symphony` and passed as `symphony runner /run/symphony/spec.json
       /etc/symphony/<file>`. Relative paths in it resolve against `/etc/symphony` in
       the pod, and a ConfigMap is not secret: credentials must come from `$VAR`
       references to the environment (`secret_env`), not literals in the file.
     - **Workspace and storage.** The workspace `emptyDir` mounts at the spec's
       `workspace_root` when the spec carries one, else `workspace.root` (a container
       path such as `/workspace` on GKE). `emptyDir.sizeLimit` is
       `workspace_size_limit` (default `20Gi`) for the workspace and
       `agent_tools_size_limit` (`1Gi`) for the agent CLIs; the runner requests
       `ephemeral_storage_request` (`2Gi`) and is limited to `ephemeral_storage_limit`
       (`24Gi`). Set any of them to `""` to leave it off.
     - **Kueue.** The pod carries `kueue.x-k8s.io/queue-name: <queue_name>` (default
       `symphony`, the LocalQueue in `symphony-runs`) so Kueue admits it and counts it
       against the ClusterQueue. Until admitted it stays Pending behind Kueue's scheduling
       gate, possibly for a long time when the queue is full; the monitor never times out
       a Pending pod. `activeDeadlineSeconds` still applies once it runs. Kueue rejects a
       workload that requests a resource its ClusterQueue does not cover, so the
       ClusterQueue must cover `ephemeral-storage` (or Kueue must exclude it) while the
       ephemeral-storage request is set.
     - The agent CLIs come from the `symphony-agent-tools` init container at
       `/opt/symphony`.
   - `SymphonyElixir.RunLauncher.Kubernetes` creates the Secret and the ConfigMap, then
     the pod, returns `"k8s:<namespace>/<pod>"`, polls the pod every 5s from a
     lightweight monitor process, and implements `alive?/1` (pod exists and is
     Pending/Running) and `stop/1` (delete pod, Secret and ConfigMap).
     - A Secret or ConfigMap that already exists (`409`, left by an attempt that crashed
       before its pod) is deleted and created again.
     - Once the pod is created, the Secret and ConfigMap are merge-patched with an
       `ownerReference` to it (its uid from the create response), so garbage collection
       deletes them with the pod even when the controller restarts before cleaning up. A
       failed patch is logged, not fatal.
     - A pod create that fails without an HTTP answer (a timeout) reads the pod back
       first: if it exists the run continues; if not, the Secret and ConfigMap are
       removed; if the read fails too, the pod is deleted as well.
     - The monitor is interim: it exits `:normal`, `{:pod_failed, reason}`,
       `:pod_lost` or `{:pod_monitor_unauthorized, reason}` for the current behaviour's
       monitor, until the process launcher's watcher lands. The failure reason is the
       pod's own (`DeadlineExceeded`, `Evicted`), else the runner container's terminated
       reason and exit code (`OOMKilled (exit code 137)`). On a terminal phase it
       deletes the run's Secret and ConfigMap; the pod stays for its logs.
     - **API load.** One GET per run every 5s is 200 GET/s at 1000 concurrent runs. A
       single pod watch (or informer) over the `app.kubernetes.io/name=symphony-runner`
       label should replace the per-run poll before runs scale that far; a follow-up
       note marks the poll interval in the launcher.
   - `agent.kubernetes` config: namespace, images, CPU/memory requests and limits,
     ephemeral storage and `emptyDir` size limits, `run_as_user`, `queue_name`,
     `active_deadline_seconds` (default 6h), and `secret_env` references to existing
     Secrets. The images are required only when the launcher renders a pod.
   - **RBAC.** The controller Role needs `patch` on `secrets` and `configmaps` for the
     ownerReferences (create/get/delete are already granted).
   Remaining:
   - **Watcher integration.** The interim poller should become the step 4 `RunWatcher`, so
     a pod's completion reaches the orchestrator exactly like a process run and a
     controller restart adopts live pods.
   - **Runner clone from the git mirror.** The controller endpoint and
     `RunSpec.attach_git_mirror/2` are built (see "Repo access" above); the pod's runner
     must still build its workspace with `GitMirror.clone_commands/3` instead of the
     host checkout.
   - **GitHub App tokens.** Per-run installation tokens are not in place yet; `secret_env`
     passes static named credentials. A minter will produce a per-run token and add it to
     the run Secret. There is a TODO at the rendering hook for this.
   - **Janitor.** Nothing removes completed/failed pods yet. Their Secret and ConfigMap
     are cleaned on a terminal phase, by `stop/1`, or by garbage collection with the pod,
     but old pods need a separate sweep.
   - **Pod watch.** Replace the per-run poll with one watch or informer (see API load
     above).
   - **Dispatch wiring.** `RunLauncher.Kubernetes` is self-contained against the current
     behaviour; selecting it for dispatch is left until both branches merge.

## Controller responsiveness

The orchestrator does no tracker (Linear) I/O in its own callbacks. Polls,
per-issue dispatch revalidation, retries and startup terminal cleanup run as
tasks under `SymphonyElixir.TaskSupervisor`, and their results are applied back
in the GenServer against the state at that moment. Only one poll is in flight;
ticks and refresh requests that arrive during it are coalesced.

This keeps the controller responsive as the fleet grows: a slow Linear response
never delays a dashboard `:snapshot`, `/api/v1/state`, or an MCP call such as
`request_refresh`. It also means a crashed fetch is isolated and logged, and the
next tick still polls.

## Environments (Phase 3/4)

Per-project agent environments are resolved by the controller at dispatch, from
the platform catalog plus the repository's `.symphony/environment.yaml`, and the
result is written into the run spec:

```json
{
  "environment": {
    "name": "python",
    "image": "registry.example.com/agents/python:3.12",
    "resources": {"cpu": 2, "memory": "4g"},
    "services": [
      {"name": "db", "image": "registry.example.com/postgres:16",
       "env": {}, "ports": ["5432"], "command": []}
    ],
    "setup": ["pip install -r requirements.txt"],
    "egress_extra": ["api.example.com"],
    "digest": "sha256 of the resolved content",
    "repo_file": true
  }
}
```

`environment` is `null` when the platform has no catalog. On the VM
(`sandbox.kind: docker`) the resolved image and resources replace the sandbox
defaults, each service runs as a sibling container on a per-issue network, and
`setup` commands run once when the container is created; services stop at reap
and are removed with the workspace. The controller owns the bounds: catalog
`resources` are maxima, and repo/service images must match `allowed_images`; a
rejected file fails the dispatch closed.

For Phase 3 the launcher renders this spec directly: the runner pod's main
container uses `environment.image` and `resources`; each service becomes a
sidecar on the same pod network (reachable by its `name`), and `setup` commands
become init containers or a startup script. The digest is the pod/workspace
cache key, so two runs with the same environment can share a prepared volume.
The runner must not re-read `.symphony/environment.yaml`: a runner pod has no
controller or repo-cache state, and the controller's resolution is the one whose
bounds were enforced.

For Phase 4, environment changes are ordinary dispatch changes: the controller
resolves the file at each dispatch, so a merged `.symphony/environment.yaml`
applies to the next run without a controller restart. Changing the catalog
requires a config reload/restart, like other `symphony.yml` platform settings.

## Rules for Phase 3

- **Runners read no controller state.** A runner pod is untrusted and has no database
  credentials. Everything it needs is in its run spec or comes from the `/runner/v1` endpoints.
  That includes the resolved Linear project route, since routes can be added through MCP
  (`ProjectRoutes`).
  - The route comes from `Config.linear_project_route/2` at dispatch. It is a
    `Config.Schema.TrackerProject` struct, or a plain map for the legacy single-project
    fallback, and is stored with `Map.from_struct/1`.
  - The resolved workspace root goes into the spec too. `workspace_root_for_route/3` picks
    `root` or `root/<slug>` by how many routes there are, and a runner can't be relied on to
    count the same routes as the controller.
- **Web and ingest run as several replicas.** Stores that serve requests from a per-node ETS copy
  loaded at boot (`McpTokens`, `ProjectRoutes`) must re-read `StateStore` on a short TTL. That
  is at most about 5s, and token verification falls back to the store on a miss. A revoked token
  then stops working on every replica, including the brief overlap of old and new controllers
  during a rollout. `StateStore` change notifications (Postgres `NOTIFY` on write) can later
  replace the TTL.
- **Each record that several replicas write is its own document.** For example
  `mcp_tokens/<hash>.json` and `project_routes/<slug>.json`.
  - Revoke and remove write tombstones.
  - `last_used_at` lives in a separate document.
  - With one shared document, concurrent writers lose updates: a stale "touch" rewriting the
    document would bring a revoked token back.
  - `StateStore.list/1` already supports this layout on both backends.
