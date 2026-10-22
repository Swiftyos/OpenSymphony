defmodule SymphonyElixirWeb.QuickLinks do
  @moduledoc """
  The flow panel's links for what the top bar picks: the Linear team or
  project page (the workspace, with all teams picked), and the GitHub repos
  the picked project, or the picked team's projects, work in (the primary
  repo and each extra one).

  Projects come from a payload already trimmed to what the viewer may see
  (`SymphonyElixirWeb.Visibility`), so a hidden project's repos never show.

  The Linear workspace's URL key (`linear.app/<key>/...`) is read from an
  issue URL Symphony already has, else asked of Linear once
  (`organization { urlKey }`), and kept; a failed lookup is tried again after
  a while.
  """

  alias SymphonyElixir.{Config, LabelSync, UsageLedger}

  @workspace_query """
  query SymphonyOrganization {
    organization {
      urlKey
    }
  }
  """
  @retry_ms 600_000
  @github_url ~r<^(?:https://|git@)github\.com[/:]([A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}?)(?:\.git)?/?$>
  @github_slug ~r/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/

  @type link :: %{label: String.t(), url: String.t()}

  @doc """
  `%{linear: link | nil, repos: [link]}` for a team or project pick (both nil:
  all teams).
  """
  @spec for_scope(map(), String.t() | nil, String.t() | nil) :: %{linear: link() | nil, repos: [link()]}
  def for_scope(visible, team, project) do
    workspace = workspace_key()

    %{
      linear: linear_link(workspace, team, project, visible),
      repos: repo_links(slugs(visible, team, project))
    }
  end

  defp linear_link(workspace, _team, project, visible) when is_binary(project) do
    url = LabelSync.project_urls()[project] || (workspace && "https://linear.app/#{workspace}/project/#{project}")
    name = Enum.find_value(project_entries(visible), project, &(&1[:slug] == project && &1[:name]))
    url && %{label: "#{name} in Linear", url: url}
  end

  defp linear_link(nil, _team, _project, _visible), do: nil
  defp linear_link(workspace, team, nil, _visible) when is_binary(team), do: %{label: "#{team} in Linear", url: "https://linear.app/#{workspace}/team/#{team}/active"}
  defp linear_link(workspace, nil, nil, _visible), do: %{label: "Linear workspace", url: "https://linear.app/#{workspace}"}

  # The picked project, else every visible project of the picked team; all
  # teams: none (there would be too many).
  defp slugs(_visible, _team, project) when is_binary(project), do: [project]

  defp slugs(visible, team, nil) when is_binary(team) do
    for %{kind: "project", slug: slug} = entry <- project_entries(visible), team in (entry[:teams] || []), do: slug
  end

  defp slugs(_visible, _team, _project), do: []

  defp project_entries(%{factory: %{teams: entries}}), do: Enum.filter(entries, &(&1[:kind] == "project"))
  defp project_entries(_visible), do: []

  defp repo_links([]), do: []

  defp repo_links(slugs) do
    routes = Config.linear_project_routes()

    slugs
    |> Enum.flat_map(fn slug -> routes |> Enum.find(&(&1.slug == slug)) |> Config.project_repos() end)
    |> Enum.flat_map(fn repo ->
      case github_url(repo.repo) do
        nil -> []
        url -> [%{label: github_slug(url), url: url, primary: repo.primary}]
      end
    end)
    |> Enum.uniq_by(& &1.url)
    |> Enum.sort_by(&{not &1.primary, &1.label})
    |> Enum.map(&Map.take(&1, [:label, :url]))
  end

  @doc "A GitHub repo's web page from `owner/name` or a github.com URL; nil for anything else."
  @spec github_url(String.t() | nil) :: String.t() | nil
  def github_url(repo) when is_binary(repo) do
    repo = String.trim(repo)

    cond do
      Regex.match?(@github_slug, repo) ->
        "https://github.com/" <> String.replace_suffix(repo, ".git", "")

      match = Regex.run(@github_url, repo) ->
        "https://github.com/" <> List.last(match)

      true ->
        nil
    end
  end

  def github_url(_repo), do: nil

  defp github_slug("https://github.com/" <> slug), do: slug

  @doc "The Linear workspace's URL key, or nil when it isn't known (yet)."
  @spec workspace_key() :: String.t() | nil
  def workspace_key do
    case :persistent_term.get({__MODULE__, :workspace}, nil) do
      {:ok, key} -> key
      {:failed, at} -> if System.monotonic_time(:millisecond) - at > @retry_ms, do: lookup_workspace(), else: nil
      nil -> lookup_workspace()
    end
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase({__MODULE__, :workspace})
    :ok
  end

  defp lookup_workspace do
    case from_issue_urls() || from_linear() do
      key when is_binary(key) ->
        :persistent_term.put({__MODULE__, :workspace}, {:ok, key})
        key

      nil ->
        :persistent_term.put({__MODULE__, :workspace}, {:failed, System.monotonic_time(:millisecond)})
        nil
    end
  end

  defp from_issue_urls do
    Enum.find_value(UsageLedger.snapshot().flow.issues, fn issue ->
      case Regex.run(~r<^https://linear\.app/([A-Za-z0-9_-]+)/issue/>, issue[:url] || "") do
        [_, key] -> key
        _ -> nil
      end
    end)
  end

  defp from_linear do
    settings = Config.settings!()

    with true <- settings.tracker.kind == "linear" and is_binary(settings.tracker.api_key),
         {:ok, %{"data" => %{"organization" => %{"urlKey" => key}}}} when is_binary(key) <- client().graphql(@workspace_query, %{}, []) do
      key
    else
      _ -> nil
    end
  end

  defp client, do: Application.get_env(:symphony_elixir, :linear_client_module, SymphonyElixir.Linear.Client)
end
