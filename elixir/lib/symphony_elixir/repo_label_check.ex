defmodule SymphonyElixir.RepoLabelCheck do
  @moduledoc """
  Tells an issue, with one comment, why no agent starts on it when its
  `repo/<name>` label doesn't pick one of its project's repos.

  Symphony works an issue in the repo its `repo/<name>` label names, else in
  the project's primary repo (`SymphonyElixir.Config.check_issue_repo/2`). A
  label naming a repo the project doesn't have, or two different repo labels,
  is an error rather than a reason to guess: `SymphonyElixir.IssueConfig`
  refuses to resolve the issue, so it is never dispatched, and this module
  posts a `## Repo label problem` comment saying what to change. Fixing the
  label (or adding the repo to the project) lets the next poll pick it up.

  Each poll hands its candidate issues to `observe/1`. Only issues in a stage
  agents work (`queue` or `agent`) are checked. The comment is posted once per
  issue and set of repo labels (its id is derived from them, so a retry or a
  restart doesn't post it twice).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Effects, IssueStage, Tracker}
  alias SymphonyElixir.Linear.Issue

  @checked_kinds ["queue", "agent"]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Looks at a poll's issues and comments on the ones with a bad repo label.
  Returns at once; the comments are posted in the background.
  """
  @spec observe([Issue.t()], GenServer.server()) :: :ok
  def observe(issues, server \\ __MODULE__) when is_list(issues) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         [_ | _] = problems <- problems(issues) do
      GenServer.cast(pid, {:observe, problems})
    end

    :ok
  end

  @doc """
  The issues in a stage agents work whose repo labels don't pick a repo, each
  with the comment to post.
  """
  @spec problems([Issue.t()], Config.Schema.t() | nil) :: [{Issue.t(), String.t()}]
  def problems(issues, settings \\ nil) do
    settings = settings || Config.settings!()

    for %Issue{id: id} = issue when is_binary(id) <- issues,
        checked_stage?(issue, settings),
        {:error, reason} <- [Config.check_issue_repo(issue, Config.linear_project_route(issue, settings))] do
      {issue, comment(issue, reason)}
    end
  end

  @doc """
  The comment for an issue whose repo labels don't pick a repo.
  """
  @spec comment(Issue.t(), term()) :: String.t()
  def comment(%Issue{} = issue, {:unknown_repo_label, name, repos}) do
    """
    ## Repo label problem

    `#{Config.repo_label(name)}` doesn't name a repo of this project, so Agent Factory won't start an agent on #{issue.identifier} \
    (it doesn't guess which repo you meant).

    #{repo_list(repos)}

    To fix it, change the label to one of these, or remove it to use the primary repo. If the work really belongs in \
    another repo, an admin adds that repo to the project (MCP `add_project` with `repos`), and then the label works. \
    The issue is picked up on the next poll after the fix.
    """
  end

  def comment(%Issue{} = issue, {:conflicting_repo_labels, names, repos}) do
    labels = Enum.map_join(names, " and ", &"`#{Config.repo_label(&1)}`")

    """
    ## Repo label problem

    #{issue.identifier} has #{length(names)} repo labels, #{labels}, but an issue is worked in exactly one repo, so \
    Agent Factory won't start an agent on it.

    #{repo_list(repos)}

    Keep the label of the repo this issue changes and remove the others. For a change that needs several repos, file \
    one issue per repo and link them as blocking.
    """
  end

  defp repo_list(repos) do
    lines =
      Enum.map_join(repos, "\n", fn repo ->
        primary = if repo.primary, do: ", the primary: used when there's no repo label", else: ""
        "- `#{Config.repo_label(repo.name)}`: `#{repo.repo}`#{primary}"
      end)

    "This project's repos:\n\n" <> lines
  end

  @impl true
  def init(opts), do: {:ok, %{done: MapSet.new(), tracker: Keyword.get(opts, :tracker, Tracker)}}

  @impl true
  def handle_cast({:observe, problems}, state) do
    done =
      Enum.reduce(problems, state.done, fn {issue, body}, done ->
        key = comment_id(issue)
        if MapSet.member?(done, key), do: done, else: post(issue, body, key, done, state.tracker)
      end)

    {:noreply, %{state | done: done}}
  end

  defp post(issue, body, key, done, tracker) do
    case tracker.create_comment(issue.id, body, id: key) do
      :ok ->
        Logger.info("Repo label problem reported issue_identifier=#{issue.identifier}")
        MapSet.put(done, key)

      {:error, reason} ->
        Logger.warning("Repo label comment failed issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
        done
    end
  end

  defp checked_stage?(issue, settings) do
    match?(%{"kind" => kind} when kind in @checked_kinds, IssueStage.stage_definition(issue, settings))
  end

  # One comment per issue and set of repo labels.
  defp comment_id(%Issue{id: id, labels: labels}) do
    prefix = Config.repo_label_group() <> "/"
    repo_labels = labels |> List.wrap() |> Enum.map(&String.downcase/1) |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()
    Effects.uuid("repo-label:#{id}:#{Enum.join(repo_labels, ",")}")
  end
end
