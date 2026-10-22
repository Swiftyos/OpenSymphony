defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @create_comment_with_id_mutation """
  mutation SymphonyCreateCommentWithId($issueId: String!, $body: String!, $id: String!) {
    commentCreate(input: {issueId: $issueId, body: $body, id: $id}) {
      success
    }
  }
  """

  @comment_lookup_query """
  query SymphonyCommentLookup($id: String!) {
    comment(id: $id) {
      id
      issue {
        id
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @stage_lookup_query """
  query SymphonyStageLookup($issueId: String!, $stateName: String!, $stage: String!, $flat: String!, $prefix: String!) {
    issue(id: $issueId) {
      team {
        id
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
      labels {
        nodes {
          id
          name
          parent {
            name
          }
        }
      }
    }
    issueLabels(first: 50, filter: {or: [{name: {eqIgnoreCase: $flat}}, {name: {eqIgnoreCase: $stage}, parent: {name: {eqIgnoreCase: $prefix}}}]}) {
      nodes {
        id
        name
        parent {
          name
        }
        team {
          id
        }
      }
    }
  }
  """

  @set_stage_mutation """
  mutation SymphonySetStage($issueId: String!, $stateId: String!, $labelIds: [String!]!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId, labelIds: $labelIds}) {
      success
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @doc """
  Posts a comment. With `id:` the create is idempotent: if Linear refuses the
  duplicate (or the request fails after it was applied), the comment is looked
  up and `:ok` returned when it already exists on this issue.
  """
  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, opts \\ []) when is_binary(issue_id) and is_binary(body) do
    id = Keyword.get(opts, :id)

    {mutation, variables} =
      if is_binary(id),
        do: {@create_comment_with_id_mutation, %{issueId: issue_id, body: body, id: id}},
        else: {@create_comment_mutation, %{issueId: issue_id, body: body}}

    with {:ok, response} <- client_module().graphql(mutation, variables),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      failure -> comment_create_error(failure, id, issue_id)
    end
  end

  @doc """
  Whether a comment with this id exists. Linear answers a missing entity with a
  "not found" GraphQL error, which means it does not exist; any other error
  (auth, rate limit) is returned, so a caller never mistakes it for absence.
  """
  @spec comment_exists?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def comment_exists?(id) when is_binary(id) do
    case client_module().graphql(@comment_lookup_query, %{id: id}) do
      {:ok, %{"data" => %{"comment" => %{"id" => _id}}}} -> {:ok, true}
      {:ok, %{"errors" => errors}} when is_list(errors) -> missing_or_error(errors)
      {:ok, %{"data" => %{"comment" => nil}}} -> {:ok, false}
      {:ok, response} -> {:error, {:unexpected_response, response}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp missing_or_error(errors) do
    not_found? = errors != [] and Enum.all?(errors, &(is_map(&1) and is_binary(&1["message"]) and &1["message"] =~ ~r/not found/i))
    if not_found?, do: {:ok, false}, else: {:error, {:graphql_errors, errors}}
  end

  defp comment_create_error(failure, id, issue_id) do
    error = comment_create_failure(failure)

    if is_binary(id) and comment_on_issue?(id, issue_id), do: :ok, else: error
  end

  defp comment_create_failure(false), do: {:error, :comment_create_failed}
  defp comment_create_failure({:error, reason}), do: {:error, reason}
  defp comment_create_failure(_failure), do: {:error, :comment_create_failed}

  defp comment_on_issue?(id, issue_id) do
    case client_module().graphql(@comment_lookup_query, %{id: id}) do
      {:ok, %{"data" => %{"comment" => %{"issue" => %{"id" => ^issue_id}}}}} -> true
      _ -> false
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec set_stage(String.t(), String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def set_stage(issue_id, state_name, stage, opts \\ []) when is_binary(issue_id) and is_binary(state_name) do
    prefix = SymphonyElixir.IssueStage.label_prefix()
    graphql_opts = Keyword.take(opts, [:api_key])

    variables = %{
      issueId: issue_id,
      stateName: state_name,
      stage: stage || "",
      flat: "#{prefix}/#{stage || ""}",
      prefix: prefix
    }

    with {:ok, response} <- client_module().graphql(@stage_lookup_query, variables, graphql_opts),
         {:ok, state_id} <- stage_state_id(response),
         {:ok, label_ids} <- stage_label_ids(response, prefix, stage, Keyword.get(opts, :drop_labels, [])),
         {:ok, extra_ids} <- labels_by_name(Keyword.get(opts, :add_labels, []), get_in(response, ["data", "issue", "team", "id"]), graphql_opts),
         label_ids = Enum.uniq(label_ids ++ extra_ids),
         {:ok, update} <-
           client_module().graphql(
             @set_stage_mutation,
             %{issueId: issue_id, stateId: state_id, labelIds: label_ids},
             graphql_opts
           ),
         true <- get_in(update, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp stage_state_id(response) do
    case get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      state_id when is_binary(state_id) -> {:ok, state_id}
      _ -> {:error, :state_not_found}
    end
  end

  # Keep every non-stage label (except `drop`, e.g. the approval label), drop
  # old stage labels, add the new one.
  defp stage_label_ids(response, prefix, stage, drop) do
    kept = kept_label_ids(get_in(response, ["data", "issue", "labels", "nodes"]) || [], prefix, Enum.map(drop, &String.downcase/1))

    case stage do
      nil ->
        {:ok, kept}

      _stage ->
        team_id = get_in(response, ["data", "issue", "team", "id"])
        # Never trust the filter alone: keep only labels that really are this
        # stage (`<prefix>/<stage>` flat, or `<stage>` inside the group).
        candidates =
          (get_in(response, ["data", "issueLabels", "nodes"]) || [])
          |> Enum.filter(&stage_label_named?(&1, prefix, stage))

        label =
          Enum.find(candidates, &(get_in(&1, ["team", "id"]) == team_id)) ||
            Enum.find(candidates, &is_nil(get_in(&1, ["team", "id"])))

        case label do
          %{"id" => id} -> {:ok, Enum.uniq(kept ++ [id])}
          _ -> {:error, {:stage_label_not_found, "#{prefix}/#{stage}"}}
        end
    end
  end

  @labels_by_name_query """
  query SymphonyLabelsByName($names: [String!]!) {
    issueLabels(first: 50, filter: {name: {in: $names}}) {
      nodes {
        id
        name
        team {
          id
        }
      }
    }
  }
  """

  # Plain labels to add (e.g. the approval label): the team's own, else the
  # workspace's. Every name must exist.
  defp labels_by_name([], _team_id, _opts), do: {:ok, []}

  defp labels_by_name(names, team_id, opts) do
    with {:ok, response} <- client_module().graphql(@labels_by_name_query, %{names: names}, opts) do
      nodes = get_in(response, ["data", "issueLabels", "nodes"]) || []

      Enum.reduce_while(names, {:ok, []}, &add_label_id(&1, &2, nodes, team_id))
    end
  end

  defp add_label_id(name, {:ok, ids}, nodes, team_id) do
    matching = Enum.filter(nodes, &(String.downcase(&1["name"] || "") == String.downcase(name)))

    case Enum.find(matching, &(get_in(&1, ["team", "id"]) == team_id)) || Enum.find(matching, &is_nil(&1["team"])) do
      %{"id" => id} -> {:cont, {:ok, ids ++ [id]}}
      nil -> {:halt, {:error, {:label_not_found, name}}}
    end
  end

  defp stage_label_named?(label, prefix, stage) do
    name = String.downcase(label["name"] || "")
    parent = String.downcase(get_in(label, ["parent", "name"]) || "")
    stage = String.downcase(stage)
    name == prefix <> "/" <> stage or (name == stage and parent == prefix)
  end

  defp kept_label_ids(labels, prefix, drop) do
    labels
    |> Enum.reject(&(stage_label?(&1, prefix) or String.downcase(&1["name"] || "") in drop))
    |> Enum.map(& &1["id"])
  end

  defp stage_label?(label, prefix) do
    name = String.downcase(label["name"] || "")
    parent = String.downcase(get_in(label, ["parent", "name"]) || "")
    parent == prefix or String.starts_with?(name, prefix <> "/")
  end

  @label_inventory_query """
  query SymphonyStageLabels($teamKey: String!, $prefix: String!) {
    teams(filter: {key: {eq: $teamKey}}, first: 1) {
      nodes {
        id
      }
    }
    issueLabels(first: 250, filter: {or: [{name: {eqIgnoreCase: $prefix}}, {parent: {name: {eqIgnoreCase: $prefix}}}]}) {
      nodes {
        id
        name
        isGroup
        team {
          id
        }
        parent {
          id
        }
      }
    }
  }
  """

  @label_create_mutation """
  mutation SymphonyCreateLabel($input: IssueLabelCreateInput!) {
    issueLabelCreate(input: $input) {
      success
      issueLabel {
        id
      }
    }
  }
  """

  @spec ensure_stage_labels(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def ensure_stage_labels(team_key, labels) when is_binary(team_key) and is_list(labels) do
    ensure_group_labels(team_key, SymphonyElixir.IssueStage.label_prefix(), labels)
  end

  @doc """
  Makes sure a team has a `group` label group with these child labels, creating
  what's missing. Returns the labels created, as `group/label`.
  """
  @spec ensure_group_labels(String.t(), String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def ensure_group_labels(team_key, prefix, labels) when is_binary(team_key) and is_binary(prefix) and is_list(labels) do
    with {:ok, response} <- client_module().graphql(@label_inventory_query, %{teamKey: team_key, prefix: prefix}),
         {:ok, team_id} <- inventory_team_id(response),
         nodes = get_in(response, ["data", "issueLabels", "nodes"]) || [],
         {:ok, group_id, created_group} <- ensure_label_group(nodes, team_id, prefix) do
      existing =
        nodes
        |> Enum.filter(&(get_in(&1, ["parent", "id"]) == group_id))
        |> MapSet.new(&String.downcase(&1["name"] || ""))

      labels
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(existing, &1))
      |> Enum.reduce_while({:ok, created_group}, &create_stage_label(&1, &2, group_id, team_id, prefix))
    end
  end

  @plain_labels_query """
  query SymphonyPlainLabels($teamKey: String!) {
    teams(filter: {key: {eq: $teamKey}}, first: 1) {
      nodes {
        id
        labels(first: 250) {
          nodes {
            name
          }
        }
      }
    }
    issueLabels(first: 250, filter: {team: {null: true}}) {
      nodes {
        name
      }
    }
  }
  """

  @doc """
  Creates plain (ungrouped) team labels that neither the team nor the workspace
  has yet, e.g. the opt-in and approval labels. Returns the names created.
  """
  @spec ensure_labels(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def ensure_labels(team_key, names) when is_binary(team_key) and is_list(names) do
    with {:ok, response} <- client_module().graphql(@plain_labels_query, %{teamKey: team_key}),
         {:ok, team_id} <- inventory_team_id(response) do
      existing =
        (get_in(response, ["data", "teams", "nodes", Access.at(0), "labels", "nodes"]) || []) ++
          (get_in(response, ["data", "issueLabels", "nodes"]) || [])

      have = MapSet.new(existing, &String.downcase(&1["name"] || ""))

      names
      |> Enum.uniq_by(&String.downcase/1)
      |> Enum.reject(&MapSet.member?(have, String.downcase(&1)))
      |> Enum.reduce_while({:ok, []}, &create_plain_label(&1, &2, team_id))
    end
  end

  defp create_plain_label(name, {:ok, created}, team_id) do
    case create_label(%{name: name, teamId: team_id}) do
      {:ok, _id} -> {:cont, {:ok, created ++ [name]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @issue_reports_query """
  query SymphonyIssueReports($ids: [ID!]!) {
    issues(filter: {id: {in: $ids}}, first: 50) {
      nodes {
        id
        identifier
        title
        url
        state {
          name
          type
        }
        attachments(first: 25) {
          nodes {
            title
            url
          }
        }
        comments(first: 100) {
          nodes {
            body
            createdAt
          }
        }
      }
    }
  }
  """

  @doc """
  What happened on some issues (by id): title, link, state, attachments (PRs)
  and comments, newest first. Used to tell a blocked issue what its blockers did.
  """
  @spec fetch_issue_reports([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_reports([]), do: {:ok, []}

  def fetch_issue_reports(ids) when is_list(ids) do
    case client_module().graphql(@issue_reports_query, %{ids: ids}) do
      {:ok, %{"data" => %{"issues" => %{"nodes" => nodes}}}} when is_list(nodes) ->
        {:ok, Enum.map(nodes, &issue_report/1)}

      {:ok, response} ->
        {:error, {:unexpected_response, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_report(node) do
    %{
      id: node["id"],
      identifier: node["identifier"],
      title: node["title"],
      url: node["url"],
      state: get_in(node, ["state", "name"]),
      state_type: get_in(node, ["state", "type"]),
      attachments: for(%{"url" => url} = a <- get_in(node, ["attachments", "nodes"]) || [], is_binary(url), do: %{title: a["title"], url: url}),
      comments:
        (get_in(node, ["comments", "nodes"]) || [])
        |> Enum.filter(&is_binary(&1["body"]))
        |> Enum.sort_by(&(&1["createdAt"] || ""), :desc)
        |> Enum.map(& &1["body"])
    }
  end

  @project_teams_query """
  query SymphonyProjectTeams($slugs: [String!]!) {
    projects(filter: {slugId: {in: $slugs}}, first: 50) {
      nodes {
        slugId
        name
        url
        teams(first: 50) {
          nodes {
            key
          }
        }
      }
    }
  }
  """

  @doc """
  Each project's (by slug) name, Linear URL and the keys of the teams it
  belongs to.
  """
  @type project_info :: %{name: String.t() | nil, url: String.t() | nil, teams: [String.t()]}
  @spec project_info([String.t()]) :: {:ok, %{String.t() => project_info()}} | {:error, term()}
  def project_info([]), do: {:ok, %{}}

  def project_info(slugs) when is_list(slugs) do
    case client_module().graphql(@project_teams_query, %{slugs: slugs}) do
      {:ok, %{"data" => %{"projects" => %{"nodes" => nodes}}}} when is_list(nodes) ->
        {:ok, Map.new(nodes, &{&1["slugId"], %{name: &1["name"], url: &1["url"], teams: for(%{"key" => key} <- get_in(&1, ["teams", "nodes"]) || [], do: key)}})}

      {:ok, response} ->
        {:error, {:unexpected_response, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @project_statuses_query """
  query SymphonyProjectStatuses($slugs: [String!]!) {
    projects(filter: {slugId: {in: $slugs}}, first: 100, includeArchived: true) {
      nodes {
        slugId
        archivedAt
        status {
          type
        }
      }
    }
  }
  """

  @doc """
  Each project's (by slug) status type and whether it is archived; a project
  Linear doesn't return (deleted) is left out.
  """
  @type project_status :: %{status: String.t() | nil, archived: boolean()}
  @spec project_statuses([String.t()]) :: {:ok, %{String.t() => project_status()}} | {:error, term()}
  def project_statuses([]), do: {:ok, %{}}

  def project_statuses(slugs) when is_list(slugs) do
    case client_module().graphql(@project_statuses_query, %{slugs: slugs}) do
      {:ok, %{"data" => %{"projects" => %{"nodes" => nodes}}}} when is_list(nodes) ->
        {:ok, Map.new(nodes, &{&1["slugId"], %{status: get_in(&1, ["status", "type"]), archived: is_binary(&1["archivedAt"])}})}

      {:ok, response} ->
        {:error, {:unexpected_response, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_stage_label(label, {:ok, created}, group_id, team_id, prefix) do
    case create_label(%{name: label, parentId: group_id, teamId: team_id}) do
      {:ok, _id} -> {:cont, {:ok, created ++ ["#{prefix}/#{label}"]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp inventory_team_id(response) do
    case get_in(response, ["data", "teams", "nodes", Access.at(0), "id"]) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :team_not_found}
    end
  end

  # Use the team's own group, else a workspace-wide one, else create it for the team.
  defp ensure_label_group(nodes, team_id, prefix) do
    groups = Enum.filter(nodes, &(&1["isGroup"] == true and String.downcase(&1["name"] || "") == prefix))

    case Enum.find(groups, &(get_in(&1, ["team", "id"]) == team_id)) || Enum.find(groups, &is_nil(&1["team"])) do
      %{"id" => id} ->
        {:ok, id, []}

      nil ->
        with {:ok, id} <- create_label(%{name: prefix, isGroup: true, teamId: team_id}), do: {:ok, id, [prefix]}
    end
  end

  defp create_label(input) do
    case client_module().graphql(@label_create_mutation, %{input: input}) do
      {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => %{"id" => id}}}}} -> {:ok, id}
      {:ok, _response} -> {:error, {:label_create_failed, input.name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
