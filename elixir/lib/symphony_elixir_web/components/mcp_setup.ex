defmodule SymphonyElixirWeb.McpSetup do
  @moduledoc """
  How to connect agent harnesses to Symphony's MCP endpoint, with the person's
  URL and current token filled in. Shown on the MCP setup page and in the popup
  on someone's first visit.
  """

  use Phoenix.Component

  alias SymphonyElixir.Config

  @server_name "symphony"

  @doc """
  The MCP endpoint people's agents call: `server.mcp.host` when set, else
  `server.public_url`, else `fallback` (the address the request came in on).
  """
  @spec url(String.t()) :: String.t()
  def url(fallback) do
    settings = Config.settings!()

    base =
      cond do
        is_binary(settings.server.mcp.host) -> "https://" <> settings.server.mcp.host
        is_binary(settings.server.public_url) -> settings.server.public_url
        true -> fallback
      end

    String.trim_trailing(base, "/") <> "/mcp"
  end

  @doc """
  Setup steps for each harness. Needs `url` and `token`.
  """
  attr(:url, :string, required: true)
  attr(:token, :string, required: true)

  @spec instructions(map()) :: Phoenix.LiveView.Rendered.t()
  def instructions(assigns) do
    assigns = assign(assigns, :harnesses, harnesses(assigns.url, assigns.token))

    ~H"""
    <div class="mcp-setup">
      <details :for={{harness, index} <- Enum.with_index(@harnesses)} class="mcp-harness" open={index == 0}>
        <summary class="mcp-harness-name">{harness.name}</summary>
        <p class="login-help">{harness.intro}</p>
        <div class="mcp-snippet-row">
          <pre class="mcp-snippet">{harness.snippet}</pre>
          <button
            type="button"
            class="fx-action mcp-copy"
            data-copy={harness.snippet}
            data-label="Copy"
            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
          >
            Copy
          </button>
        </div>
        <p :if={harness[:after]} class="login-help">{harness.after}</p>
      </details>
    </div>
    """
  end

  @doc false
  @spec harnesses(String.t(), String.t()) :: [%{name: String.t(), intro: String.t(), snippet: String.t()}]
  def harnesses(url, token) do
    name = @server_name

    [
      %{
        name: "Claude Code",
        intro: "Run in a terminal. It replaces any earlier Symphony entry, so run it again after rotating.",
        snippet:
          "claude mcp remove --scope user #{name} 2>/dev/null; " <>
            ~s(claude mcp add --transport http --scope user #{name} #{url} --header "Authorization: Bearer #{token}")
      },
      %{
        name: "Claude Desktop",
        intro:
          "Add this to claude_desktop_config.json (Settings → Developer → Edit Config; on macOS ~/Library/Application Support/Claude/). " <>
            "It runs the mcp-remote bridge, so Node.js must be installed.",
        snippet: """
        {
          "mcpServers": {
            "#{name}": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "#{url}", "--header", "Authorization:${SYMPHONY_AUTH}"],
              "env": { "SYMPHONY_AUTH": "Bearer #{token}" }
            }
          }
        }\
        """,
        after: "Merge it into any mcpServers you already have, then quit Claude Desktop completely and reopen it."
      },
      %{
        name: "Codex CLI",
        intro: "Run in a terminal. It appends Symphony to ~/.codex/config.toml.",
        snippet: """
        cat >> ~/.codex/config.toml <<'EOF'

        [mcp_servers.#{name}]
        url = "#{url}"
        http_headers = { "Authorization" = "Bearer #{token}" }
        EOF\
        """,
        after: "After rotating, replace the token on the http_headers line instead of appending again. Check with codex mcp list."
      },
      %{
        name: "Codex desktop app",
        intro:
          "The Codex app reads the same ~/.codex/config.toml as the CLI: run the Codex CLI step, then restart the app. " <>
            "Or in the app: Settings → MCP servers → Add server → Streamable HTTP, name #{name}, URL #{url}, and this header:",
        snippet: "Authorization: Bearer #{token}"
      },
      %{
        name: "Grok",
        intro: "Grok Build (the grok CLI). Run in a terminal:",
        snippet: ~s(grok mcp add --transport http #{name} #{url} --header "Authorization: Bearer #{token}"),
        after: "Check it with grok mcp doctor #{name}. After rotating, remove the server and add it again."
      }
    ]
  end
end
