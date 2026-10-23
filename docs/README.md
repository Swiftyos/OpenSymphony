# Docs

- [Architecture](architecture.md): what Symphony is made of, how an issue moves through it,
  durability, launchers, security, observability, scaling and configuration.
- [Software factory findings](factory-findings.md): how Symphony compares with the "software
  factory" model, and what other teams and vendors do for triage, specs, review, verification,
  self-improvement, metrics and autonomy.
- [Factory roadmap](factory-roadmap.md): next steps and milestones for growing Symphony into a
  factory that checks its own work, measures itself and learns from corrections.

Implementation docs for the Elixir app live in [`elixir/docs/`](../elixir/docs/):

- [Durable runs](../elixir/docs/durable-runs.md): runners, the run host, run registry, outbox
  and tracing.
- [Capacity metrics](../elixir/docs/capacity.md): what the capacity metrics mean and how to
  size a deployment.
- [Token accounting](../elixir/docs/token_accounting.md): how agent token usage is counted.
- [Logging](../elixir/docs/logging.md): logging conventions.

Also see [`elixir/README.md`](../elixir/README.md) for setup and configuration, the
[MCP manual](../elixir/lib/symphony_elixir_web/mcp/manual.md), and [`SPEC.md`](../SPEC.md).
