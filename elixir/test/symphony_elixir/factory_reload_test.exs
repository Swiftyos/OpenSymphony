defmodule SymphonyElixir.FactoryReloadTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Factory.{Definition, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-factories-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    :ok = Store.use_dir(dir)

    on_exit(fn ->
      :ok = Store.use_dir(nil)
      File.rm_rf!(dir)
    end)

    {:ok, _saved} = Store.put("PAY", Definition.default_template(), 0, "mia")
    %{path: Path.join(dir, "PAY.json")}
  end

  defp edit_on_disk(path, change) do
    path |> File.read!() |> Jason.decode!() |> change.() |> Jason.encode!() |> then(&File.write!(path, &1))
  end

  defp first_agent_instructions, do: Enum.find(Store.get("PAY")["stages"], &(&1["kind"] == "agent"))["instructions"]

  defp set_first_agent_instructions(definition, text) do
    {stages, _found} =
      Enum.map_reduce(definition["stages"], false, fn
        %{"kind" => "agent"} = stage, false -> {Map.put(stage, "instructions", text), true}
        stage, found -> {stage, found}
      end)

    %{definition | "stages" => stages}
  end

  test "a flow edited on disk takes effect on reload", %{path: path} do
    edit_on_disk(path, &(&1 |> set_first_agent_instructions("Edited on disk.") |> Map.put("version", 7)))

    capture_log(fn -> :ok = Store.reload() end)

    assert first_agent_instructions() == "Edited on disk."
    assert Store.get("PAY")["version"] == 7
  end

  test "an invalid edit is ignored and the last good flow stays", %{path: path} do
    before = Store.get("PAY")
    File.write!(path, "{not json")

    log = capture_log(fn -> :ok = Store.reload() end)

    assert log =~ "Factory definition skipped"
    assert Store.get("PAY")["stages"] == before["stages"]
  end

  test "deleting the file drops the scope's own flow", %{path: path} do
    assert Store.custom?("PAY")
    File.rm!(path)

    capture_log(fn -> :ok = Store.reload() end)

    refute Store.custom?("PAY")
    assert Store.get("PAY")["inherited"]
  end

  test "the store's own saves are not reloaded as edits" do
    {:ok, saved} = Store.put("PAY", Store.get("PAY") |> Map.drop(["team", "source", "inherited"]), 1, "ada")

    log = capture_log(fn -> :ok = Store.reload() end)

    refute log =~ "reloaded from disk"
    assert Store.get("PAY")["version"] == saved["version"]
  end

  test "a seeded flow is held in memory only and outlives a rescan", %{path: path} do
    dir = Path.dirname(path)
    definition = set_first_agent_instructions(Definition.default_template(), "From the run spec.")

    assert :ok = Store.seed("project:seeded", definition)
    on_exit(fn -> Store.reset_team("project:seeded") end)

    capture_log(fn -> :ok = Store.reload() end)

    assert Store.custom?("project:seeded")
    assert Enum.find(Store.get("project:seeded")["stages"], &(&1["kind"] == "agent"))["instructions"] == "From the run spec."
    refute File.exists?(Path.join(dir, "project--seeded.json"))
  end

  test "an invalid seed is refused" do
    assert {:error, [_ | _]} = Store.seed("PAY", %{"stages" => [%{"id" => "x"}]})
    assert {:error, :invalid_team} = Store.seed("not a team!", Definition.default_template())
  end

  defmodule UnavailableStateStore do
    @moduledoc false
    def list(_dir), do: {:error, :database_down}
  end

  test "a failed scan keeps the flows already loaded" do
    loaded = Store.get("PAY")
    Application.put_env(:symphony_elixir, :state_store, UnavailableStateStore)

    log =
      try do
        capture_log(fn -> :ok = Store.reload() end)
      after
        Application.delete_env(:symphony_elixir, :state_store)
      end

    assert log =~ "Factory scan failed"
    assert log =~ ":database_down"
    assert Store.get("PAY") == loaded
  end
end
