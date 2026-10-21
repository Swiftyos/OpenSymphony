defmodule SymphonyElixirWeb.ScopePicker do
  @moduledoc """
  The top bar's team and project pickers, shared by the dashboard and the
  traces and metrics page: the choices a viewer has, what a URL's `team` and
  `project` params resolve to, and the URL a pick leads to.

  Choices come from a factory payload already trimmed to what the viewer may
  see (`Visibility.filter_payload/2`), so a hidden team or project never shows
  up and is dropped from a URL that names it.
  """

  alias SymphonyElixir.Factory.Store

  @type choice :: %{key: String.t(), name: String.t() | nil}
  @type project :: %{slug: String.t(), name: String.t()}

  @doc "The teams the viewer can pick, from a visible payload."
  @spec teams(map(), map() | nil) :: [choice()]
  def teams(%{factory: %{teams: entries}}, user) do
    names = if user, do: Map.new(user.teams, &{&1.key, &1.name}), else: %{}

    entries
    |> Enum.filter(&(&1[:kind] == "team"))
    |> Enum.map(&%{key: &1.key, name: &1.name || names[&1.key]})
  end

  def teams(_payload, _user), do: []

  @doc "The projects the viewer can pick: the chosen team's, or all of them."
  @spec projects(map(), String.t() | nil) :: [project()]
  def projects(%{factory: %{teams: entries}}, team) do
    entries
    |> Enum.filter(&(&1[:kind] == "project" and (is_nil(team) or team in (&1[:teams] || []))))
    |> Enum.map(&%{slug: &1.slug, name: &1.name || &1.slug})
  end

  def projects(_payload, _team), do: []

  @doc """
  The team and project a URL's params pick, normalized; nil for one that is
  missing, unknown or hidden. A project outside the picked team is dropped.
  """
  @spec resolve(map(), map(), map() | nil) :: %{
          team: String.t() | nil,
          project: String.t() | nil,
          teams: [choice()],
          projects: [project()]
        }
  def resolve(params, visible, user) do
    wanted_team = params |> Map.get("team") |> then(&(is_binary(&1) && String.upcase(String.trim(&1))))
    wanted_project = params |> Map.get("project") |> then(&(is_binary(&1) && String.trim(&1)))

    teams = teams(visible, user)
    team = if Enum.any?(teams, &(&1.key == wanted_team)), do: wanted_team
    projects = projects(visible, team)
    project = if Enum.any?(projects, &(&1.slug == wanted_project)), do: wanted_project

    %{team: team, project: project, teams: teams, projects: projects}
  end

  @doc """
  The query params for a pick from the top bar's form. Picking another team
  starts from all of its projects.
  """
  @spec pick(map(), String.t() | nil) :: [{String.t(), String.t()}]
  def pick(params, current_team) do
    team = if params["team"] in [nil, "", "all"], do: nil, else: params["team"]
    project = if params["project"] in [nil, "", "all"], do: nil, else: params["project"]
    project = if team == current_team, do: project, else: nil
    Enum.reject([{"team", team}, {"project", project}], &is_nil(elem(&1, 1)))
  end

  @doc "The flow key a pick shows: the project's own scope, else the team."
  @spec flow_scope(String.t() | nil, String.t() | nil) :: String.t() | nil
  def flow_scope(_team, project) when is_binary(project), do: Store.project_scope(project)
  def flow_scope(team, _project), do: team
end
