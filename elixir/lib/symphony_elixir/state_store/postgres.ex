defmodule SymphonyElixir.StateStore.Postgres do
  @moduledoc """
  State documents as rows in Postgres (`state_documents`), keyed by their path
  relative to `StateStore.root/0` (`sessions.json`, `factories/PAY.json`). A
  path outside the root keeps its full expanded path as the key.

  Writes are single-row upserts, so every document is replaced atomically, and
  `create_once/2` uses `ON CONFLICT DO NOTHING` so concurrent creators agree.
  """

  @behaviour SymphonyElixir.StateStore

  alias SymphonyElixir.{Repo, StateStore}

  @impl true
  def read(path) do
    case Repo.query("SELECT body FROM state_documents WHERE key = $1", [key(path)]) do
      {:ok, %{rows: [[body]]}} -> {:ok, body}
      {:ok, %{rows: []}} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def write(path, content) do
    sql = """
    INSERT INTO state_documents (key, body, updated_at) VALUES ($1, $2, now())
    ON CONFLICT (key) DO UPDATE SET body = EXCLUDED.body, updated_at = EXCLUDED.updated_at
    """

    case Repo.query(sql, [key(path), IO.iodata_to_binary(content)]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def create_once(path, content) do
    sql = "INSERT INTO state_documents (key, body, updated_at) VALUES ($1, $2, now()) ON CONFLICT (key) DO NOTHING"

    with {:ok, _result} <- Repo.query(sql, [key(path), content]) do
      read(path)
    end
  end

  @impl true
  def list(dir) do
    prefix = key(dir) <> "/"

    case Repo.query("SELECT key, body FROM state_documents WHERE starts_with(key, $1) ORDER BY key", [prefix]) do
      {:ok, %{rows: rows}} ->
        documents =
          for [key, body] <- rows,
              name = String.replace_prefix(key, prefix, ""),
              not String.contains?(name, "/"),
              String.ends_with?(name, ".json"),
              do: {Path.join(dir, name), body}

        {:ok, documents}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The row key for a document path."
  @spec key(Path.t()) :: String.t()
  def key(path) do
    expanded = Path.expand(path)
    root = StateStore.root()

    case Path.relative_to(expanded, root) do
      ^expanded -> expanded
      relative -> relative
    end
  end
end
