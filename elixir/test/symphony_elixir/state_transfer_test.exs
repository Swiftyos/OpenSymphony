defmodule SymphonyElixir.StateTransferTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.{CLI, McpTokens, Repo, StateStore, StateTransfer}

  @secret String.duplicate("k", 64)

  defmodule FailingStore do
    @moduledoc false
    @behaviour SymphonyElixir.StateStore
    @impl true
    def read(_path), do: {:error, :enoent}
    @impl true
    def write(_path, _content), do: {:error, :boom}
    @impl true
    def create_once(_path, _content), do: {:error, :boom}
    @impl true
    def list(_dir), do: {:ok, []}
  end

  @marker "VALUE-THAT-MUST-NOT-BE-PRINTED"

  defp temp_dir!(name) do
    dir = Path.join(System.tmp_dir!(), "symphony-state-transfer-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
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

  # Restores the state store settings `prepare_target/1` changes.
  defp keep_state_store_env do
    put_env(:state_store, StateStore.File)
    put_env(:state_root, :default)
    put_env(:database_url, nil)
  end

  defp write!(dir, key, body) do
    path = Path.join(dir, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  # A VM's ~/.symphony: the portable documents plus everything that must stay.
  defp vm_state!(dir) do
    write!(dir, "users.json", ~s({"version":1,"users":[{"name":"#{@marker}"}]}))
    write!(dir, "project_routes.json", ~s({"version":1,"routes":[]}))
    write!(dir, "usage.json", ~s({"version":1}))
    write!(dir, "session_history.json", ~s({"version":1,"sessions":[]}))
    write!(dir, "inbox.json", ~s({"version":1,"messages":[]}))
    write!(dir, "secret_key_base", @secret)
    write!(dir, "factories/PAY.json", ~s({"version":3}))
    write!(dir, "factories/project--web.json", ~s({"version":1,"name":"Zoë ✓"}))
    write!(dir, "factories/notes.txt", "not a flow")
    write!(dir, "sessions.json", ~s({"version":1,"sessions":{"issue-1":{"workspace":"/home/vm/code/PAY-1"}}}))
    write!(dir, "retries.json", ~s({"version":1,"retries":{}}))
    write!(dir, "runs.json", ~s({"version":1,"runs":{}}))
    write!(dir, "run_registry/aXNzdWUtMQ.json", ~s({"run_id":"run-1"}))
    write!(dir, "runs/run-1/spec.json", "{}")
    write!(dir, "accounts/codex/main/auth.json", ~s({"token":"#{@marker}"}))
    write!(dir, "logs/symphony.log", @marker)
  end

  defp io(parent) do
    [
      puts: &send(parent, {:out, &1}),
      error_puts: &send(parent, {:err, &1}),
      stdout: fn data -> send(parent, {:stdout, data}) && :ok end,
      getenv: fn _name -> nil end
    ]
  end

  defp output(tag) do
    receive_all(tag, [])
  end

  defp receive_all(tag, acc) do
    receive do
      {^tag, line} -> receive_all(tag, [line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp archive!(vm) do
    {:ok, archive, _documents, _left_out} = StateTransfer.export_archive(vm)
    archive
  end

  # A tar.gz with the given entries, for archives export would never make.
  defp tarball!(entries) do
    dir = temp_dir!("tar")
    path = Path.join(dir, "x.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), Enum.map(entries, fn {name, body} -> {String.to_charlist(name), body} end), [:compressed])
    File.read!(path)
  end

  defp manifest(documents, version \\ 1) do
    Jason.encode!(%{
      "format" => "symphony-state",
      "version" => version,
      "documents" => Enum.map(documents, fn {key, body} -> %{"key" => key, "bytes" => byte_size(body), "sha256" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)} end)
    })
  end

  describe "the allowlist" do
    test "only documents that mean the same on another host are portable" do
      for key <- ~w(users.json mcp_tokens.json project_routes.json usage.json session_history.json inbox.json secret_key_base factories/PAY.json factories/project--web.json) do
        assert StateTransfer.portable_key?(key), key
      end

      for key <- ~w(sessions.json retries.json runs.json run_registry/x.json runs/r/spec.json accounts/codex/a/auth.json factories/nested/X.json factories/../users.json factories/.json logs/x) do
        refute StateTransfer.portable_key?(key), key
      end
    end
  end

  describe "file to file" do
    setup do
      keep_state_store_env()
      :ok
    end

    test "export packs the allowlisted documents and import writes them, once" do
      vm = temp_dir!("vm")
      vm_state!(vm)
      out = Path.join(temp_dir!("out"), "state.tar.gz")
      target = temp_dir!("k8s")

      assert :ok = StateTransfer.run(["export", vm, out], io(self()))
      exported = output(:out)
      assert exported =~ "Exported 8 document(s)"
      assert exported =~ "factories/project--web.json"
      assert exported =~ "#{byte_size(@secret)} bytes"
      for left <- ~w(sessions.json retries.json runs.json run_registry runs accounts), do: assert(exported =~ left)
      refute exported =~ @marker
      refute exported =~ @secret
      assert Bitwise.band(File.stat!(out).mode, 0o777) == 0o600

      {:ok, entries} = :erl_tar.extract(String.to_charlist(out), [:memory, :compressed])
      names = entries |> Enum.map(fn {name, _body} -> List.to_string(name) end) |> Enum.sort()

      assert names ==
               Enum.sort(
                 ["manifest.json"] ++
                   Enum.map(
                     ~w(users.json project_routes.json usage.json session_history.json inbox.json secret_key_base factories/PAY.json factories/project--web.json),
                     &("state/" <> &1)
                   )
               )

      assert :ok = StateTransfer.run(["import", out, "--state-dir", target], io(self()))
      imported = output(:out)
      assert imported =~ "Importing 8 document(s) into files in #{target}"
      assert imported =~ "new       users.json"
      assert imported =~ "Done (8 new)"
      refute imported =~ @marker

      for key <- ~w(users.json project_routes.json usage.json session_history.json inbox.json secret_key_base factories/PAY.json factories/project--web.json) do
        assert File.read!(Path.join(target, key)) == File.read!(Path.join(vm, key)), key
        assert Bitwise.band(File.stat!(Path.join(target, key)).mode, 0o777) == 0o600
      end

      for key <- ~w(sessions.json retries.json runs.json run_registry runs accounts logs factories/notes.txt), do: refute(File.exists?(Path.join(target, key)), key)

      assert :ok = StateTransfer.run(["import", out, "--state-dir", target], io(self()))
      assert output(:out) =~ "Already up to date (8 unchanged)"

      assert {:error, message} = StateTransfer.run(["export", vm, out], io(self()))
      assert message =~ "already exists"
    end

    test "MCP tokens keep working after the move" do
      vm = temp_dir!("vm")
      target = temp_dir!("k8s")
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, McpTokens)
      on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, McpTokens) end)

      vm_tokens = start_supervised!({McpTokens, path: Path.join(vm, "mcp_tokens.json")})
      {:ok, secret, _token} = McpTokens.create("acct-1", "agent", ["read"], 7, ["PAY"])
      assert {:ok, _record} = McpTokens.verify(secret)
      :ok = stop_supervised(McpTokens)
      refute Process.alive?(vm_tokens)

      out = Path.join(temp_dir!("out"), "state.tar.gz")
      assert :ok = StateTransfer.run(["export", vm, out], io(self()))
      refute output(:out) =~ secret
      assert :ok = StateTransfer.run(["import", out, "--state-dir", target], io(self()))

      start_supervised!({McpTokens, path: Path.join(target, "mcp_tokens.json")})
      assert {:ok, %{account_id: "acct-1", name: "agent"}} = McpTokens.verify(secret)
    end

    test "streams through stdout and stdin" do
      vm = temp_dir!("vm")
      vm_state!(vm)
      target = temp_dir!("k8s")

      assert :ok = StateTransfer.run(["export", vm, "-"], io(self()))
      assert_received {:stdout, archive}
      assert output(:err) =~ "Exported 8 document(s)"
      assert output(:out) == ""

      stdin_io = Keyword.put(io(self()), :stdin, fn -> archive end)
      assert :ok = StateTransfer.run(["import", "-", "--state-dir", target], stdin_io)
      assert output(:out) =~ "Done (8 new)"
      assert File.read!(Path.join(target, "factories/project--web.json")) == File.read!(Path.join(vm, "factories/project--web.json"))

      empty_io = Keyword.put(io(self()), :stdin, fn -> :eof end)
      assert {:error, "No archive on stdin"} = StateTransfer.run(["import", "-", "--state-dir", target], empty_io)
    end

    test "refuses to overwrite differing documents unless asked, and a dry run writes nothing" do
      vm = temp_dir!("vm")
      vm_state!(vm)
      target = temp_dir!("k8s")
      out = Path.join(temp_dir!("out"), "state.tar.gz")
      :ok = StateTransfer.run(["export", vm, out], io(self()))
      write!(target, "users.json", ~s({"version":1,"users":[]}))

      assert :ok = StateTransfer.run(["import", out, "--state-dir", target, "--dry-run"], io(self()))
      dry = output(:out)
      assert dry =~ "Dry run: would import 8 document(s)"
      assert dry =~ "conflict  users.json"
      assert dry =~ "--overwrite is needed"
      refute File.exists?(Path.join(target, "usage.json"))

      assert {:error, message} = StateTransfer.run(["import", out, "--state-dir", target], io(self()))
      assert message =~ "1 existing document(s) differ: users.json"
      assert message =~ "Nothing was written"
      refute File.exists?(Path.join(target, "usage.json"))
      assert File.read!(Path.join(target, "users.json")) == ~s({"version":1,"users":[]})

      assert :ok = StateTransfer.run(["import", out, "--state-dir", target, "--overwrite", "--dry-run"], io(self()))
      assert output(:out) =~ "replace   users.json"
      refute File.exists?(Path.join(target, "usage.json"))

      assert :ok = StateTransfer.run(["import", out, "--state-dir", target, "--overwrite"], io(self()))
      assert output(:out) =~ "1 replace"
      assert File.read!(Path.join(target, "users.json")) == File.read!(Path.join(vm, "users.json"))
      assert File.exists?(Path.join(target, "usage.json"))
    end

    test "the session secret is skipped when the target configures its own" do
      vm = temp_dir!("vm")
      vm_state!(vm)
      out = Path.join(temp_dir!("out"), "state.tar.gz")
      :ok = StateTransfer.run(["export", vm, out], io(self()))

      target = temp_dir!("k8s")
      env_io = Keyword.put(io(self()), :getenv, fn "SYMPHONY_SECRET_KEY_BASE" -> String.duplicate("e", 64) end)
      assert :ok = StateTransfer.run(["import", out, "--state-dir", target], env_io)
      assert output(:out) =~ "skip      secret_key_base"
      refute File.exists?(Path.join(target, "secret_key_base"))
      assert File.exists?(Path.join(target, "users.json"))

      other = temp_dir!("k8s-flag")
      assert :ok = StateTransfer.run(["import", out, "--state-dir", other, "--skip-secret-key-base"], io(self()))
      assert output(:out) =~ "(--skip-secret-key-base)"
      refute File.exists?(Path.join(other, "secret_key_base"))

      short_env_io = Keyword.put(io(self()), :getenv, fn _name -> "short" end)
      third = temp_dir!("k8s-short")
      assert :ok = StateTransfer.run(["import", out, "--state-dir", third], short_env_io)
      assert File.read!(Path.join(third, "secret_key_base")) == @secret
    end

    test "a write failure stops the import with the key" do
      put_env(:state_store, __MODULE__.FailingStore)
      entries = [%{action: :unchanged, key: "inbox.json", body: "{}", bytes: 2}, %{action: :new, key: "users.json", body: "{}", bytes: 2}]
      assert {:error, "Writing users.json failed: :boom" <> _} = StateTransfer.apply_plan(entries)

      vm = temp_dir!("vm")
      target = temp_dir!("k8s")
      File.write!(Path.join(target, "factories"), "a file where the directory goes")
      write!(vm, "factories/PAY.json", "{}")
      assert {:error, "Can't read factories/PAY.json from the target: " <> _} = StateTransfer.run(["import", "-", "--state-dir", target], Keyword.put(io(self()), :stdin, fn -> archive!(vm) end))
    end
  end

  describe "bad input" do
    setup do
      keep_state_store_env()
      :ok
    end

    test "export refuses missing directories, unreadable and invalid documents" do
      assert {:error, "State directory not found: " <> _} = StateTransfer.export_archive(Path.join(temp_dir!("x"), "missing"))

      vm = temp_dir!("vm")
      write!(vm, "users.json", "not json")
      assert {:error, "users.json is not a JSON object" <> _} = StateTransfer.export_archive(vm)

      File.write!(Path.join(vm, "users.json"), "{}")
      write!(vm, "secret_key_base", "short")
      assert {:error, "secret_key_base is shorter than 64 bytes"} = StateTransfer.export_archive(vm)

      File.rm!(Path.join(vm, "secret_key_base"))
      File.mkdir_p!(Path.join(vm, "usage.json"))
      assert {:error, "Can't read usage.json: " <> _} = StateTransfer.export_archive(vm)

      File.rm_rf!(Path.join(vm, "usage.json"))
      unwritable = Path.join([temp_dir!("ro"), "missing-file-as-dir"])
      File.write!(unwritable, "")
      assert {:error, "Can't write " <> _} = StateTransfer.run(["export", vm, Path.join(unwritable, "out.tar.gz")], io(self()))
    end

    test "import rejects anything that isn't an intact export" do
      users = ~s({"version":1})

      assert {:error, "Not a Symphony state archive" <> _} = StateTransfer.read_archive("plain bytes")
      assert {:error, "Not a Symphony state archive (no manifest.json)"} = StateTransfer.read_archive(tarball!([{"state/users.json", users}]))
      assert {:error, "Not a Symphony state archive (bad manifest.json)"} = StateTransfer.read_archive(tarball!([{"manifest.json", "[]"}]))
      assert {:error, "Unsupported state archive version 2"} = StateTransfer.read_archive(tarball!([{"manifest.json", manifest([], 2)}]))

      assert {:error, "Not a Symphony state archive (bad manifest entry)"} =
               StateTransfer.read_archive(tarball!([{"manifest.json", Jason.encode!(%{"format" => "symphony-state", "version" => 1, "documents" => [%{"key" => 1}]})}]))

      assert {:error, message} = StateTransfer.read_archive(tarball!([{"manifest.json", manifest([{"sessions.json", "{}"}])}, {"state/sessions.json", "{}"}]))
      assert message =~ ~s("sessions.json", which is not a portable state document)

      assert {:error, "Archive is missing users.json" <> _} = StateTransfer.read_archive(tarball!([{"manifest.json", manifest([{"users.json", users}])}]))

      assert {:error, "users.json doesn't match its checksum" <> _} =
               StateTransfer.read_archive(tarball!([{"manifest.json", manifest([{"users.json", users}])}, {"state/users.json", "{}"}]))

      assert {:error, "Archive holds entries its manifest doesn't list: state/runs.json"} =
               StateTransfer.read_archive(tarball!([{"manifest.json", manifest([{"users.json", users}])}, {"state/users.json", users}, {"state/runs.json", "{}"}]))

      assert {:error, "secret_key_base is shorter than 64 bytes"} =
               StateTransfer.read_archive(tarball!([{"manifest.json", manifest([{"secret_key_base", "x"}])}, {"state/secret_key_base", "x"}]))

      assert {:ok, [{"users.json", ^users}]} = StateTransfer.read_archive(tarball!([{"manifest.json", manifest([{"users.json", users}])}, {"state/users.json", users}]))
      assert {:error, "Can't read " <> _} = StateTransfer.run(["import", Path.join(temp_dir!("x"), "missing.tar.gz"), "--state-dir", temp_dir!("t")], io(self()))
    end

    test "usage errors and an import without a target" do
      for args <- [[], ["export"], ["export", "a"], ["import"], ["import", "a", "b"], ["import", "a", "--bogus"], ["copy"]] do
        assert {:error, "Usage:" <> _} = StateTransfer.run(args, io(self())), inspect(args)
      end

      vm = temp_dir!("vm")
      write!(vm, "users.json", "{}")
      stdin_io = Keyword.put(io(self()), :stdin, fn -> archive!(vm) end)

      assert {:error, "Nothing to import into: " <> _} = StateTransfer.run(["import", "-"], stdin_io)

      put_env(:database_url, "ecto://u:p@db.example/symphony")
      assert {:error, "--state-dir imports into files" <> _} = StateTransfer.run(["import", "-", "--state-dir", temp_dir!("t")], stdin_io)
    end

    test "the CLI dispatches `state` to the transfer" do
      assert {:error, "Usage:" <> _} = CLI.evaluate(["state"], %{})
      assert :called = CLI.evaluate(["state", "export", "a", "b"], %{state: fn ["export", "a", "b"] -> :called end})
    end

    test "an unreachable database is an error, not a crash" do
      put_env(:database_url, "ecto://postgres@127.0.0.1:1/nowhere")
      previous = System.get_env("SYMPHONY_DATABASE_POOL_SIZE")
      System.put_env("SYMPHONY_DATABASE_POOL_SIZE", "1")
      on_exit(fn -> if previous, do: System.put_env("SYMPHONY_DATABASE_POOL_SIZE", previous), else: System.delete_env("SYMPHONY_DATABASE_POOL_SIZE") end)

      capture_log(fn ->
        assert {:error, message} = StateTransfer.prepare_target(nil)
        assert message =~ "Can't start the Postgres state store (127.0.0.1:1/nowhere)"
        refute message =~ "postgres@"
      end)

      refute Process.whereis(StateStore.Supervisor)
    end
  end

  describe "into postgres" do
    @describetag :postgres

    setup do
      keep_state_store_env()
      put_env(:database_url, System.fetch_env!("SYMPHONY_TEST_DATABASE_URL"))
      put_env(:state_root, temp_dir!("pg-root"))

      on_exit(fn ->
        case Process.whereis(StateStore.Supervisor) do
          nil -> :ok
          pid -> Supervisor.stop(pid)
        end
      end)

      :ok
    end

    test "imports into state_documents keyed by path, idempotently, and MCP tokens verify" do
      vm = temp_dir!("vm")
      vm_state!(vm)

      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, McpTokens)
      on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, McpTokens) end)
      start_supervised!({McpTokens, path: Path.join(vm, "mcp_tokens.json")})
      {:ok, secret, _token} = McpTokens.create("acct-1", "agent", ["read", "write"], 7, ["PAY"])
      :ok = stop_supervised(McpTokens)

      archive = archive!(vm)
      stdin_io = Keyword.put(io(self()), :stdin, fn -> archive end)

      capture_log(fn -> assert {:ok, "Postgres " <> _} = StateTransfer.prepare_target(nil) end)
      Repo.query!("TRUNCATE state_documents")

      assert :ok = StateTransfer.run(["import", "-"], stdin_io)
      imported = output(:out)
      assert imported =~ "Importing 9 document(s) into Postgres"
      refute imported =~ "@"
      refute imported =~ @marker

      %{rows: rows} = Repo.query!("SELECT key FROM state_documents ORDER BY key")

      assert List.flatten(rows) ==
               Enum.sort(~w(factories/PAY.json factories/project--web.json inbox.json mcp_tokens.json project_routes.json secret_key_base session_history.json usage.json users.json))

      assert {:ok, body} = StateStore.read(Path.join(StateStore.root(), "factories/project--web.json"))
      assert body == File.read!(Path.join(vm, "factories/project--web.json"))

      start_supervised!({McpTokens, path: Path.join(StateStore.root(), "mcp_tokens.json")})
      assert {:ok, %{account_id: "acct-1", scopes: ["read", "write"]}} = McpTokens.verify(secret)

      assert :ok = StateTransfer.run(["import", "-"], stdin_io)
      assert output(:out) =~ "Already up to date (9 unchanged)"

      :ok = StateStore.write(Path.join(StateStore.root(), "secret_key_base"), String.duplicate("n", 64))
      assert {:error, "1 existing document(s) differ: secret_key_base." <> _} = StateTransfer.run(["import", "-"], stdin_io)
      assert :ok = StateTransfer.run(["import", "-", "--overwrite"], stdin_io)
      assert {:ok, @secret} = StateStore.read(Path.join(StateStore.root(), "secret_key_base"))
    end

    test "read errors from the target stop the plan" do
      capture_log(fn -> assert {:ok, _target} = StateTransfer.prepare_target(nil) end)
      Repo.query!("ALTER TABLE state_documents RENAME TO state_documents_away")

      try do
        assert {:error, "Can't read users.json from the target: " <> _} = StateTransfer.plan([{"users.json", "{}"}])
      after
        Repo.query!("ALTER TABLE state_documents_away RENAME TO state_documents")
      end
    end
  end
end
