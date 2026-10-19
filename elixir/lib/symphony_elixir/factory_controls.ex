defmodule SymphonyElixir.FactoryControls do
  @moduledoc """
  Runtime controls for each agent stage of the factory, set from the dashboard.

  Per stage an operator can pause dispatch, cap concurrent agents, and choose the
  default harness and thinking effort. Issue labels still win over these
  defaults, so a one-off `claude` or `thinking/max` label keeps working.

  Values live in a public ETS table (read on every dispatch decision, so reads
  must be cheap) and are persisted to JSON on each change.
  """

  use GenServer
  require Logger

  @table :symphony_factory_controls
  @stages ["todo", "implement", "rework", "merge"]
  @backends ["codex", "claude", "opencode"]
  @efforts ["low", "medium", "high", "xhigh", "max"]

  @type stage_controls :: %{
          paused: boolean(),
          max_agents: pos_integer() | nil,
          backend: String.t() | nil,
          effort: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec stages() :: [String.t()]
  def stages, do: @stages

  @spec get(String.t() | nil) :: stage_controls()
  def get(stage) do
    key = stage || "todo"

    with true <- :ets.whereis(@table) != :undefined,
         [{^key, controls}] <- :ets.lookup(@table, key) do
      controls
    else
      _ -> default()
    end
  end

  @spec all() :: %{String.t() => stage_controls()}
  def all, do: Map.new(@stages, &{&1, get(&1)})

  @spec paused?(String.t() | nil) :: boolean()
  def paused?(stage), do: get(stage).paused

  @doc """
  Updates one field of a stage's controls. Returns the new controls.
  """
  @spec put(String.t(), String.t(), term()) :: {:ok, stage_controls()} | {:error, term()}
  def put(stage, field, value) do
    GenServer.call(__MODULE__, {:put, stage, field, value})
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    load(path)
    {:ok, %{path: path}}
  end

  @impl true
  def handle_call({:put, stage, field, value}, _from, state) do
    with :ok <- validate_stage(stage),
         {:ok, field, value} <- cast(field, value) do
      controls = Map.put(get(stage), field, value)
      :ets.insert(@table, {stage, controls})
      persist(state.path)
      {:reply, {:ok, controls}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp default, do: %{paused: false, max_agents: nil, backend: nil, effort: nil}

  defp validate_stage(stage) when stage in @stages, do: :ok
  defp validate_stage(stage), do: {:error, {:unknown_stage, stage}}

  defp cast("paused", value) when is_boolean(value), do: {:ok, :paused, value}
  defp cast("max_agents", nil), do: {:ok, :max_agents, nil}
  defp cast("max_agents", value) when is_integer(value) and value > 0 and value <= 100, do: {:ok, :max_agents, value}
  defp cast("backend", value) when value in [nil | @backends], do: {:ok, :backend, value}
  defp cast("effort", value) when value in [nil | @efforts], do: {:ok, :effort, value}
  defp cast(field, value), do: {:error, {:invalid_control, field, value}}

  defp default_path do
    case Application.get_env(:symphony_elixir, :factory_controls_path, :default) do
      :default -> Path.expand("~/.symphony/factory_controls.json")
      path -> path
    end
  end

  defp persist(nil), do: :ok

  defp persist(path) do
    body = all() |> Jason.encode!(pretty: true)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> Logger.warning("Factory controls save failed path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp load(nil), do: :ok

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = stages} <- Jason.decode(body) do
      Enum.each(stages, fn {stage, raw} -> load_stage(stage, raw) end)
    else
      {:error, :enoent} -> :ok
      other -> Logger.warning("Factory controls load skipped path=#{path} reason=#{inspect(other, limit: 5)}")
    end
  end

  defp load_stage(stage, raw) when stage in @stages and is_map(raw) do
    controls =
      Enum.reduce(raw, default(), fn {field, value}, acc ->
        case cast(field, value) do
          {:ok, key, cast_value} -> Map.put(acc, key, cast_value)
          {:error, _reason} -> acc
        end
      end)

    :ets.insert(@table, {stage, controls})
  end

  defp load_stage(_stage, _raw), do: :ok
end
