# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Current capabilities

The experimental Elixir implementation currently supports:

- Codex, Claude Code, and OpenCode as unattended agent backends.
- Multi-project routing from one Symphony instance across multiple repos.
- Repo-local `WORKFLOW.md` files with a global `symphony.yml` runtime config.
- Linear label-based backend switching with labels like `codex`, `claude`, and `opencode`.
- Linear label-based thinking/effort switching with labels like `thinking/high` and
  `thinking/max`.

If you want to try those features, start with [elixir/README.md](elixir/README.md), which now
documents backend support, multi-project setup, and label-routing behavior in detail.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. It includes setup guidance for OpenCode, Claude
Code, multi-project routing, and Linear label-based backend and effort switching. You can also ask
your favorite coding agent to help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
