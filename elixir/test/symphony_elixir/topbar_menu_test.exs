defmodule SymphonyElixir.TopbarMenuTest do
  use ExUnit.Case, async: true

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
end
