defmodule SymphonyElixir.ConfigCoverageStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SymphonyConfigStore

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-coverage-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  defp write_config!(path, value) do
    File.write!(path, "marker: #{value}\n")
    path
  end

  defp marker do
    assert {:ok, %{config: %{"marker" => value}}} = SymphonyConfigStore.current()
    value
  end

  describe "SymphonyConfig.load/1" do
    test "reports missing files, non-map documents and parse errors", %{root: root} do
      missing = Path.join(root, "missing.yml")
      assert {:error, {:missing_symphony_config_file, ^missing, :enoent}} = SymphonyConfig.load(missing)

      list_path = Path.join(root, "list.yml")
      File.write!(list_path, "- one\n- two\n")
      assert {:error, :symphony_config_not_a_map} = SymphonyConfig.load(list_path)

      broken_path = Path.join(root, "broken.yml")
      File.write!(broken_path, "key: [unclosed\n")
      assert {:error, {:symphony_config_parse_error, _reason}} = SymphonyConfig.load(broken_path)

      good_path = write_config!(Path.join(root, "good.yml"), "one")
      assert {:ok, %{config: %{"marker" => "one"}, path: ^good_path}} = SymphonyConfig.load(good_path)
    end

    test "clear_config_file_path resets to the cwd symphony.yml in global mode", %{root: root} do
      SymphonyConfig.set_config_file_path(write_config!(Path.join(root, "symphony.yml"), "one"))
      assert SymphonyConfig.config_file_path() == Path.join(root, "symphony.yml")

      assert :ok = SymphonyConfig.clear_config_file_path()
      assert SymphonyConfig.config_file_path() == Path.join(File.cwd!(), "symphony.yml")
      assert Application.get_env(:symphony_elixir, :startup_mode) == :global
    end
  end

  describe "without a running store" do
    test "current and force_reload fall back to loading the file", %{root: root} do
      refute Process.whereis(SymphonyConfigStore)

      path = write_config!(Path.join(root, "symphony.yml"), "direct")
      SymphonyConfig.set_config_file_path(path)

      assert {:ok, %{config: %{"marker" => "direct"}}} = SymphonyConfigStore.current()
      assert :ok = SymphonyConfigStore.force_reload()

      File.rm!(path)

      assert {:error, {:missing_symphony_config_file, ^path, :enoent}} = SymphonyConfigStore.force_reload()
      assert {:error, {:missing_symphony_config_file, ^path, :enoent}} = SymphonyConfigStore.current()
    end
  end

  describe "with a running store" do
    test "init stops when the configured file cannot be loaded", %{root: root} do
      Application.put_env(:symphony_elixir, :symphony_config_path, Path.join(root, "missing.yml"))

      assert {:error, {{:missing_symphony_config_file, _path, :enoent}, _child}} =
               start_supervised(SymphonyConfigStore)
    end

    test "serves, reloads and keeps the last good config", %{root: root} do
      path = write_config!(Path.join(root, "symphony.yml"), "one")
      Application.put_env(:symphony_elixir, :symphony_config_path, path)

      pid = start_supervised!(%{id: SymphonyConfigStore, start: {SymphonyConfigStore, :start_link, []}})
      assert Process.whereis(SymphonyConfigStore) == pid

      assert marker() == "one"
      assert {:ok, %{config: %{"marker" => "one"}}} = SymphonyConfig.current()
      assert :ok = SymphonyConfigStore.force_reload()

      write_config!(path, "two")
      assert marker() == "two"

      File.write!(path, "marker: [unclosed\n")

      log =
        capture_log(fn ->
          assert marker() == "two"
          assert {:error, {:symphony_config_parse_error, _}} = SymphonyConfigStore.force_reload()
        end)

      assert log =~ "Failed to reload symphony config path=#{path}"
      assert log =~ "keeping last known good configuration"

      File.rm!(path)

      log =
        capture_log(fn ->
          assert marker() == "two"
          assert {:error, :enoent} = SymphonyConfigStore.force_reload()
        end)

      assert log =~ "reason=:enoent"
    end

    test "follows config path changes and polls in the background", %{root: root} do
      first = write_config!(Path.join(root, "first.yml"), "first")
      Application.put_env(:symphony_elixir, :symphony_config_path, first)

      pid = start_supervised!(SymphonyConfigStore)
      assert marker() == "first"

      second = write_config!(Path.join(root, "second.yml"), "second")
      SymphonyConfig.set_config_file_path(second)
      assert %{path: ^second, config: %{config: %{"marker" => "second"}}} = :sys.get_state(pid)

      write_config!(second, "polled")
      send(pid, :poll)
      assert %{config: %{config: %{"marker" => "polled"}}} = :sys.get_state(pid)

      missing = Path.join(root, "missing.yml")
      Application.put_env(:symphony_elixir, :symphony_config_path, missing)

      log =
        capture_log(fn ->
          send(pid, :poll)
          assert %{path: ^second, config: %{config: %{"marker" => "polled"}}} = :sys.get_state(pid)
          assert marker() == "polled"
        end)

      assert log =~ "Failed to reload symphony config path=#{missing}"
    end
  end

  describe "SymphonyElixir.Application" do
    test "selects the symphony config store in global startup mode" do
      Application.put_env(:symphony_elixir, :startup_mode, :global)
      supervisor = Process.whereis(SymphonyElixir.Supervisor)

      assert {:error, {:already_started, ^supervisor}} = SymphonyElixir.Application.start(:normal, [])
    end
  end
end
