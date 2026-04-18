defmodule SymphonyElixir.AgentRoute do
  @moduledoc """
  Resolves the effective backend and effort for a Linear issue from labels.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @backend_labels %{
    "codex" => "codex",
    "claude" => "claude",
    "opencode" => "opencode"
  }

  @thinking_labels %{
    "thinking/low" => "low",
    "thinking/medium" => "medium",
    "thinking/high" => "high",
    "thinking/xhigh" => "xhigh",
    "thinking/max" => "max"
  }

  # Preserve existing tickets that still carry the old Linear label prefix.
  @legacy_effort_labels %{
    "effort/low" => "low",
    "effort/medium" => "medium",
    "effort/high" => "high",
    "effort/xhigh" => "xhigh",
    "effort/max" => "max"
  }

  @effort_labels Map.merge(@thinking_labels, @legacy_effort_labels)

  @effort_values ["low", "medium", "high", "xhigh", "max"]

  defstruct [:backend, :effort, warnings: []]

  @type t :: %__MODULE__{
          backend: String.t(),
          effort: String.t() | nil,
          warnings: [String.t()]
        }

  @spec resolve(Issue.t(), term()) :: t()
  def resolve(%Issue{} = issue, settings \\ Config.settings!()) do
    labels =
      issue
      |> Issue.label_names()
      |> Enum.map(&normalize_label/1)
      |> Enum.reject(&is_nil/1)

    backend_matches =
      labels
      |> Enum.map(&Map.get(@backend_labels, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    effort_matches =
      labels
      |> Enum.map(&Map.get(@effort_labels, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    default_backend = settings.agent.backend
    default_effort = Schema.normalize_optional_effort(settings.agent.default_effort)

    {backend, backend_warnings} =
      case backend_matches do
        [backend] ->
          {backend, []}

        [] ->
          {default_backend, []}

        conflicts ->
          {default_backend,
           [
             "multiple backend labels (#{Enum.join(conflicts, ", ")}) found; falling back to default backend #{default_backend}"
           ]}
      end

    {effort, effort_warnings} =
      case effort_matches do
        [effort] ->
          {effort, []}

        [] ->
          {default_effort, []}

        conflicts when is_binary(default_effort) ->
          {default_effort,
           [
             "multiple thinking labels (#{Enum.join(conflicts, ", ")}) found; falling back to default effort #{default_effort}"
           ]}

        conflicts ->
          {nil,
           [
             "multiple thinking labels (#{Enum.join(conflicts, ", ")}) found; ignoring effort override"
           ]}
      end

    %__MODULE__{
      backend: backend,
      effort: effort,
      warnings: backend_warnings ++ effort_warnings
    }
  end

  @spec backend_labels() :: [String.t()]
  def backend_labels, do: Map.keys(@backend_labels)

  @spec effort_labels() :: [String.t()]
  def effort_labels, do: Map.keys(@thinking_labels)

  @spec effort_values() :: [String.t()]
  def effort_values, do: @effort_values

  @spec local_only_backend?(String.t() | nil) :: boolean()
  def local_only_backend?("opencode"), do: true
  def local_only_backend?(_backend), do: false

  # Codex natively supports low/medium/high/xhigh. Symphony's "max" tier is above
  # xhigh but Codex has no higher level, so both "max" and "xhigh" collapse to xhigh.
  @spec codex_effort(String.t() | nil) :: String.t() | nil
  def codex_effort("max"), do: "xhigh"
  def codex_effort("xhigh"), do: "xhigh"
  def codex_effort(effort) when effort in @effort_values, do: effort
  def codex_effort(_effort), do: nil

  @spec claude_effort(String.t() | nil) :: String.t() | nil
  def claude_effort(effort) when effort in @effort_values, do: effort
  def claude_effort(_effort), do: nil

  # OpenCode natively supports low/medium/high/max. Symphony's "xhigh" has no
  # OpenCode counterpart, so it collapses to max.
  @spec opencode_variant(String.t() | nil) :: String.t() | nil
  def opencode_variant("xhigh"), do: "max"
  def opencode_variant(effort) when effort in @effort_values, do: effort
  def opencode_variant(_effort), do: nil

  defp normalize_label(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_label(_value), do: nil
end
