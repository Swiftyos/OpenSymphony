defmodule SymphonyElixir.RunSpec do
  @moduledoc """
  What the controller hands a runner: everything a run needs to work without
  the controller holding its state.

  It is written as `spec.json` (owner-only) under the run's directory in the
  state root — a local file even when the state store is Postgres, because it
  belongs to the runner process on this host. `docs/durable-runs.md` has the
  protocol around it.

  `environment` carries the resolved `SymphonyElixir.Environment` as a plain
  map (see `SymphonyElixir.Environment.to_map/1`): `name`, `image`, `resources`,
  `services`, `setup`, `egress_extra`, `digest`, and `repo_file`. It is nil when
  the platform has no environment catalog. A Kubernetes launcher renders the
  runner's init containers and service sidecars from it; it must not re-resolve
  the repository file, because the runner pod does not read controller state.
  """

  alias SymphonyElixir.{Config, GitMirror, HttpServer}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrivateFile
  alias SymphonyElixir.StateStore

  @fields [
    :run_id,
    :epoch,
    :attempt,
    :issue,
    :worker_host,
    :backend,
    :effort,
    :account,
    :environment,
    :controller_url,
    :git_mirror_url,
    :target_branch,
    :token
  ]

  @issue_fields [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :project_id,
    :project_slug,
    :project_name,
    :branch_name,
    :url,
    :assignee_id,
    :labels,
    :assigned_to_worker,
    :created_at,
    :updated_at,
    :blocked_by
  ]

  @enforce_keys [:run_id, :epoch]
  defstruct @fields

  @type t :: %__MODULE__{
          run_id: String.t(),
          epoch: pos_integer(),
          attempt: non_neg_integer() | nil,
          issue: map(),
          worker_host: String.t() | nil,
          backend: String.t() | nil,
          effort: String.t() | nil,
          account: %{backend: String.t(), id: String.t()} | nil,
          environment: map() | nil,
          controller_url: String.t() | nil,
          git_mirror_url: String.t() | nil,
          target_branch: String.t() | nil,
          token: String.t() | nil
        }

  @doc "The run's directory under the state root."
  @spec dir(String.t()) :: Path.t()
  def dir(run_id) when is_binary(run_id), do: Path.join([StateStore.root(), "runs", run_id])

  @doc "Where this run's spec is written."
  @spec path(String.t()) :: Path.t()
  def path(run_id) when is_binary(run_id), do: Path.join(dir(run_id), "spec.json")

  @doc "The spec as the JSON document written to `spec.json`."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = spec), do: encode(spec)

  @doc """
  Writes the spec owner-only; returns its path.

  It writes the spec exactly as given and reads no config: the controller
  fills `git_mirror_url` and `target_branch` with `attach_git_mirror/2`,
  passing the settings it launches the run with, before it writes the spec.
  """
  @spec write(t()) :: {:ok, Path.t()} | {:error, term()}
  def write(%__MODULE__{run_id: run_id} = spec) when is_binary(run_id) do
    path = path(run_id)

    case PrivateFile.write(path, Jason.encode!(to_map(spec), pretty: true)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Adds the read-only git mirror URL and the target branch when this
  controller has the cache of the issue's project repo
  (`SymphonyElixir.GitMirror.mirror_for/2`). Values already set are kept.
  """
  @spec attach_git_mirror(t(), Config.Schema.t()) :: t()
  def attach_git_mirror(%__MODULE__{} = spec, %Config.Schema{} = settings) do
    case GitMirror.mirror_for(spec, settings) do
      %{url: url, target_branch: target_branch} ->
        %{spec | git_mirror_url: spec.git_mirror_url || url, target_branch: spec.target_branch || target_branch}

      nil ->
        spec
    end
  end

  @doc "Reads a spec written with `write/1`."
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = document} <- Jason.decode(body) do
      {:ok, decode(document)}
    end
  end

  @doc "Rebuilds the Linear issue the run works on."
  @spec to_issue(t()) :: Issue.t()
  def to_issue(%__MODULE__{issue: issue}), do: issue_map(issue)

  @doc "The controller URL for the running endpoint, or nil when no server is bound."
  @spec controller_url(non_neg_integer() | nil) :: String.t() | nil
  def controller_url(port \\ HttpServer.bound_port())

  def controller_url(port) when is_integer(port) and port > 0, do: "http://127.0.0.1:#{port}"
  def controller_url(_port), do: nil

  defp encode(spec) do
    Map.new(@fields, fn field ->
      value = Map.get(spec, field)

      encoded =
        case field do
          :issue -> encode_issue(value)
          :account -> encode_account(value)
          :environment -> encode_environment(value)
          _ -> value
        end

      {Atom.to_string(field), encoded}
    end)
  end

  defp decode(document) do
    Map.new(@fields, fn field ->
      raw = Map.get(document, Atom.to_string(field))

      value =
        case field do
          :issue -> decode_issue(raw)
          :account -> decode_account(raw)
          :environment -> decode_environment(raw)
          :epoch -> raw
          :attempt -> raw
          _ -> raw
        end

      {field, value}
    end)
    |> then(&struct(__MODULE__, &1))
  end

  defp encode_environment(nil), do: nil
  defp encode_environment(%SymphonyElixir.Environment{} = environment), do: SymphonyElixir.Environment.to_map(environment)
  defp encode_environment(%{} = environment), do: encode_value(environment)
  defp encode_environment(_environment), do: nil

  defp decode_environment(%{} = environment), do: decode_value(environment)
  defp decode_environment(_environment), do: nil

  defp encode_issue(%Issue{} = issue), do: issue |> Map.from_struct() |> Map.new(fn {key, value} -> {key, encode_value(value)} end)

  defp encode_issue(%{} = issue), do: Map.new(issue, fn {key, value} -> {key, encode_value(value)} end)
  defp encode_issue(_issue), do: %{}

  defp encode_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_value(%Date{} = value), do: Date.to_iso8601(value)
  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)
  defp encode_value(%{} = value) when not is_struct(value), do: Map.new(value, fn {key, item} -> {key, encode_value(item)} end)
  defp encode_value(value), do: value

  defp decode_issue(%{} = issue) do
    issue_map =
      Map.new(issue, fn {key, value} ->
        key = if is_binary(key) and key in Enum.map(@issue_fields, &Atom.to_string/1), do: String.to_existing_atom(key), else: key
        {key, decode_value(value)}
      end)

    issue_map(issue_map)
  end

  defp decode_issue(_issue), do: %Issue{}

  defp issue_map(%Issue{} = issue), do: issue

  defp issue_map(%{} = issue) do
    issue =
      issue
      |> Map.new(fn {key, value} ->
        key = if is_binary(key), do: safe_atom(key, @issue_fields), else: key
        {key, value}
      end)
      |> Map.put_new(:blocked_by, [])
      |> Map.put_new(:labels, [])
      |> Map.put_new(:assigned_to_worker, true)

    struct(Issue, Map.take(issue, @issue_fields))
  end

  defp decode_value(value) when is_list(value), do: Enum.map(value, &decode_value/1)

  defp decode_value(%{} = value) when not is_struct(value) do
    Map.new(value, fn {key, item} ->
      key = if is_binary(key), do: safe_atom(key, [:id, :identifier, :state]), else: key
      {key, decode_value(item)}
    end)
  end

  defp decode_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> value
    end
  end

  defp decode_value(value), do: value

  defp safe_atom(key, allowed) do
    atom = Enum.find(allowed, fn field -> Atom.to_string(field) == key end)
    atom || key
  end

  defp encode_account(nil), do: nil

  defp encode_account(%{backend: backend, id: id}), do: %{"backend" => backend, "id" => id}
  defp encode_account(%{"backend" => backend, "id" => id}), do: %{"backend" => backend, "id" => id}
  defp encode_account(_account), do: nil

  defp decode_account(%{"backend" => backend, "id" => id}) when is_binary(backend) and is_binary(id),
    do: %{backend: backend, id: id}

  defp decode_account(_account), do: nil
end
