defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @doc """
  Posts a comment. With `id:` a comment already posted under that id is not
  posted or announced again.
  """
  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, opts \\ []) do
    case Keyword.get(opts, :id) do
      nil -> post_comment(issue_id, body)
      id -> if remember_comment(id), do: post_comment(issue_id, body), else: :ok
    end
  end

  @spec comment_exists?(String.t()) :: {:ok, boolean()}
  def comment_exists?(id) do
    {:ok, MapSet.member?(comment_ids(), id)}
  end

  defp post_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  defp remember_comment(id) do
    ids = comment_ids()

    if MapSet.member?(ids, id) do
      false
    else
      Application.put_env(:symphony_elixir, :memory_tracker_comment_ids, MapSet.put(ids, id))
      true
    end
  end

  defp comment_ids do
    Application.get_env(:symphony_elixir, :memory_tracker_comment_ids, MapSet.new())
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @spec set_stage(String.t(), String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def set_stage(issue_id, state_name, stage, opts \\ []) do
    prefix = SymphonyElixir.IssueStage.label_prefix() <> "/"
    drop = opts |> Keyword.get(:drop_labels, []) |> Enum.map(&String.downcase/1)

    issues =
      Enum.map(configured_issues(), fn
        %Issue{id: ^issue_id, labels: labels} = issue ->
          labels = Enum.reject(labels || [], &(String.starts_with?(String.downcase(&1), prefix) or String.downcase(&1) in drop))
          labels = if(stage, do: labels ++ [prefix <> stage], else: labels)
          %{issue | state: state_name, labels: Enum.uniq(labels ++ Keyword.get(opts, :add_labels, []))}

        other ->
          other
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    send_event({:memory_tracker_stage_update, issue_id, state_name, stage})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  @spec ensure_stage_labels(String.t(), [String.t()]) :: {:ok, [String.t()]}
  def ensure_stage_labels(team_key, labels) do
    send_event({:memory_tracker_ensure_labels, team_key, labels})
    {:ok, []}
  end

  @spec ensure_labels(String.t(), [String.t()]) :: {:ok, [String.t()]}
  def ensure_labels(team_key, names) do
    send_event({:memory_tracker_ensure_plain_labels, team_key, names})
    {:ok, []}
  end

  @spec ensure_group_labels(String.t(), String.t(), [String.t()]) :: {:ok, [String.t()]}
  def ensure_group_labels(team_key, group, labels) do
    send_event({:memory_tracker_ensure_group_labels, team_key, group, labels})
    {:ok, []}
  end

  # Teams come from the configured issues' identifiers (`PAY-1` -> `PAY`).
  @spec project_info([String.t()]) :: {:ok, %{String.t() => map()}}
  def project_info(slugs) do
    issues = configured_issues()

    {:ok,
     Map.new(slugs, fn slug ->
       mine = for %Issue{project_slug: ^slug} = issue <- issues, do: issue
       teams = for issue <- mine, team = SymphonyElixir.IssueStage.team(issue), uniq: true, do: team
       {slug, %{name: Enum.find_value(mine, & &1.project_name), teams: teams}}
     end)}
  end

  # Reports come from `:memory_tracker_issue_reports` (by id), else the issue itself.
  @spec fetch_issue_reports([String.t()]) :: {:ok, [map()]}
  def fetch_issue_reports(ids) do
    reports = Application.get_env(:symphony_elixir, :memory_tracker_issue_reports, %{})
    issues = Map.new(issue_entries(), &{&1.id, &1})

    {:ok, ids |> Enum.map(&(Map.get(reports, &1) || issue_report(Map.get(issues, &1)))) |> Enum.reject(&is_nil/1)}
  end

  defp issue_report(nil), do: nil

  defp issue_report(%Issue{} = issue) do
    %{id: issue.id, identifier: issue.identifier, title: issue.title, url: issue.url, state: issue.state, state_type: nil, attachments: [], comments: []}
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
