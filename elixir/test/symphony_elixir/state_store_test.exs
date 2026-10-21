defmodule SymphonyElixir.StateStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Repo, SessionStore, StateStore}
  alias SymphonyElixir.Repo.Migrator
  alias SymphonyElixir.StateStore.{Postgres, Supervisor}

  defp temp_root! do
    root = Path.join(System.tmp_dir!(), "symphony-state-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:symphony_elixir, key)
    Application.put_env(:symphony_elixir, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:symphony_elixir, key, old)
        :error -> Application.delete_env(:symphony_elixir, key)
      end
    end)
  end

  describe "file backend" do
    test "reads, writes, creates once and lists the json documents in a directory" do
      root = temp_root!()
      path = Path.join([root, "factories", "PAY.json"])

      assert StateStore.backend() == StateStore.File
      assert {:error, :enoent} = StateStore.read(path)
      assert :ok = StateStore.write(path, ["{", "}"])
      assert {:ok, "{}"} = StateStore.read(path)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

      secret = Path.join(root, "secret")
      assert {:ok, "first"} = StateStore.create_once(secret, "first")
      assert {:ok, "first"} = StateStore.create_once(secret, "second")

      File.write!(Path.join([root, "factories", "notes.txt"]), "ignored")
      assert {:ok, [{^path, "{}"}]} = StateStore.list(Path.join(root, "factories"))
      assert {:ok, []} = StateStore.list(Path.join(root, "missing"))
    end

    test "list skips documents that can't be read" do
      root = temp_root!()
      File.mkdir_p!(Path.join(root, "broken.json"))
      assert {:ok, []} = StateStore.list(root)
    end

    test "the root is ~/.symphony unless configured" do
      put_env(:state_root, :default)
      assert StateStore.root() == Path.expand("~/.symphony")

      put_env(:state_root, "/srv/symphony/state")
      assert StateStore.root() == "/srv/symphony/state"
    end
  end

  describe "repo configuration" do
    test "the database url comes from SYMPHONY_DATABASE_URL unless configured" do
      put_env(:database_url, :env)
      previous = System.get_env("SYMPHONY_DATABASE_URL")
      on_exit(fn -> if previous, do: System.put_env("SYMPHONY_DATABASE_URL", previous), else: System.delete_env("SYMPHONY_DATABASE_URL") end)

      System.put_env("SYMPHONY_DATABASE_URL", "ecto://u:p@db/symphony")
      assert Repo.database_url() == "ecto://u:p@db/symphony"

      System.put_env("SYMPHONY_DATABASE_URL", "  ")
      assert Repo.database_url() == nil

      put_env(:database_url, "ecto://other/db")
      assert Repo.database_url() == "ecto://other/db"

      put_env(:database_url, nil)
      assert Repo.database_url() == nil
    end

    test "init fills in the url and pool size" do
      put_env(:database_url, "ecto://u:p@db/symphony")
      previous = System.get_env("SYMPHONY_DATABASE_POOL_SIZE")
      on_exit(fn -> if previous, do: System.put_env("SYMPHONY_DATABASE_POOL_SIZE", previous), else: System.delete_env("SYMPHONY_DATABASE_POOL_SIZE") end)

      System.put_env("SYMPHONY_DATABASE_POOL_SIZE", "3")
      assert {:ok, config} = Repo.init(:runtime, [])
      assert config[:url] == "ecto://u:p@db/symphony"
      assert config[:pool_size] == 3

      System.put_env("SYMPHONY_DATABASE_POOL_SIZE", "lots")
      assert {:ok, config} = Repo.init(:runtime, url: "ecto://given/db")
      assert config[:url] == "ecto://given/db"
      assert config[:pool_size] == 10
    end

    test "the supervisor starts nothing without a database" do
      put_env(:database_url, nil)
      assert :ignore = Supervisor.init([])
      assert StateStore.backend() == StateStore.File
    end

    test "postgres keys are paths relative to the state root" do
      put_env(:state_root, "/home/symphony/.symphony")
      assert Postgres.key("/home/symphony/.symphony/sessions.json") == "sessions.json"
      assert Postgres.key("/home/symphony/.symphony/factories/PAY.json") == "factories/PAY.json"
      assert Postgres.key("/elsewhere/users.json") == "/elsewhere/users.json"
    end
  end

  describe "postgres backend" do
    @describetag :postgres

    setup do
      put_env(:database_url, System.fetch_env!("SYMPHONY_TEST_DATABASE_URL"))
      put_env(:state_store, StateStore.File)
      put_env(:state_root, temp_root!())

      capture_log(fn -> start_supervised!(Supervisor) end)
      Repo.query!("TRUNCATE state_documents")
      :ok
    end

    test "the supervisor migrates and switches the backend" do
      assert StateStore.backend() == Postgres
      assert Migrator.run() == []

      # Down and up again, so a fresh database gets the same schema.
      capture_log(fn ->
        assert [_version] = Ecto.Migrator.run(Repo, Migrator.migrations(), :down, all: true)
        assert [_version] = Migrator.run()
      end)

      assert {:error, :enoent} = StateStore.read(Path.join(StateStore.root(), "sessions.json"))
    end

    test "reads, upserts, creates once and lists documents" do
      root = StateStore.root()
      path = Path.join(root, "sessions.json")

      assert {:error, :enoent} = StateStore.read(path)
      assert :ok = StateStore.write(path, ["{", "}"])
      assert :ok = StateStore.write(path, ~s({"version":1}))
      assert {:ok, ~s({"version":1})} = StateStore.read(path)

      secret = Path.join(root, "secret_key_base")
      assert {:ok, "first"} = StateStore.create_once(secret, "first")
      assert {:ok, "first"} = StateStore.create_once(secret, "second")

      factories = Path.join(root, "factories")
      :ok = StateStore.write(Path.join(factories, "PAY.json"), "{}")
      :ok = StateStore.write(Path.join(factories, "project--web.json"), "{}")
      :ok = StateStore.write(Path.join(factories, "notes.txt"), "x")
      :ok = StateStore.write(Path.join([factories, "nested", "DEEP.json"]), "{}")

      assert {:ok, documents} = StateStore.list(factories)
      assert Enum.map(documents, &elem(&1, 0)) == [Path.join(factories, "PAY.json"), Path.join(factories, "project--web.json")]
    end

    test "stores keep their state in postgres across restarts" do
      path = Path.join(StateStore.root(), "sessions.json")
      name = :"session_store_pg_#{System.unique_integer([:positive])}"

      {:ok, first} = SessionStore.start_link(path: path, name: name)
      :ok = GenServer.call(first, {:put, "issue-1", %{backend: "claude", session_id: "s-1"}})
      GenServer.stop(first)

      refute File.exists?(path)
      {:ok, second} = SessionStore.start_link(path: path, name: name)
      assert %{"backend" => "claude", "session_id" => "s-1"} = GenServer.call(second, {:get, "issue-1"})
      GenServer.stop(second)
    end

    test "the run registry keeps one row per issue and migrates a legacy runs.json" do
      runs_path = Path.join(StateStore.root(), "runs.json")
      previous = Application.get_env(:symphony_elixir, :runs_path)
      Application.put_env(:symphony_elixir, :runs_path, runs_path)

      on_exit(fn ->
        SymphonyElixir.RunRegistry.reload()
        Application.put_env(:symphony_elixir, :runs_path, previous)
      end)

      legacy = %{"run_id" => "run-legacy", "attempt" => 0, "epoch" => 3, "ref" => "local:boot:0.1.0", "started_at_unix_ms" => 1}
      :ok = StateStore.write(runs_path, Jason.encode!(%{"version" => 1, "runs" => %{"issue-legacy" => legacy}, "epochs" => %{}}))

      capture_log(fn -> assert %{"issue-legacy" => %{run_id: "run-legacy"}} = SymphonyElixir.RunRegistry.load() end)
      :ok = SymphonyElixir.RunRegistry.record("issue-2", %{run_id: "run-2", attempt: 0, epoch: 1, ref: "local:boot:0.2.0", started_at_unix_ms: 2})

      %{rows: rows} = Repo.query!("SELECT key FROM state_documents WHERE starts_with(key, 'run_registry/') ORDER BY key")
      assert length(rows) == 2

      :ok = SymphonyElixir.RunRegistry.reload()
      assert {"issue-2", %{run_id: "run-2"}} = SymphonyElixir.RunRegistry.find_run("run-2")
      assert SymphonyElixir.RunRegistry.next_epoch("issue-legacy") == 4
    end

    test "database errors are returned, not raised" do
      Repo.query!("ALTER TABLE state_documents RENAME TO state_documents_away")

      try do
        path = Path.join(StateStore.root(), "users.json")
        assert {:error, %Postgrex.Error{}} = StateStore.read(path)
        assert {:error, %Postgrex.Error{}} = StateStore.write(path, "{}")
        assert {:error, %Postgrex.Error{}} = StateStore.create_once(path, "{}")
        assert {:error, %Postgrex.Error{}} = StateStore.list(StateStore.root())
      after
        Repo.query!("ALTER TABLE state_documents_away RENAME TO state_documents")
      end
    end
  end
end
