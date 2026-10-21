defmodule SymphonyElixir.StateStore.File do
  @moduledoc """
  State documents as owner-only files on local disk (`PrivateFile`).
  """

  @behaviour SymphonyElixir.StateStore

  alias SymphonyElixir.PrivateFile

  @impl true
  def read(path), do: File.read(path)

  @impl true
  def write(path, content), do: PrivateFile.write(path, content)

  @impl true
  def create_once(path, content), do: PrivateFile.create_once(path, content)

  @impl true
  def list(dir) do
    documents =
      dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, body} -> [{path, body}]
          {:error, _reason} -> []
        end
      end)

    {:ok, documents}
  end
end
