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

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
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
         {:ok, label_ids} <- stage_label_ids(response, prefix, stage),
         {:ok, update} <-
           client_module().graphql(@set_stage_mutation, %{issueId: issue_id, stateId: state_id, labelIds: label_ids}, graphql_opts),
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

  # Keep every non-stage label, drop old stage labels, add the new one.
  defp stage_label_ids(response, prefix, stage) do
    current = get_in(response, ["data", "issue", "labels", "nodes"]) || []

    kept =
      current
      |> Enum.reject(&stage_label?(&1, prefix))
      |> Enum.map(& &1["id"])

    case stage do
      nil ->
        {:ok, kept}

      _stage ->
        team_id = get_in(response, ["data", "issue", "team", "id"])
        candidates = get_in(response, ["data", "issueLabels", "nodes"]) || []

        label =
          Enum.find(candidates, &(get_in(&1, ["team", "id"]) == team_id)) ||
            Enum.find(candidates, &is_nil(get_in(&1, ["team", "id"])))

        case label do
          %{"id" => id} -> {:ok, Enum.uniq(kept ++ [id])}
          _ -> {:error, {:stage_label_not_found, "#{prefix}/#{stage}"}}
        end
    end
  end

  defp stage_label?(label, prefix) do
    name = String.downcase(label["name"] || "")
    parent = String.downcase(get_in(label, ["parent", "name"]) || "")
    parent == prefix or String.starts_with?(name, prefix <> "/")
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
