defmodule SymphonyElixirWeb.StaticAssets do
  @moduledoc false

  @dashboard_css_path Path.expand("../../priv/static/dashboard.css", __DIR__)
  @factory_js_path Path.expand("../../priv/static/factory.js", __DIR__)
  @factory_flow_js_path Path.expand("../../priv/static/factory_flow.js", __DIR__)
  @factory_assist_js_path Path.expand("../../priv/static/factory_assist.js", __DIR__)
  @logo_css_path Path.expand("../../priv/static/agent_factory_logo.css", __DIR__)
  @brand_dir Path.expand("../../priv/static/brand", __DIR__)
  # Favicons, served at the paths browsers ask for unprompted.
  @brand_files %{
    "/favicon.ico" => {"image/x-icon", "favicon.ico"},
    "/favicon.svg" => {"image/svg+xml", "favicon.svg"},
    "/favicon-16.png" => {"image/png", "favicon-16.png"},
    "/favicon-32.png" => {"image/png", "favicon-32.png"},
    "/apple-touch-icon.png" => {"image/png", "apple-touch-icon-180.png"}
  }
  @phoenix_html_js_path Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @phoenix_js_path Application.app_dir(:phoenix, "priv/static/phoenix.js")
  @phoenix_live_view_js_path Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.js")

  @external_resource @dashboard_css_path
  @external_resource @factory_js_path
  @external_resource @factory_flow_js_path
  @external_resource @factory_assist_js_path
  @external_resource @logo_css_path
  for {_path, {_type, file}} <- @brand_files, do: @external_resource(Path.join(@brand_dir, file))
  @external_resource @phoenix_html_js_path
  @external_resource @phoenix_js_path
  @external_resource @phoenix_live_view_js_path

  @dashboard_css File.read!(@dashboard_css_path)
  @factory_js File.read!(@factory_js_path)
  @factory_flow_js File.read!(@factory_flow_js_path)
  @factory_assist_js File.read!(@factory_assist_js_path)
  @logo_css File.read!(@logo_css_path)
  @phoenix_html_js File.read!(@phoenix_html_js_path)
  @phoenix_js File.read!(@phoenix_js_path)
  @phoenix_live_view_js File.read!(@phoenix_live_view_js_path)

  @brand_assets Map.new(@brand_files, fn {path, {type, file}} -> {path, {type, File.read!(Path.join(@brand_dir, file))}} end)

  @assets Map.merge(@brand_assets, %{
            "/dashboard.css" => {"text/css", @dashboard_css},
            "/agent_factory_logo.css" => {"text/css", @logo_css},
            "/factory.js" => {"application/javascript", @factory_js},
            "/factory_flow.js" => {"application/javascript", @factory_flow_js},
            "/factory_assist.js" => {"application/javascript", @factory_assist_js},
            "/vendor/phoenix_html/phoenix_html.js" => {"application/javascript", @phoenix_html_js},
            "/vendor/phoenix/phoenix.js" => {"application/javascript", @phoenix_js},
            "/vendor/phoenix_live_view/phoenix_live_view.js" => {"application/javascript", @phoenix_live_view_js}
          })

  @doc "The favicon paths, routed to `StaticAssetController.asset/2`."
  @spec brand_paths() :: [String.t()]
  def brand_paths, do: Map.keys(@brand_files)

  # Content hashes for cache busting: assets are served with a one-year cache,
  # so pages link to `path?v=<hash>` and an upgrade changes the URL.
  @versions Map.new(@assets, fn {path, {_type, body}} ->
              {path, :crypto.hash(:sha256, body) |> Base.url_encode64(padding: false) |> binary_part(0, 10)}
            end)

  @doc """
  The cache-busted URL for an embedded asset.
  """
  @spec url(String.t()) :: String.t()
  def url(path), do: path <> "?v=" <> Map.fetch!(@versions, path)

  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | :error
  def fetch(path) when is_binary(path) do
    case Map.fetch(@assets, path) do
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      :error -> :error
    end
  end
end
