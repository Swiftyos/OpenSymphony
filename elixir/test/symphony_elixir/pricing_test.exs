defmodule SymphonyElixir.PricingTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Pricing

  @catalog %{
    "deepseek/flash" => %{
      "prompt" => "0.00000015",
      "completion" => "0.0000006",
      "input_cache_read" => "0.000000003",
      "overrides" => [
        %{"utc_days" => ["monday"], "utc_start" => 100, "utc_end" => 400, "prompt" => "0.0000003", "completion" => "0.0000012", "input_cache_read" => "0.000000006"},
        %{"utc_days" => ["tuesday"], "utc_start" => 2200, "utc_end" => 200, "prompt" => "0.000001", "completion" => "0.000002"},
        %{"utc_days" => ["wednesday"], "utc_start" => 2300, "utc_end" => 0, "prompt" => "0.000002", "completion" => 0.000004}
      ]
    },
    "plain/model" => %{"prompt" => "not a number", "completion" => "0.000001"}
  }

  setup do
    Pricing.put_catalog(@catalog)
    on_exit(fn -> Pricing.put_catalog(%{}) end)
    :ok
  end

  defp at(iso), do: iso |> DateTime.from_iso8601() |> elem(1)

  test "fixed rates price cached input at its own rate, or at the input rate" do
    pricing = %{"claude" => %{"input_per_mtok" => 3, "output_per_mtok" => 15, "cached_input_per_mtok" => 0.3}, "codex" => %{"input_per_mtok" => 2}}
    delta = %{input_tokens: 1_000_000, cached_input_tokens: 800_000, output_tokens: 100_000}

    # 200k uncached * 3 + 800k cached * 0.3 + 100k out * 15, in micro-dollars
    assert Pricing.cost_micros("claude", "x", delta, DateTime.utc_now(), pricing) == 600_000 + 240_000 + 1_500_000
    assert Pricing.cost_micros("codex", "x", delta, DateTime.utc_now(), pricing) == 2_000_000
    assert Pricing.cost_micros("opencode", "x", delta, DateTime.utc_now(), pricing) == nil
    # Cached tokens never exceed input.
    assert Pricing.cost_micros("claude", "x", %{input_tokens: 10, cached_input_tokens: 99}, DateTime.utc_now(), pricing) == 3
  end

  test "OpenRouter prices follow the model's time-of-day windows" do
    pricing = %{"codex" => %{"openrouter_model" => "deepseek/flash"}}

    # Monday 02:00 UTC is in the peak window; 05:00 isn't.
    assert %{input: 0.3, output: 1.2, cached_input: 0.006} = round_rates(Pricing.rates("codex", "m", at("2026-10-19T02:00:00Z"), pricing))
    assert %{input: 0.15, output: 0.6, cached_input: 0.003} = round_rates(Pricing.rates("codex", "m", at("2026-10-19T05:00:00Z"), pricing))
    # A window that wraps past midnight, and one that runs to midnight (end 0).
    assert %{input: 1.0} = round_rates(Pricing.rates("codex", "m", at("2026-10-20T23:30:00Z"), pricing))
    assert %{input: 1.0} = round_rates(Pricing.rates("codex", "m", at("2026-10-20T01:00:00Z"), pricing))
    assert %{input: 2.0, output: 4.0} = round_rates(Pricing.rates("codex", "m", at("2026-10-21T23:30:00Z"), pricing))

    # Without a cache-read price, cache reads cost what input does; bad numbers count as 0.
    assert %{input: 0.0, cached_input: 0.0, output: 1.0} = round_rates(Pricing.rates("codex", "m", DateTime.utc_now(), %{"codex" => %{"openrouter_model" => "plain/model"}}))
    # A model OpenRouter doesn't list (or before the catalog loads) has no price.
    assert Pricing.rates("codex", "m", DateTime.utc_now(), %{"codex" => %{"openrouter_model" => "nope/nope"}}) == nil
  end

  test "an invalid config prices nothing" do
    File.write!(Workflow.workflow_file_path(), "---\npricing:\n  codex: 5\n---\nPrompt.\n")
    SymphonyElixir.WorkflowStore.force_reload()
    assert Pricing.rates("codex", "m") == nil
  end

  test "rates come from the config by default, harness and model first" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert Pricing.rates("codex", "m") == nil
    assert Pricing.cost_micros("codex", "m", %{input_tokens: 1}) == nil
    pricing = %{"codex/special" => %{"input_per_mtok" => 9}, "codex" => %{"input_per_mtok" => 1}}
    assert %{input: 9} = Pricing.rates("codex", "special", DateTime.utc_now(), pricing)
  end

  test "the catalog refreshes in the background only when OpenRouter pricing is used" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    parent = self()
    {:ok, pid} = Pricing.start_link(name: :pricing_test, fetch: fn -> send(parent, :fetched) && {:ok, %{}} end)
    refute_receive :fetched, 100
    GenServer.stop(pid)

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
    pricing:
      codex:
        openrouter_model: deepseek/flash
    ---
    Prompt.
    """)

    SymphonyElixir.WorkflowStore.force_reload()

    fetch = fn -> send(parent, :fetched) && {:ok, %{"x/y" => %{}}} end
    {:ok, pid} = Pricing.start_link(name: :pricing_test_on, fetch: fetch)
    assert_receive :fetched, 1_000
    GenServer.stop(pid)
    assert Pricing.rates("codex", "m") == nil

    log =
      capture_log(fn ->
        failing = fn -> send(parent, :fetched) && {:error, :down} end
        {:ok, pid} = Pricing.start_link(name: :pricing_test_err, fetch: failing)
        assert_receive :fetched, 1_000
        GenServer.stop(pid)
      end)

    assert log =~ "OpenRouter price refresh failed: :down"
  end

  test "fetching the catalog reads OpenRouter's model list" do
    Application.put_env(:symphony_elixir, :pricing_req_options, plug: fn conn -> Req.Test.json(conn, %{"data" => [%{"id" => "a/b", "pricing" => %{"prompt" => "1"}}, %{"id" => "c/d"}]}) end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :pricing_req_options) end)
    assert Pricing.fetch_catalog() == {:ok, %{"a/b" => %{"prompt" => "1"}, "c/d" => %{}}}

    Application.put_env(:symphony_elixir, :pricing_req_options, plug: fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
    assert Pricing.fetch_catalog() == {:error, {:http_status, 503}}

    refused = fn conn -> Req.Test.transport_error(conn, :econnrefused) end
    Application.put_env(:symphony_elixir, :pricing_req_options, plug: refused)
    assert {:error, %Req.TransportError{reason: :econnrefused}} = Pricing.fetch_catalog()
  end

  defp round_rates(rates), do: Map.new(rates, fn {k, v} -> {k, Float.round(v * 1.0, 4)} end)
end
