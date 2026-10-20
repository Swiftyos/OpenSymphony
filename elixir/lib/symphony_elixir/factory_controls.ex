defmodule SymphonyElixir.FactoryControls do
  @moduledoc """
  Runtime controls for a team's agent stages, as set from the dashboard: pause
  dispatch, cap concurrent agents, and choose the default harness and thinking
  level. Issue labels still win over the harness and thinking defaults.

  The values live on the stage in the team's factory definition
  (`SymphonyElixir.Factory.Store`), keyed here by `{team, stage_id}`.
  """

  alias SymphonyElixir.Factory.{Definition, Store}

  @type key :: {String.t() | nil, String.t()} | String.t() | nil
  @type stage_controls :: %{
          paused: boolean(),
          max_agents: pos_integer() | nil,
          backend: String.t() | nil,
          effort: String.t() | nil
        }

  @field_map %{"paused" => "paused", "approval" => "approval", "max_agents" => "max_agents", "backend" => "harness", "effort" => "effort"}

  @spec get(key()) :: stage_controls()
  def get(key) do
    {team, stage_id} = normalize_key(key)

    case Definition.stage(Store.get(team), stage_id) do
      %{} = stage -> from_stage(stage)
      nil -> %{paused: false, max_agents: nil, backend: nil, effort: nil}
    end
  end

  @doc """
  Controls for every agent-run stage of a team's factory, keyed by stage id.
  """
  @spec all(String.t() | nil) :: %{String.t() => stage_controls()}
  def all(team \\ nil) do
    Store.get(team)["stages"]
    |> Enum.filter(&(&1["kind"] in ["queue", "agent"]))
    |> Map.new(&{&1["id"], from_stage(&1)})
  end

  @spec paused?(key()) :: boolean()
  def paused?(key), do: get(key).paused

  @doc """
  Updates one control (`paused`, `approval`, `max_agents`, `backend`, `effort`) on a stage.
  """
  @spec put(key(), String.t(), term(), String.t()) :: {:ok, stage_controls()} | {:error, term()}
  def put(key, field, value, updated_by \\ "dashboard") do
    {team, stage_id} = normalize_key(key)

    with {:ok, stage_field} <- Map.fetch(@field_map, field) |> or_error({:invalid_control, field, value}),
         %{} = stage <- Definition.stage(Store.get(team), stage_id) || {:error, {:unknown_stage, stage_id}},
         true <- stage["kind"] in ["queue", "agent"] || {:error, {:unknown_stage, stage_id}},
         {:ok, definition} <-
           Store.put_stage_field(team || Store.default_team(), stage_id, stage_field, value, updated_by) do
      {:ok, from_stage(Definition.stage(definition, stage_id))}
    else
      {:error, [message | _]} -> {:error, {:invalid_control, field, value, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec reset() :: :ok
  def reset, do: Store.reset()

  defp from_stage(stage) do
    %{paused: stage["paused"] == true, max_agents: stage["max_agents"], backend: stage["harness"], effort: stage["effort"]}
  end

  # Legacy callers pass a bare stage id for the default factory.
  defp normalize_key({team, stage_id}), do: {team, stage_id || "todo"}
  defp normalize_key(stage_id) when is_binary(stage_id), do: {nil, stage_id}
  defp normalize_key(nil), do: {nil, "todo"}

  defp or_error({:ok, value}, _error), do: {:ok, value}
  defp or_error(:error, error), do: {:error, error}
end
