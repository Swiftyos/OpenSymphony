defmodule SymphonyElixirWeb.Markdown do
  @moduledoc """
  A small Markdown renderer for agent messages in the chat view.

  Agents write GitHub-flavoured Markdown; this covers what they use (fenced
  code, inline code, bold, italics, headings, lists, quotes, links) and nothing
  else. Everything is HTML-escaped first, so the output only ever contains the
  tags added here; links are kept only for http(s) URLs.
  """

  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: {:safe, ""}

  def to_html(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> blocks()
    |> Enum.map_join("\n", &render_block/1)
    |> then(&{:safe, &1})
  end

  # ------------------------------------------------------------------ blocks

  defp blocks(text), do: text |> String.split("\n") |> collect([], nil) |> Enum.reverse()

  defp collect([], acc, nil), do: acc
  defp collect([], acc, {:code, lang, lines}), do: [{:code, lang, Enum.reverse(lines)} | acc]

  defp collect([line | rest], acc, {:code, lang, lines}) do
    if String.starts_with?(String.trim_leading(line), "```"),
      do: collect(rest, [{:code, lang, Enum.reverse(lines)} | acc], nil),
      else: collect(rest, acc, {:code, lang, [line | lines]})
  end

  defp collect([line | rest], acc, nil) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "```") ->
        collect(rest, acc, {:code, trimmed |> String.trim_leading("`") |> String.trim(), []})

      String.trim(line) == "" ->
        collect(rest, acc, nil)

      true ->
        collect(rest, add_line(acc, classify(line)), nil)
    end
  end

  defp classify(line) do
    trimmed = String.trim_leading(line)

    cond do
      match = Regex.run(~r/^(\#{1,6})\s+(.*)$/, trimmed) -> {:heading, String.length(Enum.at(match, 1)), Enum.at(match, 2)}
      match = Regex.run(~r/^[-*+]\s+(.*)$/, trimmed) -> {:ul, Enum.at(match, 1)}
      match = Regex.run(~r/^\d+[.)]\s+(.*)$/, trimmed) -> {:ol, Enum.at(match, 1)}
      match = Regex.run(~r/^>\s?(.*)$/, trimmed) -> {:quote, Enum.at(match, 1)}
      true -> {:p, String.trim(line)}
    end
  end

  # Consecutive lines of the same kind join one block; headings stand alone.
  defp add_line([{:ul, items} | acc], {:ul, item}), do: [{:ul, [item | items]} | acc]
  defp add_line([{:ol, items} | acc], {:ol, item}), do: [{:ol, [item | items]} | acc]
  defp add_line([{:quote, lines} | acc], {:quote, line}), do: [{:quote, [line | lines]} | acc]
  defp add_line([{:p, lines} | acc], {:p, line}), do: [{:p, [line | lines]} | acc]
  defp add_line(acc, {:ul, item}), do: [{:ul, [item]} | acc]
  defp add_line(acc, {:ol, item}), do: [{:ol, [item]} | acc]
  defp add_line(acc, {:quote, line}), do: [{:quote, [line]} | acc]
  defp add_line(acc, {:p, line}), do: [{:p, [line]} | acc]
  defp add_line(acc, heading), do: [heading | acc]

  defp render_block({:code, lang, lines}) do
    label = if lang != "", do: ~s( data-lang="#{escape(lang)}"), else: ""
    "<pre class=\"md-code\"#{label}><code>#{escape(Enum.join(lines, "\n"))}</code></pre>"
  end

  defp render_block({:heading, level, text}), do: "<h#{min(level + 2, 6)}>#{inline(text)}</h#{min(level + 2, 6)}>"
  defp render_block({:ul, items}), do: "<ul>" <> Enum.map_join(Enum.reverse(items), &"<li>#{inline(&1)}</li>") <> "</ul>"
  defp render_block({:ol, items}), do: "<ol>" <> Enum.map_join(Enum.reverse(items), &"<li>#{inline(&1)}</li>") <> "</ol>"
  defp render_block({:quote, lines}), do: "<blockquote>#{lines |> Enum.reverse() |> Enum.map_join("<br>", &inline/1)}</blockquote>"
  defp render_block({:p, lines}), do: "<p>#{lines |> Enum.reverse() |> Enum.map_join("<br>", &inline/1)}</p>"

  # ------------------------------------------------------------------ inline

  # Code spans first, so nothing inside them is formatted.
  defp inline(text) do
    ~r/`([^`]+)`/
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn part ->
      case Regex.run(~r/^`([^`]+)`$/, part) do
        [_, code] -> "<code>#{escape(code)}</code>"
        nil -> part |> escape() |> links() |> emphasis()
      end
    end)
  end

  defp links(escaped) do
    Regex.replace(~r/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/, escaped, fn _, label, url ->
      ~s(<a href="#{url}" target="_blank" rel="noopener noreferrer">#{label}</a>)
    end)
  end

  defp emphasis(escaped) do
    escaped
    |> then(&Regex.replace(~r/\*\*([^*]+)\*\*/, &1, "<strong>\\1</strong>"))
    |> then(&Regex.replace(~r/(?<![*\w])\*([^*\s][^*]*)\*(?![*\w])/, &1, "<em>\\1</em>"))
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
