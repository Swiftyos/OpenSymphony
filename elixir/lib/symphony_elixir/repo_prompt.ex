defmodule SymphonyElixir.RepoPrompt do
  @moduledoc """
  The "repositories" part of an agent's prompt, for a Linear project with more
  than one repo (`repos:` on its route).

  Each issue is worked in exactly one repo, its home repo: the one its
  `repo/<name>` label names, else the project's primary repo (a label naming
  no repo of the project stops the issue instead, `SymphonyElixir.RepoLabelCheck`). The workspace is a checkout of
  the home repo, and the project's other repos are checked out read-only under
  `.symphony/repos/<name>` (`SymphonyElixir.Workspace`).

  When the fix belongs in another repo, the agent files a Linear issue for that
  repo, links it as blocking this one, and moves this issue to its flow's
  blocked stage. `SymphonyElixir.Unblocker` moves it back once every blocker is
  done, with a comment saying what was done.
  """

  alias SymphonyElixir.{Config, IssueStage, Workspace}
  alias SymphonyElixir.Factory.Definition
  alias SymphonyElixir.Linear.Issue

  @doc """
  The section, or "" for a single-repo project.
  """
  @spec render(Issue.t(), keyword()) :: String.t()
  def render(issue, opts \\ [])

  def render(%Issue{} = issue, opts) do
    settings = Keyword.get(opts, :settings) || Config.settings!()
    repos = issue |> Config.linear_project_route(settings) |> Config.project_repos()

    case repos do
      [_primary, _ | _] -> render_repos(issue, repos, Config.issue_repo(issue, settings), settings)
      _ -> ""
    end
  end

  def render(_issue, _opts), do: ""

  @doc """
  Template variables (`{{ repo.name }}`, `{{ repo.others }}`): the issue's home
  repo and the project's other repos.
  """
  @spec variables(Issue.t(), keyword()) :: map()
  def variables(issue, opts \\ [])

  def variables(%Issue{} = issue, opts) do
    settings = Keyword.get(opts, :settings) || Config.settings!()
    repos = issue |> Config.linear_project_route(settings) |> Config.project_repos()
    home = Config.issue_repo(issue, settings)

    %{
      "name" => home && home.name,
      "repo" => home && home.repo,
      "others" =>
        for repo <- repos, home != nil and repo.name != home.name do
          %{"name" => repo.name, "repo" => repo.repo, "path" => reference_path(repo), "description" => repo.description}
        end
    }
  end

  def variables(_issue, _opts), do: %{"name" => nil, "repo" => nil, "others" => []}

  defp render_repos(issue, repos, home, settings) do
    others = Enum.reject(repos, &(&1.name == home.name))

    [
      "## Repositories",
      "",
      "This project has #{length(repos)} repos. An issue is worked in exactly one of them, its home repo: the repo its " <>
        "`#{Config.repo_label_group()}/<name>` label names, else the project's primary repo (**#{hd(repos).name}**). " <>
        "This issue is worked in **#{home.name}** (`#{home.repo}`): the workspace is its checkout, and your commits, " <>
        "branch (`#{Workspace.issue_branch(issue.identifier)}`) and PR go there only. Your GitHub access can push to this repo only.",
      "",
      "The project's other repos are checked out read-only at their default branch, refreshed at the start of every run " <>
        "(changes there are thrown away). Read them freely; never commit, push or open PRs in them:",
      "",
      Enum.map_join(others, "\n", &other_line/1),
      "",
      blocker_section(issue, home, others, settings)
    ]
    |> Enum.join("\n")
  end

  defp other_line(repo) do
    description = if is_binary(repo.description), do: ": #{repo.description}", else: ""
    "- **#{repo.name}** (`#{repo.repo}`) at `#{reference_path(repo)}`#{description}"
  end

  defp reference_path(repo), do: Path.join(Workspace.reference_repos_dir(), repo.name)

  defp blocker_section(issue, home, [example | _], settings) do
    group = Config.repo_label_group()
    require_label = settings.tracker.require_label

    labels =
      ["`#{group}/<name>` (the repo it's for, e.g. `#{Config.repo_label(example.name)}`; the label is in the `#{group}` group)"] ++
        if(is_binary(require_label), do: ["`#{require_label}`, so Symphony picks it up"], else: [])

    """
    ### When the fix belongs in another repo

    One issue changes one repo. If the problem, or part of it, has to be fixed in one of the other repos, don't change that repo from here. Instead:

    1. Create a Linear issue for it with `linear_graphql`, in this issue's project and team (read their ids from this issue),
       in the `#{queue_state(issue)}` state, assigned like this issue, with the labels #{Enum.join(labels, " and ")}. Its description must say what needs to change in that repo
       and why, the evidence (errors, logs, file paths, lines), how to verify the fix, and link back to #{issue.identifier}.
    2. Link it as blocking this issue: `issueRelationCreate(input: {issueId: "<new issue id>", relatedIssueId: "<this issue's id>", type: blocks})`.
    3. Commit and push whatever you have on this issue's branch, then #{blocked_move(issue)}

    Symphony works the new issue in its own repo, with its own branch and PR. Once every issue blocking this one is done
    (in the default flow: its PR merged), Symphony moves this issue back to work and comments `## Unblocked` with what each
    blocker changed. The next run then starts from that comment, with the other repos refreshed to their latest default branch.

    If the fix belongs in a repo that isn't listed here, Symphony can't work there for this project yet: write in the
    workpad and your summary which repo needs what change, and finish as blocked (see "When you are blocked"); a person
    adds the repo to the project or makes the change.

    Work that only needs #{home.name} stays here as usual.
    """
  end

  # The state new issues wait in for an agent: the flow's queue stage (teams
  # name it differently, e.g. "Ready for pickup"), else Linear's default.
  defp queue_state(issue) do
    case Enum.find(IssueStage.definition(issue)["stages"] || [], &(&1["kind"] == "queue")) do
      %{"linear_state" => state} when is_binary(state) -> state
      _ -> "Todo"
    end
  end

  defp blocked_move(issue) do
    definition = IssueStage.definition(issue)
    stage = IssueStage.stage_definition(issue)

    target =
      if stage,
        do: Enum.find_value(Definition.transitions_from(definition, stage["id"]), &blocked_target(definition, &1)),
        else: nil

    case target do
      %{"id" => id, "name" => name} ->
        "finish this stage with the move `#{id}` (#{name}), and say in your summary which issue blocks this one and what this issue still needs once it's done."

      nil ->
        "say in your summary which issue blocks this one; this stage has no move to a blocked stage, so a person takes it from there."
    end
  end

  defp blocked_target(definition, %{"by" => "agent", "to" => to}) do
    case Definition.stage(definition, to) do
      %{"kind" => "parked"} = stage -> stage
      _ -> nil
    end
  end

  defp blocked_target(_definition, _transition), do: nil
end
