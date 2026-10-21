defmodule SymphonyElixir.AgentPrompt do
  @moduledoc """
  The prompt Symphony gives a project's agents when the project has no
  repo-local `WORKFLOW.md`: the issue, the ground rules for working unattended,
  the Linear workpad and follow-up conventions, and the PR hand-off.

  `SymphonyElixir.PromptBuilder` appends the stage section (instructions, skill
  and allowed moves from the issue's flow) and, for a multi-repo project, the
  repositories section. A project can replace this template with its own file
  (`prompt:` on its `symphony.yml` entry).

  The template is compiled in from `priv/prompts/agent.md`, so it works from
  the escript too.
  """

  @path Path.expand("../../priv/prompts/agent.md", __DIR__)
  @external_resource @path
  @template File.read!(@path)

  @spec template() :: String.t()
  def template, do: @template
end
