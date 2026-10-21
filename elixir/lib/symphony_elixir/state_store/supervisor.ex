defmodule SymphonyElixir.StateStore.Supervisor do
  @moduledoc """
  Starts the Postgres state store when a database is configured
  (`SYMPHONY_DATABASE_URL`): the repo, then the migrator, and switches
  `StateStore` to the Postgres backend. Without a database it starts nothing and
  state stays in files.

  It sits before every store in the application tree, so stores load from the
  backend they will write to.
  """

  use Supervisor
  require Logger

  alias SymphonyElixir.{Repo, StateStore}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case Repo.database_url() do
      nil ->
        :ignore

      _url ->
        Application.put_env(:symphony_elixir, :state_store, StateStore.Postgres)
        Logger.info("State store: Postgres")
        # The migrator needs the repo, and a restarted repo must not leave stores without one.
        Supervisor.init([Repo, SymphonyElixir.Repo.Migrator], strategy: :rest_for_one)
    end
  end
end
