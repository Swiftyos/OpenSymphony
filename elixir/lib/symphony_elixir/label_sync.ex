defmodule SymphonyElixir.LabelSync do
  @moduledoc """
  Creates the Linear labels Symphony needs, so nobody has to make them by hand.

  For every configured project it asks Linear which teams the project belongs
  to, then makes sure each team has:

    * the `<prefix>` label group with a child label for every stage label in the
      flow the team's issues in that project follow
    * `tracker.require_label` (e.g. `auto-build`) and `tracker.approval_label`
      (e.g. `needs-approval`)

  Labels that already exist in the team or workspace are left alone. It runs
  once at startup, and for each project added through MCP (`sync_projects/1`);
  saving a flow in the dashboard syncs that flow's labels too.
  The project names and teams Linear returns are kept (`project_names/0`,
  `project_teams/0`) so the dashboard can name projects, and list them under
  their teams, before it has seen any of their issues.
  """

  require Logger

  alias SymphonyElixir.{Config, IssueStage, Tracker}
  alias SymphonyElixir.Factory.Store

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: %{id: __MODULE__, start: {Task, :start_link, [&boot/0]}, restart: :temporary}

  @doc """
  Runs `sync/0` at startup when the tracker is Linear (and `:label_sync_on_boot`
  isn't turned off, as it is in tests).
  """
  @spec boot() :: :ok
  def boot do
    if Application.get_env(:symphony_elixir, :label_sync_on_boot, true) and Config.settings!().tracker.kind == "linear" do
      sync()
    end

    :ok
  end

  @doc """
  Ensures the labels for every configured project's teams. Returns the labels
  created per team.
  """
  @spec sync() :: {:ok, %{String.t() => [String.t()]}} | {:error, term()}
  def sync do
    Config.settings!() |> Config.linear_project_routes() |> Enum.map(& &1.slug) |> Enum.filter(&is_binary/1) |> sync_projects()
  end

  @doc """
  Like `sync/0`, for some projects only (e.g. one just added through MCP): learns
  their names and ensures their teams' labels.
  """
  @spec sync_projects([String.t()]) :: {:ok, %{String.t() => [String.t()]}} | {:error, term()}
  def sync_projects(slugs) when is_list(slugs) do
    settings = Config.settings!()
    plain = Enum.filter([settings.tracker.require_label, settings.tracker.approval_label], &is_binary/1)

    case Tracker.project_info(slugs) do
      {:ok, info} ->
        remember_names(info)
        teams_by_project = Map.new(info, fn {slug, %{teams: teams}} -> {slug, teams} end)

        created =
          teams_by_project
          |> stage_labels_by_team()
          |> Map.new(fn {team, labels} -> {team, ensure(team, labels, plain)} end)

        log(created)
        {:ok, created}

      {:error, reason} ->
        Logger.warning("Linear label sync skipped: couldn't look up project teams reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Project names by slug, as Linear reported them at the last sync.
  """
  @spec project_names() :: %{String.t() => String.t()}
  def project_names, do: :persistent_term.get({__MODULE__, :project_names}, %{})

  @doc """
  The teams each project belongs to, by slug, as Linear reported them at the
  last sync.
  """
  @spec project_teams() :: %{String.t() => [String.t()]}
  def project_teams, do: :persistent_term.get({__MODULE__, :project_teams}, %{})

  defp remember_names(info) do
    names = for {slug, %{name: name}} <- info, is_binary(name), into: project_names(), do: {slug, name}
    teams = for {slug, %{teams: teams}} <- info, is_list(teams), into: project_teams(), do: {slug, teams}
    :persistent_term.put({__MODULE__, :project_names}, names)
    :persistent_term.put({__MODULE__, :project_teams}, teams)
  end

  # Each team needs the stage labels of every flow its issues can follow.
  defp stage_labels_by_team(teams_by_project) do
    Enum.reduce(teams_by_project, %{}, fn {slug, teams}, acc ->
      Enum.reduce(teams, acc, fn team, acc ->
        labels =
          Store.get(Store.scope_for(team, slug))["stages"]
          |> Enum.map(& &1["label"])
          |> Enum.filter(&is_binary/1)

        Map.update(acc, team, labels, &Enum.uniq(&1 ++ labels))
      end)
    end)
  end

  defp ensure(team, stage_labels, plain) do
    prefix = IssueStage.label_prefix()

    with {:ok, stage_created} <- ensure_some(stage_labels, &Tracker.ensure_stage_labels(team, &1)),
         {:ok, plain_created} <- ensure_some(plain, &Tracker.ensure_labels(team, &1)) do
      stage_created ++ plain_created
    else
      {:error, reason} ->
        Logger.warning("Linear label sync failed team=#{team} prefix=#{prefix} reason=#{inspect(reason)}")
        []
    end
  end

  defp ensure_some([], _ensure), do: {:ok, []}
  defp ensure_some(labels, ensure), do: ensure.(labels)

  defp log(created) do
    Enum.each(created, fn
      {_team, []} -> :ok
      {team, labels} -> Logger.info("Created Linear labels team=#{team} labels=#{Enum.join(labels, ",")}")
    end)
  end
end
