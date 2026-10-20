defmodule SymphonyElixir.IssueReport do
  @moduledoc """
  What building an issue took: tokens and cost per stage, and how often it was
  knocked back. Posted on the issue as a final report when it reaches a done
  stage.

  A knock-back is a move to an earlier stage of the flow (Test -> Implement,
  Review -> Implement). The latest stage that knocks issues back is the outer
  loop (usually review): its knock-backs split the history into rounds, and
  other knock-backs (failed tests) are counted per round. So "3 rounds of
  review, test failures 2 · 0 · 1" separates failing review from failing tests.
  """

  alias SymphonyElixir.Factory.Definition
  alias SymphonyElixir.{Pricing, Tracker, UsageLedger}

  @type rounds :: %{
          outer: String.t() | nil,
          rounds: pos_integer(),
          knockbacks: %{String.t() => pos_integer()},
          inner: [map()]
        }

  @doc """
  Posts the report on the issue.
  """
  @spec post(map(), map()) :: :ok | {:error, term()}
  def post(%{id: id, identifier: identifier}, definition) when is_binary(id) and is_binary(identifier) do
    Tracker.create_comment(id, markdown(identifier, definition))
  end

  @doc """
  The report, as Markdown.
  """
  @spec markdown(String.t(), map()) :: String.t()
  def markdown(identifier, definition) do
    %{usage: usage, moves: moves} = UsageLedger.issue_history(identifier)

    Enum.join(
      [
        "## Factory report",
        "",
        usage_table(usage, definition),
        "",
        rounds_text(rounds(moves, definition)),
        "",
        "_Posted by Agent Factory when the issue reached done._"
      ],
      "\n"
    )
  end

  # ------------------------------------------------------------------ usage

  defp usage_table([], _definition), do: "No agent usage was recorded for this issue."

  defp usage_table(usage, definition) do
    rows =
      usage
      |> Enum.group_by(& &1.stage)
      |> Enum.map(fn {stage, rows} -> {stage_name(definition, stage), order(definition, stage), totals(rows)} end)
      |> Enum.sort_by(fn {_name, order, _totals} -> order end)

    total = totals(usage)
    estimated? = Enum.any?(usage, &estimated?/1)

    lines =
      for {name, _order, t} <- rows do
        "| #{name} | #{count(t.input)} | #{count(t.cached)} | #{count(t.output)} | #{money(t.cost)} |"
      end

    Enum.join(
      [
        "| Stage | Input tokens | of which cached | Output tokens | Cost |",
        "| --- | ---: | ---: | ---: | ---: |"
      ] ++
        lines ++
        [
          "| **Total** | **#{count(total.input)}** | **#{count(total.cached)}** | **#{count(total.output)}** | **#{money(total.cost)}** |",
          "",
          "Harnesses: " <>
            (usage |> Enum.map(&"#{&1.backend} (#{&1.model})") |> Enum.uniq() |> Enum.join(", ")) <>
            "." <>
            if(estimated?, do: " Costs marked ≈ include usage recorded before Agent Factory priced it as spent, so it's priced at today's rates.", else: "")
        ],
      "\n"
    )
  end

  defp totals(rows) do
    Enum.reduce(rows, %{input: 0, cached: 0, output: 0, cost: {0.0, false}}, fn row, acc ->
      {usd, approx} = row_cost(row)
      {sum, was_approx} = acc.cost

      %{
        input: acc.input + row.input_tokens,
        cached: acc.cached + (row[:cached_input_tokens] || 0),
        output: acc.output + row.output_tokens,
        cost: {sum + (usd || 0), was_approx or approx or is_nil(usd)}
      }
    end)
  end

  defp row_cost(%{cost_micros: micros}) when is_integer(micros) and micros > 0, do: {micros / 1_000_000, false}

  defp row_cost(row) do
    case Pricing.cost_micros(row.backend, row.model, row) do
      nil -> {nil, true}
      micros -> {micros / 1_000_000, true}
    end
  end

  defp estimated?(row), do: elem(row_cost(row), 1)

  defp money({usd, approx}), do: if(approx, do: "≈ ", else: "") <> "$" <> :erlang.float_to_binary(usd * 1.0, decimals: 2)

  defp count(n) when n >= 1_000_000, do: :erlang.float_to_binary(n / 1_000_000, decimals: 1) <> "M"
  defp count(n) when n >= 1_000, do: "#{div(n, 1_000)}k"
  defp count(n), do: Integer.to_string(n)

  # ------------------------------------------------------------------ rounds

  @doc """
  Knock-backs and rounds from an issue's moves (`[from, to, at]`).
  """
  @spec rounds([list()], map()) :: rounds()
  def rounds(moves, definition) do
    knockbacks = for [from, to, _at] <- moves, order(definition, to) < order(definition, from), do: from
    outer = Enum.max_by(knockbacks, &order(definition, &1), fn -> nil end)

    inner =
      knockbacks
      |> Enum.chunk_while(
        %{},
        fn
          ^outer, acc -> {:cont, acc, %{}}
          from, acc -> {:cont, Map.update(acc, from, 1, &(&1 + 1))}
        end,
        &{:cont, &1, %{}}
      )

    %{
      outer: outer && stage_name(definition, outer),
      rounds: Enum.count(knockbacks, &(&1 == outer)) + 1,
      knockbacks: knockbacks |> Enum.frequencies() |> Map.new(fn {id, n} -> {stage_name(definition, id), n} end),
      inner: Enum.map(inner, fn round -> Map.new(round, fn {id, n} -> {stage_name(definition, id), n} end) end)
    }
  end

  @doc false
  @spec rounds_text(rounds()) :: String.t()
  def rounds_text(%{knockbacks: knockbacks}) when map_size(knockbacks) == 0,
    do: "**Rounds:** none. It went straight through without being sent back."

  def rounds_text(%{outer: outer, rounds: rounds, inner: inner, knockbacks: knockbacks}) do
    others = knockbacks |> Map.delete(outer) |> Map.keys() |> Enum.sort()

    per_round =
      for name <- others do
        counts = Enum.map(inner, &Map.get(&1, name, 0))
        "- **#{name}** sent it back #{Enum.sum(counts)}× (per #{outer} round: #{Enum.join(counts, " · ")})"
      end

    Enum.join(["**Rounds:** #{rounds} rounds of #{outer} (it sent the work back #{rounds - 1}×)." | per_round], "\n")
  end

  # ------------------------------------------------------------------ stages

  defp stage_name(_definition, nil), do: "Before stages were tracked"

  defp stage_name(definition, id) do
    case Definition.stage(definition, id) do
      %{"name" => name} -> name
      nil -> id
    end
  end

  # Flow order: left to right on the diagram, then the order stages are listed.
  defp order(_definition, nil), do: {-1, -1}

  defp order(definition, id) do
    stages = definition["stages"] || []

    case Enum.find_index(stages, &(&1["id"] == id)) do
      nil -> {1_000_000, 0}
      index -> {get_in(Enum.at(stages, index), ["position", "x"]) || 0, index}
    end
  end
end
