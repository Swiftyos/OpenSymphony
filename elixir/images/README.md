# Symphony container images

Two images live here:

| Image | Purpose |
|---|---|
| `symphony` | The Symphony controller **and** the runner. Same image; the role comes from the arguments. |
| `symphony-agent-tools` | Only the Codex and Claude Code binaries, for an init container to inject into any team base image. |

Both build from the **repository root**, which is the build context. The root
`.containerignore`/`.dockerignore` keeps `_build`, `deps`, `cover`, `bin`,
`.tmp` and `node_modules` out of it.

```bash
# From the repository root (same as `make images` in elixir/):
podman build -f elixir/images/symphony/Containerfile \
  --build-arg REVISION=$(git rev-parse --short HEAD) -t symphony:dev .
podman build -f elixir/images/agent-tools/Containerfile \
  --build-arg REVISION=$(git rev-parse --short HEAD) -t symphony-agent-tools:dev .
```

Or, from `elixir/`:

```bash
make images
```

`make images` uses `podman`, falling back to `docker` when `podman` is not on
`PATH`, and tags `symphony:dev` and `symphony-agent-tools:dev`. Build for the
target platform explicitly when it differs from the host, e.g.
`podman build --platform linux/amd64 ...`; both images build natively on arm64
and amd64.

## `symphony`: controller and runner

Multi-stage:

- **Build** on the official `hexpm/elixir` image pinned to
  `1.19.5-erlang-28.5.0.5-debian-bookworm-20260824-slim` (Elixir 1.19, OTP 28,
  the same pair as `mise.toml`): `mix deps.get --only prod`, then
  `MIX_ENV=prod mix build` (`mix escript.build`).
- **Runtime** on `debian:bookworm-slim`, with the Erlang runtime copied from the
  same hexpm tag (so `escript` is on `PATH`). Also installed: `git`,
  `openssh-client`, `ca-certificates`, `gh` (GitHub's official apt repo),
  `tini`, and the shared libraries the VM's NIFs use.

The escript embeds Elixir and the application, so the runtime only needs the
Erlang VM. The image runs as the non-root `symphony` user, declared numerically
as `USER 10001:10001` so Kubernetes can verify `runAsNonRoot` (a named user
cannot be checked without a `runAsUser`). `HOME` is `/home/symphony`, and the
workdir is `/srv/symphony`. It exposes `4000`.
`tini` is PID 1 and forwards signals to `symphony`:

```bash
# Controller
podman run -d -p 4000:4000 -v "$PWD/cfg:/cfg:ro" symphony:dev \
  /cfg/WORKFLOW.md --port 4000 \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails

# Runner (the controller writes the spec; see docs/durable-runs.md)
podman run --rm -v /state:/state symphony:dev \
  runner /state/runs/<run_id>/spec.json \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

The dashboard listens on `127.0.0.1` by default, which is unreachable through a
port mapping. Set `server.host: 0.0.0.0` in the config. Any non-loopback host
switches the dashboard to username/password sign-in (`server.auth: accounts`),
so `GET /` answers `302` to `/login` (and on a fresh install on to `/signup`)
instead of `200`; the sign-in/signup page returns `200`.

`REVISION` is recorded in the `org.opencontainers.image.revision` label. The
`source` label points at this repository.

### On GKE

The controller runs one pod with the config mounted read-only and
`server.host: 0.0.0.0` behind the ingress. Runner pods use the same image with
the `runner` argument and a per-run spec written by the controller; they need no
controller state or database credentials. The protocol, fencing and pod layout
are described in [`../docs/durable-runs.md`](../docs/durable-runs.md) (Phase 3,
"Kubernetes launcher"). The image does not include Codex or Claude Code itself:
runner pods get those from the `symphony-agent-tools` init container below.

## `symphony-agent-tools`: agent CLIs for runners

The build stage is `node:22-bookworm-slim`, which installs the pinned npm
packages and keeps only their native binaries:

- `@openai/codex@0.163.0` — the static `codex` binary from
  `@openai/codex-<platform>/vendor/<triple>/bin/codex`.
- `@anthropic-ai/claude-code@2.1.306` — the native `claude` binary from
  `@anthropic-ai/claude-code-linux-<arch>/claude`.

Both are kept in `/agent-tools/bin` inside the image; no Node.js runtime is
needed at run time. The final stage is `busybox` and runs as `USER 10001:10001`
(the same uid as the `symphony` image and the runner pod's `runAsUser`), with
`/agent-tools` readable and executable by any uid. Its entrypoint copies
`/agent-tools` into the directory given as the first argument with `cp -R`, so
the copies belong to the running uid (no ownership is preserved), so it works as an
init container writing to a shared volume mounted at `/opt/symphony`. That's why
the image doesn't keep the tools at `/opt/symphony` itself: the mount would hide
them:

```bash
# Copy into a host directory (smoke test). The image runs as uid 10001, so the
# target must be writable by it (rootless podman: --userns=keep-id, or chmod).
mkdir -p agent-tools && chmod 0777 agent-tools
podman run --rm -v "$PWD/agent-tools:/shared" symphony-agent-tools:dev /shared
ls agent-tools/bin   # claude  codex

# Kubernetes: the volume is mounted at /opt/symphony in the init container and
# in the runner container, so /opt/symphony/bin is already on the runner's PATH.
# The pod sets runAsUser/runAsGroup/fsGroup 10001, so the emptyDir is writable.
#   initContainers:
#     - name: agent-tools
#       image: .../symphony-agent-tools:...
#       args: ["/opt/symphony"]
#       volumeMounts: [{name: agent-tools, mountPath: /opt/symphony}]
```

To update the CLIs, bump `CODEX_VERSION` / `CLAUDE_CODE_VERSION` (or pass them
as `--build-arg`) and rebuild. Pin exact published versions; `latest` is not
used.

### glibc

`codex` is statically linked (musl). `claude` is dynamically linked against
glibc; the current binary runs on glibc 2.28 and newer (verified on
`debian:buster-slim`, `bullseye-slim` and `bookworm-slim`). Arch must match the
image: amd64 images carry the x86_64 binaries, arm64 images the aarch64 ones.

## Base-image contract for team images

The runner image and the init container expect a team base image that is:

- **glibc based** (Debian/Ubuntu or similar, glibc >= 2.28). Alpine/musl is not
  supported for `claude`.
- Equipped with `git` and `bash` (the agent tooling comes from the init
  container, so no Node.js or Erlang is needed). Install the team's own
  toolchain there too.
- Runnable as a non-root **numeric** uid with a **writable `$HOME`** and a
  writable workspace directory. The runner pod runs every container as
  `agent.kubernetes.run_as_user` (default `10001`, also the group and
  `fsGroup`), so `$HOME` must be writable by that uid or its group. The agent
  CLIs write config/state under `$HOME`.
- Willing to mount the init container's volume at `/opt/symphony`, and to put
  `/opt/symphony/bin` on `PATH` (for example
  `ENV PATH=/opt/symphony/bin:$PATH`). Symphony starts `codex` and `claude` by
  name from the workspace.
