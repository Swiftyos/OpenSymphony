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
     - the resolved project route and workspace root
     - the account by id
     - the controller URL
     - the run token
     The runner seeds its issue config from the spec's route and workspace root, so it does not
     have to re-resolve a route that may only exist in the controller's stored project routes.
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
   `{:run_finished, ...}` handler (step 4 forwards it to the run's watcher). AgentInbox pushes
   messages to `RunnerCommands` for runners registered as remote; the local path is unchanged.
4. **Process launcher and watchers.** This step makes runs real processes:
   - **Launcher.** It is selected with `agent.launcher: local | process`. `process` starts
     `symphony runner <spec>` with the `agent.runner_command` template. Placeholders are
     `{symphony}` (the escript path, or `SYMPHONY_BIN`), `{spec}` and `{run_id}`, each
     shell-quoted. The default template detaches the runner with `setsid`; on a host without
     `setsid` (macOS) a leading `setsid` runs as `perl -e 'setpgrp; exec @ARGV'`, so the runner
     still leads its own process group. On the VM the template is `systemd-run --user
     --unit=symphony-run-{run_id} --collect --property=KillMode=mixed {symphony} runner
     {spec} --i-understand-that-this-will-be-running-without-the-usual-guardrails`, outside
     `symphony.service`'s cgroup.
     - A backgrounded runner's stdin is `/dev/null` and its output is appended to
       `<run dir>/runner.log`. Dispatch returns as soon as the runner is spawned; the run's
       watcher checks it once after 1s, and a runner already gone (with no `finished`) makes
       the watcher exit `{:launch_failed, log_tail}`. The orchestrator's `:DOWN` handler stops
       and cleans up the run in a task and schedules a failure retry whose error is the log's
       tail.
     - The reference is `process:<pid>:<start time>` (`ps -o lstart=`): `alive?` and `stop`
       treat a pid whose start time differs as another process.
     - The run is recorded in the registry (with a `pending:` reference) before the runner
       starts, so its first events find it; a failed launch deletes it again.
     - `spec.json` (it holds the run token) is deleted when the run ends or is stopped.
   - **Watchers.** Each process run has a watcher process in the controller (under a
     DynamicSupervisor). The orchestrator monitors that watcher, so its existing `:DOWN`
     handling is unchanged.
     - The watcher exits with the reason from the run's `finished` event.
     - If the runner disappears without one, it exits with `:runner_lost` after a 10s grace.
     - Heartbeat events (every 30s) and every other event reset the stall clock; the
       orchestrator also reads the watcher's last-seen time for process runs.
   - **Adoption.** On start, `recover_runs/1` adopts each registered run whose
     `launcher.alive?(ref)` and whose launcher is still available: it starts a watcher, rebuilds
     the running entry from the registry metadata, and puts the run back in `running` without
     bumping the epoch or scheduling a retry. A run that is gone is retried with attempt + 1.
     - A run whose `finished` reason is already in the registry, or whose dead runner left a
       `finished` event in `<run dir>/outbox.jsonl`, has ended: it is deleted and gets exactly
       what the `:DOWN` handler gives that reason (a continuation check for `normal`, a
       failure retry otherwise), and a runner still alive is stopped.
   - **Finishing.** The runner exits only once its `finished` event is acknowledged or the run
     is fenced (`409`, or `404` for a run the controller no longer has). The outbox keeps
     retrying with backoff while the controller is down, for up to
     `agent.runner_finish_flush_ms` (one hour by default).
   - **Lost watchers.** When a process run's watcher goes down for any reason but a normal
     finish, the orchestrator stops the runner before the retry is dispatched. `stop` can wait
     up to 20s, so the orchestrator always runs it in a task under `TaskSupervisor`.
   - **Event progress.** `RunnerCommands` seeds its per-run `last_seq` from `runs.json` after a
     restart, and the controller writes the applied batch's `last_seq` (and the finished reason)
     back to the registry. Every registry write goes through `SymphonyElixir.RunRegistry.Server`,
     so the orchestrator's records and deletes and the endpoints' progress never overwrite each
     other. Progress is coalesced per run and written at most once a second (readers in the
     controller see it at once); a finished reason is written before the batch is acknowledged. A crash between a batch being applied and that one write can still
     replay the batch's transcript entries; it cannot apply a stage result twice because Linear
     writes are idempotent.
   - **Cancellation** stops the systemd unit, or kills the process group (`TERM`, then `KILL`
     after 10s), and stops the watcher.
   - **End-to-end test.** It kills the controller mid-run, restarts it, and checks that the run
     is adopted and completes once. The opt-in test is tagged `:e2e_process` and runs only with
     `SYMPHONY_E2E_PROCESS=1`; the always-on integration tests cover the watcher, adoption,
     event replay and cancellation with a real detached process.
   Done: `SymphonyElixir.RunLauncher.Process`, `SymphonyElixir.RunWatcher` (and its
   `Registry`/`DynamicSupervisor`), `SymphonyElixir.RunSpec` route/workspace fields,
   `SymphonyElixir.RunRegistry` progress and issue metadata, `SymphonyElixir.RunOutbox`
   heartbeats, and the orchestrator's dispatch, adoption, stall and cancellation wiring.
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
     At dispatch the controller adds `git_mirror_url` and `target_branch` to
     every run's spec with `RunSpec.attach_git_mirror/2` when it has the
     cache of the issue's repo. A runner whose host has no cache of that repo
     (a pod) builds its workspace with
     `SymphonyElixir.GitMirror.clone_commands/3` from
     `Workspace.create_for_issue(..., git_mirror: spec)`: init, fetch
     `refs/remotes/origin/*` from the mirror, resume or create the issue
     branch. The run token is only in that script's `GIT_CONFIG_*`
     environment (`http.extraHeader`), never in argv or `.git/config`, and
     `origin` is the repo's real remote, so pushes go to GitHub with the
     agent's own credentials. A host with the cache (the VM, a process
     runner) keeps cloning from it and ignores the mirror. The mirror serves
     only the issue's home repo, so a mirror workspace gets no reference
     repos (`.symphony/repos`).
   - **Controller URL.** A pod cannot use the controller's loopback address.
     The launcher's optional `controller_url/1` callback names the URL its
     runs use: `agent.kubernetes.controller_url` (for example
     `http://symphony-controller.symphony.svc:4000`, required to render a
     pod) for Kubernetes, `http://127.0.0.1:<port>` for the others. The spec's
     `controller_url` and `git_mirror_url` are built from it. Pod egress is
     DNS, the controller's port (runner API and git mirror) and 443.
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
     lasts more than five minutes makes the run's watcher exit
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
       gate, possibly for a long time when the queue is full; the watcher never times out
       a Pending pod. `activeDeadlineSeconds` still applies once it runs. Kueue rejects a
       workload that requests a resource its ClusterQueue does not cover, so the
       ClusterQueue must cover `ephemeral-storage` (or Kueue must exclude it) while the
       ephemeral-storage request is set.
     - The agent CLIs come from the `symphony-agent-tools` init container at
       `/opt/symphony`. It requests `agent_tools_ephemeral_storage_request`
       (`256Mi`) of ephemeral storage explicitly instead of relying on the
       namespace's LimitRange default.
     - **References.** The pod mounts only its own `run-<run-id>` Secret and
       ConfigMap; the only other Secrets it names are `secret_env`'s
       `secretKeyRef`s, which must be on the infra's allowlist of shared
       Secrets.
   - `SymphonyElixir.RunLauncher.Kubernetes` (`agent.launcher: kubernetes`) implements
     `start_process/2`, so `RunLauncher.start/3` and the orchestrator's dispatch hand it
     the run spec like the process launcher. It creates the Secret and the ConfigMap,
     then the pod, and returns the run's `RunWatcher` and `"k8s:<namespace>/<pod>"`.
     - A Secret or ConfigMap that already exists (`409`, left by an attempt that crashed
       before its pod) is deleted and created again.
     - Once the pod is created, the Secret and ConfigMap are merge-patched with an
       `ownerReference` to it (its uid from the create response), so garbage collection
       deletes them with the pod even when the controller restarts before cleaning up. A
       failed patch is logged, not fatal.
     - A pod create that fails without an HTTP answer (a timeout) reads the pod back
       first: if it exists the run continues; if not, the Secret and ConfigMap are
       removed; if the read fails too, the pod is deleted as well. A watcher that cannot
       start (another already holds the run) removes the pod and its objects.
   - **Watcher.** The pod is watched by the step 4 `RunWatcher`, so its end reaches the
     orchestrator exactly like a process run's. `RunLauncher` has an optional
     `status/1` callback: `:alive` (Pending/Running), `{:gone, reason}`,
     `{:unknown, reason}` or `{:unauthorized, reason}`; launchers without it are
     checked through `alive?/1`.
     - The runner's `finished` event (which flows over `/runner/v1`) ends the watcher
       with that reason, as for a process run. A pod that Succeeded or disappeared
       without one ends it with `:runner_lost` after the grace (10s), and a Failed pod
       with `{:pod_failed, reason}`: the pod's own reason (`DeadlineExceeded`,
       `Evicted`), else the runner container's terminated reason and exit code
       (`OOMKilled (exit code 137)`).
     - An API error or an `Unknown` phase is retried at the next poll without starting
       the lost clock; a 401/403 for five minutes exits
       `{:pod_monitor_unauthorized, reason}`. A Pending pod is never timed out.
     - **Adoption.** `recover_runs/1` adopts a registered pod whose status is anything
       but gone: a pod that cannot be checked at boot is adopted too, and its watcher
       decides. A finished run is known from the registry's `finished` reason, which the
       controller writes before it acknowledges the event; the runner exits only after
       that acknowledgement, so a Succeeded pod always has it. (The `outbox.jsonl`
       fallback of process runs reads a local file a pod does not have.)
     - **Cleanup.** A run that ended by itself, or a dead run found at boot, is
       *released* (`release/1`): its Secret (the run token) and ConfigMap are deleted
       and the pod is kept for its logs. `stop/1` (cancellation, a lost or stalled
       watcher) deletes the pod as well unless it has already finished.
   - **Janitor.** `SymphonyElixir.RunLauncher.Kubernetes.Janitor` sweeps every
     `agent.kubernetes.janitor_interval_ms` (5 min) while the launcher is Kubernetes. It
     lists `app.kubernetes.io/name=symphony-runner` pods and Secrets
     (`Kube.list_pods/3`, `Kube.list_secrets/3`), deletes finished pods whose last
     container finished more than `finished_pod_retention_ms` (1h) ago, and deletes
     `run-*` Secrets (and the ConfigMap of the same name) that have no pod and are
     older than ten minutes (a launch creates its Secret just before its pod).
   - **API load.** Each run's watcher GETs its pod every 5s: 200 GET/s at 1000
     concurrent runs. A single pod watch (or informer) over the
     `app.kubernetes.io/name=symphony-runner` label should feed the watchers before runs
     scale that far; a follow-up note marks it in the launcher.
   - `agent.kubernetes` config: namespace, images, `controller_url`, CPU/memory
     requests and limits, ephemeral storage and `emptyDir` size limits,
     `agent_tools_ephemeral_storage_request`, `run_as_user`, `queue_name`,
     `active_deadline_seconds` (default 6h), `finished_pod_retention_ms` (1h),
     `janitor_interval_ms` (5 min), and `secret_env` references to existing Secrets.
     The images and `controller_url` are required only when the launcher renders a pod.
   - **RBAC.** The controller Role needs `patch` on `secrets` and `configmaps` for the
     ownerReferences, and `list` on `pods` and `secrets` for the janitor
     (create/get/delete are already granted).
   Remaining:
   - **GitHub App tokens.** Per-run installation tokens are not in place yet; `secret_env`
     passes static named credentials. A minter will produce a per-run token and add it to
     the run Secret. There is a TODO at the rendering hook for this.
   - **Pod watch.** Replace the per-run poll with one watch or informer (see API load
     above).
   - **Environments on the pod.** The spec's resolved `environment` (image, resources,
     service sidecars, setup) is not rendered into the pod yet; the runner image and
     `agent.kubernetes` resources are used.
   - **Reference repos in a pod.** The mirror serves only the issue's home repo, so a
     multi-repo project's other repos are not checked out in a runner pod.
   - **Recovery detail.** A run found dead at boot is retried as interrupted even when
     its pod Failed; the pod's failure reason only reaches the retry when the watcher
     sees it.
   - **Cluster validation.** Everything here is tested against `Req.Test` stubs; the
     first runs on GKE should check the RBAC above, Kueue admission and the controller
     Service URL.

## Tracing runs

Every run is one trace, from the controller's dispatch through the runner to the
agent CLI. `SymphonyElixir.RunTrace` holds the context and
`SymphonyElixir.TraceExporter` sends Symphony's own spans.

### One trace per run

- **Ids.** The trace id and the root span id are SHA-256 prefixes of the run id.
  A run is one attempt at an issue, so a retry (a new run id) is a new trace. The
  attempts of an issue are grouped by `langfuse.session.id` (the issue identifier)
  and by the `linear.issue.identifier` resource attribute.
- **Adoption.** A controller that restarts and adopts a live run builds the same
  context from the registry's run id. The root span starts at the registry's
  `started_at_unix_ms`. Nothing new is written and no second trace is started.
- **Spans.**
  - `symphony.run` is the root. The controller emits it when the run leaves
    `running`: after a finish, crash, stall or stop, and also for a run recovered at
    boot that had already finished. It is an error for `crashed`/`stalled` and ok
    otherwise, and `symphony.run.outcome` gives the reason.
  - `symphony.dispatch` is the controller starting the run through its launcher.
    It is an error when the launcher refuses.
  - `symphony.agent_run` is `AgentRunner.run/3` wherever it runs: a controller
    task for `local`, the runner process for `process` and `kubernetes`. It is a
    child of the root.
  - The agent CLI's spans come next. The CLI gets `TRACEPARENT` naming
    `symphony.agent_run`, so a CLI that reads W3C context from its environment nests
    under it. A CLI that ignores it keeps its own trace ids. Its spans still carry
    the run's resource attributes, so they can be joined by `symphony.run.id` or
    `symphony.trace_id`.
- **Resource attributes.** Symphony's spans and the agent's
  `OTEL_RESOURCE_ATTRIBUTES` carry `symphony.run.id`, `symphony.run.attempt`,
  `symphony.run.launcher` (`local`, `process`, `kubernetes`), `symphony.project`
  (the Linear project slug), `symphony.trace_id`, `linear.issue.id`,
  `linear.issue.identifier` and `symphony.backend`. They sit next to the existing
  `telemetry.resource_attributes`, `symphony.instance` and account attributes.
- **Across the split.** The run spec's `telemetry` map carries `traceparent` (the
  root), `launcher`, and `otlp_endpoint`/`otlp_protocol`. The runner continues the
  spec's `traceparent`. A spec written before this existed (no `telemetry`) gets
  the context derived from its run id, which is the same one. A local run gets the
  same context in-process through `AgentRunner.run/3`'s `:trace` option.

### Where runner pods export

A runner pod cannot reach the controller host's collector (on the VM, agents use
`host.containers.internal:4318`). `agent.kubernetes.otlp_endpoint`, with
`agent.kubernetes.otlp_protocol` (default `http/protobuf`), names the collector
that runner pods use, for example an in-cluster Service:

```yaml
agent:
  kubernetes:
    otlp_endpoint: http://otel-collector.symphony.svc:4318
    otlp_protocol: http/protobuf
```

- The launcher's optional `otlp_override/1` callback (implemented by the
  Kubernetes launcher) puts it in the spec.
- The runner calls `Telemetry.put_otlp_override/1`. From then on that endpoint and
  protocol replace `telemetry.otlp_endpoint` and every per-signal endpoint, for
  the agents (`OTEL_EXPORTER_OTLP_*`, Codex's `-c otel.*`) and for Symphony's own
  spans.
- The pod's runner container also renders `TRACEPARENT`,
  `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_EXPORTER_OTLP_ENDPOINT` and
  `OTEL_EXPORTER_OTLP_PROTOCOL` for anything else in the pod. If no pod
  collector is set, it renders `telemetry.otlp_endpoint`, and with telemetry off
  it renders none of them. `OTEL_SERVICE_NAME` is deliberately not rendered,
  because the agents would inherit it.
- **No credentials.** The endpoint must be a plain `http(s)` URL; one with
  `user:pass@` is rejected. Symphony never renders `OTEL_EXPORTER_OTLP_HEADERS`.
  Langfuse keys and the ClickHouse password exist only in the collector.

### Bounded export from the controller

`TraceExporter` exists so that tracing cannot take the controller down:

- `emit/1` writes to an ETS queue, not to a mailbox, and never blocks or raises.
- The queue holds at most `telemetry.span_max_queue_size` spans (2048). A span
  emitted while the queue is full is dropped and counted.
- Every `telemetry.span_export_interval_ms` (5 s) the exporter posts batches of up
  to `telemetry.span_max_batch_size` (512) as OTLP/HTTP JSON. Each request is
  bounded by `telemetry.span_export_timeout_ms` (5 s) and is not retried. A failed
  batch is dropped and counted.
- `TraceExporter.stats/0` returns the queued, dropped, exported and failed-batch
  counts.
- The runner flushes before it exits.
- `telemetry.symphony_spans: false` turns Symphony's spans off and leaves the
  agents' export alone.
- The exporter speaks OTLP/HTTP only. With a `grpc` protocol and no HTTP
  `otlp_traces_endpoint`, its spans are dropped and a warning is logged once.

At 1000 concurrent runs averaging 30 minutes, about 0.6 runs end per second. Each
run makes three Symphony spans, so the total is under 2 spans/s. The queue holds
more than 15 minutes of them while a collector is down.

### Volume at 1000 agents

These figures are planning estimates. The assumptions are listed so they can be
replaced with measurements (see the queries below).

| Per agent turn (about 4 min, 25 model requests, 25 tool calls) | Claude Code | Codex |
| --- | --- | --- |
| spans | ~75 (interaction, llm_request, tool, tool.execution) | ~100-300 (session_loop and handlers) |
| log events | ~75 (api_request, tool_result, tool_decision, user_prompt) | ~50 |
| metric points | ~30 per 60 s export | ~30 per 60 s export |

- Per agent: about 0.3-1 span/s and about 0.3 log records/s. Size is about 1 KB
  per span or record on the wire with `log_user_prompts` and `log_tool_details`
  off, and 5-20 KB with them on.
- At 1000 agents, using 1 span/s and 0.5 logs/s per agent as the planning figure:
  - About **1,000 spans/s, 500 log records/s and 500 metric points/s**.
  - About **1.5-2 MB/s** of OTLP, roughly 150 GB/day uncompressed. ClickHouse
    compresses this about 10x, so that is about 15 GB/day, or about 1.4 TB at the
    90-day TTL.
  - Waves of pod starts and prompt/tool logging can push it 3-10x higher: plan for
    **5,000 items/s and 10-15 MB/s** peaks.
- **Requests.** Each CLI batches on its own. Claude Code is the Node SDK: traces
  in batches of up to 512 every 5 s from a 2048-span queue, logs every 5 s
  (`OTEL_LOGS_EXPORT_INTERVAL`), metrics every 60 s
  (`OTEL_METRIC_EXPORT_INTERVAL`). Codex is the Rust SDK, with similar batch
  defaults. Each queue is bounded and drops when full, so a slow collector cannot
  grow an agent's memory. 1000 agents make about 400 export requests/s (traces and
  logs every 5 s, metrics every 60 s). Keep the defaults. Raising the batch delay
  saves requests, but agents that are killed mid-run then lose more.
- **Keep everything; do not tail-sample.**
  - A run's trace lasts as long as the run (minutes to `active_deadline_seconds`,
    6 h), and its root span only arrives at the end. A `tail_sampling` processor
    would have to hold every live run's spans for hours, behind a
    trace-id-sharded load-balancing tier. Langfuse would then see nothing until a
    run ended.
  - ClickHouse absorbs everything cheaply. Keep all of it there.
  - If Langfuse ingestion cannot keep up, sample its pipeline alone with the
    `probabilistic_sampler` processor (it hashes the trace id, so a run is kept or
    dropped whole) or `filter` out tool-internal spans. The dashboard falls back to
    ClickHouse for a trace Langfuse does not have.

To measure instead of estimating, run against the collector's ClickHouse (database `otel`):

```sql
-- spans per second by service over the last day
SELECT ServiceName, count() / 86400 AS spans_per_s FROM otel_traces
WHERE Timestamp > now() - INTERVAL 1 DAY GROUP BY ServiceName;
-- spans per run (needs the run attributes above)
SELECT quantiles(0.5, 0.9)(n) FROM (SELECT ResourceAttributes['symphony.run.id'] AS run, count() AS n
  FROM otel_traces WHERE run != '' AND Timestamp > now() - INTERVAL 1 DAY GROUP BY run);
-- stored bytes per table
SELECT table, formatReadableSize(sum(data_compressed_bytes)) AS stored,
  formatReadableSize(sum(data_uncompressed_bytes)) AS raw
FROM system.parts WHERE database = 'otel' AND active GROUP BY table;
```

Divide by the average number of running agents (`symphony_running_agents` on
`/metrics`) to get per-agent rates.

### In-cluster collector (infrastructure spec)

On Kubernetes, the controller and the runner pods export to a collector in the
controller's namespace (`symphony`). It has the same pipelines as the VM
collector: traces to Langfuse and ClickHouse, and logs and metrics to ClickHouse.

- **Deployment** `otel-collector` in `symphony`:
  - Image `otel/opentelemetry-collector-contrib`, pinned by digest to the VM's
    version.
  - Two replicas (HPA 2-4 on 70% CPU), a PodDisruptionBudget of `minAvailable: 1`,
    and anti-affinity across nodes.
  - Each replica requests `cpu: 1, memory: 2Gi` with limits `cpu: 2, memory: 3Gi`.
    That covers the 5,000 items/s peak with headroom: one core handles about
    10,000 spans/s through batch plus the ClickHouse exporter.
  - Non-root (`runAsUser: 10001`), read-only root filesystem, all capabilities
    dropped, `RuntimeDefault` seccomp.
  - `automountServiceAccountToken: false`, with no RBAC.
  - Probes on the `health_check` extension at `:13133`.
  - Credentials come from a CSI-mounted secret volume at
    `/var/run/secrets/otel` (`langfuse-otlp-auth` holding
    `Basic base64(public:secret)`, and `clickhouse-password`). Config reads them
    with `${file:...}`, so they are never in a ConfigMap, a pod spec or a run
    spec.
- **Config:**

```yaml
receivers:
  otlp:
    protocols:
      grpc: {endpoint: 0.0.0.0:4317}
      http: {endpoint: 0.0.0.0:4318}
extensions:
  health_check: {endpoint: 0.0.0.0:13133}
processors:
  memory_limiter: {check_interval: 1s, limit_mib: 2400, spike_limit_mib: 500}
  batch: {send_batch_size: 2048, send_batch_max_size: 4096, timeout: 2s}
exporters:
  otlphttp/langfuse:
    traces_endpoint: ${env:LANGFUSE_URL}/api/public/otel/v1/traces
    headers:
      Authorization: ${file:/var/run/secrets/otel/langfuse-otlp-auth}
      x-langfuse-ingestion-version: "4"
    retry_on_failure: {enabled: true, max_elapsed_time: 300s}
    sending_queue: {enabled: true, queue_size: 100}
  clickhouse:
    endpoint: ${env:CLICKHOUSE_ENDPOINT}   # tcp://host:9000?dial_timeout=10s
    database: otel
    username: otel
    password: ${file:/var/run/secrets/otel/clickhouse-password}
    create_schema: true
    ttl: 2160h
    timeout: 10s
    retry_on_failure: {enabled: true, max_elapsed_time: 300s}
    sending_queue: {enabled: true, queue_size: 100}
service:
  extensions: [health_check]
  pipelines:
    traces:  {receivers: [otlp], processors: [memory_limiter, batch], exporters: [otlphttp/langfuse, clickhouse]}
    logs:    {receivers: [otlp], processors: [memory_limiter, batch], exporters: [clickhouse]}
    metrics: {receivers: [otlp], processors: [memory_limiter, batch], exporters: [clickhouse]}
```

  - `queue_size` counts batches. 100 batches of up to 4096 items bound each
    exporter's queue to about 400 MB, and `memory_limiter` refuses data
    (receivers return 503/`RESOURCE_EXHAUSTED`, and the SDKs drop) before the
    limit is reached.
  - Only one collector replica creates the ClickHouse schema in practice. It is
    idempotent.
- **Service** `otel-collector` in `symphony`: ClusterIP, ports `otlp-grpc`
  4317 and `otlp-http` 4318, selecting
  `app.kubernetes.io/name: otel-collector`.
- **NetworkPolicy:**
  - Add an egress rule to `symphony-runs-default-deny`: to the `symphony`
    namespace, pods `app.kubernetes.io/name: otel-collector`, TCP 4317 and 4318.
    Runner pods then reach only DNS, the controller on 4000, the collector, and
    the internet on 443.
  - Add an ingress policy `otel-collector-ingress` in `symphony` for those pods:
    from pods in `symphony` (the controller) and from `symphony-runs` pods
    `app.kubernetes.io/name: symphony-runner`, on TCP 4317 and 4318. The
    namespace's default deny covers everything else, including the health port.
  - The collector's egress needs to reach Langfuse (HTTPS or HTTP on its port) and
    ClickHouse (native 9000). If those stay on the VM, that means a firewall rule
    from the cluster's pod range to the VM on those ports, and ClickHouse 9000
    published on the VM's internal address (today only Langfuse 3000 and OTLP are
    published).
  - The simpler interim option is a gateway: the in-cluster collector's only
    exporter is `otlphttp` to the VM collector on 4318, which needs one firewall
    port. The VM collector's `memory_limiter` (800 MiB) and queues must then be
    raised to the sizes above.
- **Symphony config** on the controller:
  - `telemetry.otlp_endpoint: http://otel-collector.symphony.svc:4318` and
    `otlp_protocol: http/protobuf`, used by the controller's own spans.
  - `agent.kubernetes.otlp_endpoint: http://otel-collector.symphony.svc:4318`,
    which only needs setting when it differs from `telemetry.otlp_endpoint`.

## GitHub App token hardening

With `github_app` configured, a runner gets a short-lived installation token
limited to its issue's repository. The controller writes only the run's normal
spec; the token is not persisted in `spec.json`, logs, or transcripts.

- The token is delivered in the agent's process environment (`GH_TOKEN`, plus
  a `GIT_CONFIG_*` `http.<host>.extraHeader`). It is never put in argv,
  `.git/config`, or workspace scripts, and token-shaped strings (`ghs_`,
  `ghp_`, `github_pat_`, JWTs, PEM private keys, `Basic`/`Bearer`
  authorization values) are redacted from logger output and transcripts.
- On an ssh worker host the agent's environment (the token, the Linear API key,
  account credentials) is not in the ssh command line: the remote shell reads
  one escaped line per variable from ssh stdin (`IFS= read -r NAME`), exports
  it, and then `exec`s the agent, which reads its protocol from the rest of
  stdin. Repo cache syncs on worker hosts send their script and env over ssh
  stdin too.
- Repo cache syncs, for the home repo and multi-repo reference repos alike,
  mint read-only tokens (`contents`/`metadata: read`); write permissions only
  reach the agent, and only for its home repo.
- Agents get a token with at least 50 minutes left (a cached token closer to
  expiry is replaced); workspace syncs accept one with five minutes left.
- `SymphonyElixir.GitHubApp.token_for_run/2` resolves a fresh token from a run
  spec. **TODO:** expose it as a `/runner/v1/runs/:run_id/github-token`
  endpoint, authenticated like the other runner endpoints, so a run that
  outlives its token can refresh the environment for later turns. Until then a
  run that outlives its token fails its authenticated git/`gh` operations and
  is retried; the retry mints a fresh token.
- Permissions are an allowlist (`contents`, `pull_requests`, `metadata`,
  `issues`, `checks`, `statuses`; `read` or `write`), checked at config load
  and again for every token request, so a compromised run cannot change CI
  definitions, secrets, or the app installation. An empty map is refused
  because GitHub would grant every installation permission.

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
       "env": {}, "ports": ["5432"], "command": [],
       "resources": {"cpu": 1, "memory": "1g"}}
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
defaults, each service runs as a sibling container on a per-issue `--internal`
network (the agent keeps `sandbox.network` and joins it too, so services never
widen egress), and `setup` commands run once, under `hooks.timeout_ms`, when the
container is created; services stop at reap and are removed with the workspace.
The controller owns the bounds: catalog `resources` are maxima, repo/service
images must match `allowed_images`, services are capped by `max_services` and
each carries its `resources` (bounded by the catalog's `service_resources`); a
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
