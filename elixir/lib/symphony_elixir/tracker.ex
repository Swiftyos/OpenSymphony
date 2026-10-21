defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback comment_exists?(String.t()) :: {:ok, boolean()} | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback set_stage(String.t(), String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  @callback ensure_stage_labels(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  @callback ensure_labels(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  @callback ensure_group_labels(String.t(), String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  @callback project_info([String.t()]) :: {:ok, %{String.t() => map()}} | {:error, term()}
  @callback fetch_issue_reports([String.t()]) :: {:ok, [map()]} | {:error, term()}

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

  @doc """
  Posts a comment on an issue. Pass `id:` (a UUID string) to make the write
  idempotent: creating the same comment again returns `:ok` without posting a
  second one.
  """
  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, opts \\ []) do
    adapter().create_comment(issue_id, body, opts)
  end

  @doc """
  Whether a comment with this id exists on the tracker.
  """
  @spec comment_exists?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def comment_exists?(id) do
    adapter().comment_exists?(id)
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

  @doc """
  Makes sure a team has these plain labels (it or the workspace), creating any
  that are missing.
  """
  @spec ensure_labels(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def ensure_labels(team_key, names), do: adapter().ensure_labels(team_key, names)

  @doc """
  Makes sure a team has a `group` label group with these child labels (e.g. the
  `repo` group with one label per project repo), creating what's missing.
  """
  @spec ensure_group_labels(String.t(), String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def ensure_group_labels(team_key, group, labels), do: adapter().ensure_group_labels(team_key, group, labels)

  @doc """
  Each project's (by slug) name and team keys: `%{name: ..., teams: [...]}`.
  """
  @spec project_info([String.t()]) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def project_info(slugs), do: adapter().project_info(slugs)

  @doc """
  What happened on some issues (by id): `%{id, identifier, title, url, state,
  state_type, attachments: [%{title, url}], comments: [body]}`, comments newest
  first.
  """
  @spec fetch_issue_reports([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_reports(ids), do: adapter().fetch_issue_reports(ids)

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
