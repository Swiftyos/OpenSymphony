defmodule SymphonyElixir.StateStore do
  @moduledoc """
  Where Symphony keeps its state documents: sessions, usage, users, the agent
  inbox, factory flows, the retry queue and the session secret.

  Each store reads and writes whole documents named by the path they'd have on
  disk (`~/.symphony/sessions.json`, `~/.symphony/factories/PAY.json`). The
  backend decides where they really live:

    * `StateStore.File` (the default): owner-only files, written atomically
      (`PrivateFile`).
    * `StateStore.Postgres`: rows in `state_documents`, chosen when
      `SYMPHONY_DATABASE_URL` is set. State then survives the host, so a
      controller can be replaced without losing it.
  """

  alias SymphonyElixir.StateStore

  @callback read(Path.t()) :: {:ok, binary()} | {:error, term()}
  @callback write(Path.t(), iodata()) :: :ok | {:error, term()}
  @callback create_once(Path.t(), binary()) :: {:ok, binary()} | {:error, term()}
  @callback list(Path.t()) :: {:ok, [{Path.t(), binary()}]} | {:error, term()}

  @doc "The document at `path`; `{:error, :enoent}` when there is none."
  @spec read(Path.t()) :: {:ok, binary()} | {:error, term()}
  def read(path), do: backend().read(path)

  @doc "Replaces the document at `path`."
  @spec write(Path.t(), iodata()) :: :ok | {:error, term()}
  def write(path, content), do: backend().write(path, content)

  @doc """
  Creates the document only if it doesn't exist yet and returns the stored
  content either way, so two processes racing to create it agree on one value.
  """
  @spec create_once(Path.t(), binary()) :: {:ok, binary()} | {:error, term()}
  def create_once(path, content), do: backend().create_once(path, content)

  @doc "The `.json` documents directly inside `dir`, as `{path, content}`."
  @spec list(Path.t()) :: {:ok, [{Path.t(), binary()}]} | {:error, term()}
  def list(dir), do: backend().list(dir)

  @doc "The backend module in use."
  @spec backend() :: module()
  def backend, do: Application.get_env(:symphony_elixir, :state_store, StateStore.File)

  @doc "The directory documents are named relative to: `~/.symphony` unless configured."
  @spec root() :: Path.t()
  def root do
    case Application.get_env(:symphony_elixir, :state_root, :default) do
      :default -> Path.expand("~/.symphony")
      root -> Path.expand(root)
    end
  end
end
