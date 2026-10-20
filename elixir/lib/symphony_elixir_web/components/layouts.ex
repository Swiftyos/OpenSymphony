defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  alias SymphonyElixir.Config
  alias SymphonyElixirWeb.StaticAssets

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:page_title, page_title())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title><%= @page_title %></title>
        <script defer src={StaticAssets.url("/vendor/phoenix_html/phoenix_html.js")}></script>
        <script defer src={StaticAssets.url("/vendor/phoenix/phoenix.js")}></script>
        <script defer src={StaticAssets.url("/vendor/phoenix_live_view/phoenix_live_view.js")}></script>
        <%!-- Order matters: factory.js uses the flow and assist modules. --%>
        <script defer src={StaticAssets.url("/factory_flow.js")}></script>
        <script defer src={StaticAssets.url("/factory_assist.js")}></script>
        <script defer src={StaticAssets.url("/factory.js")}></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: window.SymphonyHooks || {}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500&display=swap" />
        <link rel="stylesheet" href={StaticAssets.url("/dashboard.css")} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end

  defp page_title do
    case Config.instance_name() do
      name when is_binary(name) and name != "" -> "#{name} · Symphony Observability"
      _ -> "Symphony Observability"
    end
  end
end
