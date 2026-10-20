defmodule SymphonyElixirWeb.StaticAssetController do
  @moduledoc """
  Serves the dashboard's embedded CSS and JavaScript assets.
  """

  use Phoenix.Controller, formats: []

  alias Plug.Conn
  alias SymphonyElixirWeb.StaticAssets

  @spec dashboard_css(Conn.t(), map()) :: Conn.t()
  def dashboard_css(conn, _params), do: serve(conn, "/dashboard.css")

  @spec factory_js(Conn.t(), map()) :: Conn.t()
  def factory_js(conn, _params), do: serve(conn, "/factory.js")

  @spec factory_flow_js(Conn.t(), map()) :: Conn.t()
  def factory_flow_js(conn, _params), do: serve(conn, "/factory_flow.js")

  @spec factory_assist_js(Conn.t(), map()) :: Conn.t()
  def factory_assist_js(conn, _params), do: serve(conn, "/factory_assist.js")

  @spec phoenix_html_js(Conn.t(), map()) :: Conn.t()
  def phoenix_html_js(conn, _params), do: serve(conn, "/vendor/phoenix_html/phoenix_html.js")

  @spec phoenix_js(Conn.t(), map()) :: Conn.t()
  def phoenix_js(conn, _params), do: serve(conn, "/vendor/phoenix/phoenix.js")

  @spec phoenix_live_view_js(Conn.t(), map()) :: Conn.t()
  def phoenix_live_view_js(conn, _params), do: serve(conn, "/vendor/phoenix_live_view/phoenix_live_view.js")

  @logo_types %{".svg" => "image/svg+xml", ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".webp" => "image/webp"}
  @max_logo_bytes 512_000

  @doc """
  The operator's brand logo from `instance.logo`. The file stays on the
  server's disk; it is never part of the repo. SVGs are served with a
  CSP that blocks scripts, in case one is opened directly.
  """
  @spec logo(Conn.t(), map()) :: Conn.t()
  def logo(conn, _params) do
    with path when is_binary(path) <- SymphonyElixir.Config.instance_logo(),
         {:ok, type} <- Map.fetch(@logo_types, path |> Path.extname() |> String.downcase()),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_logo_bytes <- File.stat(path),
         {:ok, body} <- File.read(path) do
      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=300")
      |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  defp serve(conn, path) do
    case StaticAssets.fetch(path) do
      {:ok, content_type, body} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=31536000")
        |> send_resp(200, body)

      :error ->
        send_resp(conn, 404, "Not Found")
    end
  end
end
