defmodule SymphonyElixir.RunSpec do
  @moduledoc """
  What the controller hands a runner: everything a run needs to work without
  the controller holding its state.

  It is written as `spec.json` (owner-only) under the run's directory in the
  state root — a local file even when the state store is Postgres, because it
  belongs to the runner process on this host. `docs/durable-runs.md` has the
  protocol around it.
  """

  alias SymphonyElixir.HttpServer
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
    :controller_url,
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
          controller_url: String.t() | nil,
          token: String.t() | nil
        }

  @doc "The run's directory under the state root."
  @spec dir(String.t()) :: Path.t()
  def dir(run_id) when is_binary(run_id), do: Path.join([StateStore.root(), "runs", run_id])

  @doc "Where this run's spec is written."
  @spec path(String.t()) :: Path.t()
  def path(run_id) when is_binary(run_id), do: Path.join(dir(run_id), "spec.json")

  @doc "Writes the spec owner-only; returns its path."
  @spec write(t()) :: {:ok, Path.t()} | {:error, term()}
  def write(%__MODULE__{run_id: run_id} = spec) when is_binary(run_id) do
    path = path(run_id)

    case PrivateFile.write(path, Jason.encode!(encode(spec), pretty: true)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
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
          :epoch -> raw
          :attempt -> raw
          _ -> raw
        end

      {field, value}
    end)
    |> then(&struct(__MODULE__, &1))
  end

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
