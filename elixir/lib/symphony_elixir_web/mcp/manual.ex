defmodule SymphonyElixirWeb.Mcp.Manual do
  @moduledoc """
  Symphony's user manual for MCP clients (`manual.md` beside this file): what
  Symphony is, its concepts, an issue's life, the MCP tools and recipes.

  Served as the `get_manual` tool and as MCP resources (`symphony://manual`
  and `symphony://manual/<section>`). Compiled in, so it ships with the escript.
  """

  @external_resource Path.join(__DIR__, "manual.md")
  @text File.read!(Path.join(__DIR__, "manual.md"))

  # "## Heading" sections, keyed by a slug of the heading.
  @sections @text
            |> String.split(~r/^## /m)
            |> tl()
            |> Enum.map(fn chunk ->
              [heading | _rest] = String.split(chunk, "\n", parts: 2)
              slug = heading |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
              {slug, heading, "## " <> String.trim_trailing(chunk) <> "\n"}
            end)

  @uri "symphony://manual"

  @spec text() :: String.t()
  def text, do: @text

  @doc """
  Section slugs in order, e.g. `"overview"`, `"using-this-mcp"`.
  """
  @spec sections() :: [String.t()]
  def sections, do: Enum.map(@sections, &elem(&1, 0))

  @spec section(String.t()) :: {:ok, String.t()} | :error
  def section(slug) do
    case List.keyfind(@sections, slug, 0) do
      {_slug, _heading, body} -> {:ok, body}
      nil -> :error
    end
  end

  @doc """
  MCP resource descriptors: the whole manual, then each section.
  """
  @spec resources() :: [map()]
  def resources do
    whole = %{
      uri: @uri,
      name: "manual",
      title: "Symphony manual",
      description: "What Symphony is, how issues flow through it, and how to use this MCP server.",
      mimeType: "text/markdown"
    }

    sections =
      Enum.map(@sections, fn {slug, heading, _body} ->
        %{uri: "#{@uri}/#{slug}", name: "manual-#{slug}", title: "Symphony manual: #{heading}", mimeType: "text/markdown"}
      end)

    [whole | sections]
  end

  @spec read(String.t()) :: {:ok, String.t()} | :error
  def read(@uri), do: {:ok, @text}
  def read(@uri <> "/" <> slug), do: section(slug)
  def read(_uri), do: :error
end
