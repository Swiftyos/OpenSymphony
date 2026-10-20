defmodule SymphonyElixirWeb.ChatPanel do
  @moduledoc """
  The agent chat for one issue, laid out like the Codex app: the agent's
  messages as plain prose, yours as bubbles, and its work (thinking, commands,
  edits, tool calls) as quiet rows that open to show the detail. A composer at
  the bottom sends the agent a message.
  """

  use Phoenix.Component

  alias SymphonyElixirWeb.Markdown

  attr(:issue, :string, required: true)
  attr(:entries, :list, default: [])
  attr(:queued, :list, default: [], doc: "messages not yet delivered to the agent")
  attr(:session, :map, default: nil, doc: "the issue's running entry, if an agent is on it")
  attr(:can_message, :boolean, default: false)
  attr(:error, :string, default: nil)
  attr(:expanded, :boolean, default: false)

  @spec chat_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def chat_panel(assigns) do
    assigns = assign(assigns, :items, Enum.map(assigns.entries, &view_entry/1))

    ~H"""
    <aside
      class={["chat-panel cx", @expanded && "is-expanded"]}
      aria-label={"Agent chat for #{@issue}"}
      phx-window-keydown="close_chat"
      phx-key="Escape"
    >
      <header class="cx-head">
        <div class="cx-head-main">
          <p class="cx-eyebrow">
            <span class={["cx-state", @session && "is-working"]}></span>
            {if @session, do: "Working", else: "Idle"}
            <span :if={@session && @session[:stage]}>· {@session.stage}</span>
            <span :if={@session && @session[:turn_count]}>· turn {@session.turn_count}</span>
          </p>
          <h2 class="cx-title">
            <span class="cx-id">{@issue}</span>
            <span :if={@session && @session[:issue_title]} class="cx-issue-title">{@session.issue_title}</span>
          </h2>
          <p :if={@session} class="cx-sub">
            <span class={"harness-dot h-#{@session[:backend] || "codex"}"}></span>
            {@session[:model] || @session[:backend]}
            <span :if={@session[:effort]}>· {@session.effort}</span>
          </p>
        </div>
        <div class="cx-head-actions">
          <a :if={@session && @session[:issue_url]} class="cx-icon" href={@session.issue_url} target="_blank" rel="noopener" title="Open in Linear">↗</a>
          <button type="button" class="cx-icon" phx-click="toggle_chat_size" title={if @expanded, do: "Narrow", else: "Widen"}>
            {if @expanded, do: "⇥", else: "⇤"}
          </button>
          <button type="button" class="cx-icon" phx-click="close_chat" aria-label="Close chat">✕</button>
        </div>
      </header>

      <div id={"chat-log-#{@issue}"} class="cx-log" phx-hook="ChatScroll">
        <div class="cx-thread">
          <p :if={@items == []} class="cx-empty">
            Nothing yet. The conversation appears as soon as an agent works on this issue.
          </p>
          <%= for item <- @items do %>
            <.item item={item} />
          <% end %>
        </div>
      </div>

      <footer class="cx-footer">
        <div :if={@queued != []} class="cx-queued">
          <span class="cx-queued-label">Queued for the agent's next turn</span>
          <p :for={msg <- @queued} class="cx-queued-item">{msg.text}</p>
        </div>
        <p :if={@error} class="cx-error" role="alert">{@error}</p>
        <%= if @can_message do %>
          <form id={"chat-compose-#{@issue}"} class="cx-compose" phx-submit="send_message" phx-hook="ChatComposer">
            <textarea
              name="text"
              rows="1"
              maxlength="8000"
              placeholder={"Message the agent on #{@issue}…"}
              aria-label="Message the agent"
            ></textarea>
            <button type="submit" class="cx-send" aria-label="Send">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19V5M5 12l7-7 7 7" /></svg>
            </button>
          </form>
          <p class="cx-hint">
            Enter sends, Shift+Enter adds a line. Codex gets it right away; Claude at its next turn.
          </p>
        <% else %>
          <p class="cx-hint">You can read this conversation but not message its agent.</p>
        <% end %>
      </footer>
    </aside>
    """
  end

  attr(:item, :map, required: true)

  defp item(%{item: %{type: :user}} = assigns) do
    ~H"""
    <div class="cx-row cx-user">
      <div class="cx-bubble">
        <div class="cx-md">{Markdown.to_html(@item.text)}</div>
      </div>
      <span class="cx-time">{@item.author}{@item.author && " · "}{time(@item.at)}</span>
    </div>
    """
  end

  defp item(%{item: %{type: :agent}} = assigns) do
    ~H"""
    <div class="cx-row cx-agent">
      <div class="cx-md">{Markdown.to_html(@item.text)}</div>
      <span class="cx-time">{time(@item.at)}</span>
    </div>
    """
  end

  defp item(%{item: %{type: :note}} = assigns) do
    ~H"""
    <div class="cx-row cx-note"><span>{@item.text}</span></div>
    """
  end

  defp item(%{item: %{type: :error}} = assigns) do
    ~H"""
    <div class="cx-row cx-error-row">
      <span class="cx-error-mark">!</span>
      <pre>{@item.text}</pre>
    </div>
    """
  end

  defp item(%{item: %{type: :thinking}} = assigns) do
    ~H"""
    <details class="cx-row cx-work cx-thinking">
      <summary><span class="cx-work-icon">◌</span> Thought <span class="cx-work-peek">{peek(@item.text)}</span></summary>
      <div class="cx-work-body cx-md">{Markdown.to_html(@item.text)}</div>
    </details>
    """
  end

  defp item(%{item: %{type: :command}} = assigns) do
    ~H"""
    <details class={["cx-row cx-work cx-command", @item.failed && "is-failed"]}>
      <summary>
        <span class="cx-work-icon">{if @item.failed, do: "✗", else: "›_"}</span>
        Ran <code class="cx-cmd">{@item.command}</code>
        <span :if={@item.meta} class="cx-work-meta">{@item.meta}</span>
      </summary>
      <pre :if={@item.output != ""} class="cx-output">{@item.output}</pre>
      <p :if={@item.output == ""} class="cx-work-empty">No output.</p>
    </details>
    """
  end

  defp item(%{item: %{type: :edit}} = assigns) do
    ~H"""
    <details class="cx-row cx-work cx-edit">
      <summary>
        <span class="cx-work-icon">±</span>
        Edited {length(@item.files)} {if length(@item.files) == 1, do: "file", else: "files"}
        <span class="cx-work-peek">{Enum.map_join(Enum.take(@item.files, 3), ", ", &Path.basename(&1.path))}</span>
      </summary>
      <ul class="cx-files">
        <li :for={file <- @item.files}>
          <code>{file.path}</code>
          <span :if={file[:additions]} class="cx-add">+{file.additions}</span>
          <span :if={file[:deletions]} class="cx-del">−{file.deletions}</span>
        </li>
      </ul>
    </details>
    """
  end

  defp item(assigns) do
    ~H"""
    <details class="cx-row cx-work cx-tool">
      <summary><span class="cx-work-icon">⚙</span> {@item.title}</summary>
      <pre :if={@item.text not in [nil, ""]} class="cx-output">{@item.text}</pre>
    </details>
    """
  end

  # ------------------------------------------------------------------ entries

  # Transcript entries, old and new shapes, as what the chat draws.
  @doc false
  @spec view_entry(map()) :: map()
  def view_entry(%{kind: kind} = entry) do
    base = %{at: entry[:at], text: entry[:text] || entry[:body] || ""}

    case kind do
      "user" -> Map.merge(base, %{type: :user, author: entry[:author]})
      "agent" -> Map.put(base, :type, :agent)
      "thinking" -> Map.put(base, :type, :thinking)
      "symphony" -> Map.put(base, :type, :note)
      "turn" -> Map.put(base, :type, :note)
      "error" -> Map.put(base, :type, :error)
      "command" -> command(base, entry)
      "edit" -> edit(base, entry)
      "tool" -> legacy_tool(base, entry)
      _ -> Map.merge(base, %{type: :tool, title: entry[:title] || kind})
    end
  end

  defp command(base, entry) do
    exit_code = entry[:exit_code]
    meta = [exit_code && exit_code != 0 && "exit #{exit_code}", duration(entry[:duration_ms])] |> Enum.filter(& &1) |> Enum.join(" · ")

    Map.merge(base, %{
      type: :command,
      command: entry[:command] || entry[:title] || first_line(base.text),
      output: entry[:output] || entry[:body] || "",
      failed: (is_integer(exit_code) and exit_code != 0) or entry[:status] == "failed",
      meta: if(meta == "", do: nil, else: meta)
    })
  end

  defp edit(base, entry) do
    files =
      entry
      |> Map.get(:files, [])
      |> List.wrap()
      |> Enum.map(fn
        %{} = file -> %{path: file[:path] || file["path"] || "a file", additions: file[:additions] || file["additions"], deletions: file[:deletions] || file["deletions"]}
        path when is_binary(path) -> %{path: path}
      end)

    Map.merge(base, %{type: :edit, files: if(files == [], do: [%{path: entry[:title] || "a file"}], else: files)})
  end

  # Entries from before the structured transcript: "$ cmd (exit 1)\noutput" and
  # "Edited a, b".
  defp legacy_tool(base, entry) do
    text = base.text

    cond do
      String.starts_with?(text, "$ ") ->
        [head | rest] = String.split(text, "\n", parts: 2)
        {cmd, exit_code} = split_exit(String.trim_leading(head, "$ "))
        command(base, %{command: cmd, exit_code: exit_code, output: Enum.join(rest, "")})

      String.starts_with?(text, "Edited ") ->
        files = text |> String.trim_leading("Edited ") |> String.split(", ") |> Enum.map(&%{path: &1})
        edit(base, %{files: files})

      true ->
        Map.merge(base, %{type: :tool, title: entry[:title] || first_line(text), text: rest_lines(text)})
    end
  end

  defp split_exit(head) do
    case Regex.run(~r/^(.*) \(exit (-?\d+)\)$/, head) do
      [_, cmd, code] -> {cmd, String.to_integer(code)}
      nil -> {head, nil}
    end
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp rest_lines(text) do
    case String.split(text, "\n", parts: 2) do
      [_, rest] -> rest
      _ -> ""
    end
  end

  defp peek(text), do: text |> String.replace(~r/\s+/, " ") |> String.slice(0, 90)

  defp duration(ms) when is_integer(ms) and ms >= 60_000, do: "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
  defp duration(ms) when is_integer(ms) and ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp duration(ms) when is_integer(ms), do: "#{ms}ms"
  defp duration(_ms), do: nil

  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
  defp time(_at), do: ""
end
