defmodule SymphonyElixir.InsightsLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config) end)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64))
    )

    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    write_workflow_file!(Workflow.workflow_file_path())
    :ok
  end

  test "without an observability section the page says how to set it up" do
    {:ok, view, html} = live(build_conn(), "/insights")
    assert html =~ "Traces &amp; metrics"

    html = render_async(view)
    assert html =~ "aren&#39;t set up"
    assert html =~ "source-chip is-off"
  end

  test "range, issue and trace live in the URL" do
    {:ok, view, _html} = live(build_conn(), "/insights?range=week&issue=MT-1&trace=abc")
    html = render_async(view)
    assert html =~ ~s(id="issue-insights")
    assert html =~ "No traces for this issue yet."

    view |> element("button[phx-value-range=hour]") |> render_click()
    assert_patch(view, "/insights?issue=MT-1&range=hour&trace=abc")

    render_hook(view, "open_trace", %{"id" => "def"})
    assert_patch(view, "/insights?issue=MT-1&range=hour&trace=def")

    view |> element("button", "Close") |> render_click()
    assert_patch(view, "/insights?range=hour")

    send(view.pid, :refresh)
    assert render_async(view) =~ "Traces &amp; metrics"
  end

  test "an unknown range falls back to a day" do
    {:ok, view, _html} = live(build_conn(), "/insights?range=decade")
    assert render_async(view) =~ ~s(class="fx-seg-btn is-active" phx-click="pick_range" phx-value-range="day")
  end
end
