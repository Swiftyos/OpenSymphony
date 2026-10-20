defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback set_stage(String.t(), String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  @callback ensure_stage_labels(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @doc """
  Moves an issue to `state_name` and makes `stage` its only factory stage label
  (`nil` removes stage labels). Pass `api_key:` to make the change as a
  specific Linear user.
  """
  @spec set_stage(String.t(), String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def set_stage(issue_id, state_name, stage, opts \\ []) do
    adapter().set_stage(issue_id, state_name, stage, opts)
  end

  @doc """
  Makes sure a team has a `<prefix>` label group with a child label for every
  stage label, creating what's missing. Returns the labels it created.
  """
  @spec ensure_stage_labels(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def ensure_stage_labels(team_key, labels) do
    adapter().ensure_stage_labels(team_key, labels)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
