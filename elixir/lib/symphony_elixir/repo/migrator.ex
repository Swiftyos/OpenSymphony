defmodule SymphonyElixir.Repo.Migrator do
  @moduledoc """
  Brings the database schema up to date when Symphony starts. It is a
  supervisor child placed after the repo and before the stores; it migrates
  during `start_link/1` and returns `:ignore`, so nothing loads state from a
  schema that isn't there yet.

  Migrations are compiled modules rather than files in `priv/` because the
  escript has no `priv/` directory. Concurrent starts are safe: Ecto takes the
  migration lock, so a second controller waits and then finds nothing to run.
  """

  alias SymphonyElixir.Repo
  alias SymphonyElixir.Repo.Migrations

  @migrations [
    {20_261_021_000_001, Migrations.CreateStateDocuments}
  ]

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :temporary}

  @spec start_link(keyword()) :: :ignore
  def start_link(_opts) do
    run()
    :ignore
  end

  @doc "Runs every pending migration and returns the versions it applied."
  @spec run() :: [integer()]
  def run, do: Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: :info)

  @doc "The migrations Symphony knows, as `{version, module}`."
  @spec migrations() :: [{integer(), module()}]
  def migrations, do: @migrations
end
