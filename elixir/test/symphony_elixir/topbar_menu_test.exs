defmodule SymphonyElixir.TopbarMenuTest do
  use SymphonyElixir.TestSupport

  import Phoenix.LiveViewTest

  alias SymphonyElixir.Auth

  # The dashboard re-renders many times a second while agents stream. The user
  # menu is a <details>; LiveView must leave the browser's `open` attribute
  # alone, or the menu closes again as soon as it opens.
  test "the user menu keeps the browser's open attribute across updates" do
    user = %Auth.User{id: "usr_1", username: "ada", name: "Ada", local: false, admin: true, teams: [], projects: []}

    html = render_component(&SymphonyElixirWeb.Topbar.topbar/1, current_user: user, inner_block: [])

    assert html =~ ~s(id="user-menu")
    assert html =~ "ignore_attrs"
    assert html =~ "open"
  end

  test "the user menu links to MCP tokens only when MCP is enabled" do
    user = %Auth.User{id: "usr_1", username: "ada", name: "Ada", local: false, admin: true, teams: [], projects: []}

    write_mcp_config!(false)
    refute render_component(&SymphonyElixirWeb.Topbar.topbar/1, current_user: user, inner_block: []) =~ ~s(href="/account/mcp")

    write_mcp_config!(true)
    assert render_component(&SymphonyElixirWeb.Topbar.topbar/1, current_user: user, inner_block: []) =~ ~s(href="/account/mcp")
  end

  defp write_mcp_config!(enabled?) do
    write_workflow_file!(Workflow.workflow_file_path(), server_host: "127.0.0.1")
    path = Workflow.workflow_file_path()
    content = File.read!(path)

    content =
      if enabled?,
        do: String.replace(content, "\nserver:\n", "\nserver:\n  mcp:\n    enabled: true\n", global: false),
        else: content

    File.write!(path, content)
    WorkflowStore.force_reload()
  end
end
