defmodule SymphonyElixir.RunLauncher.Kubernetes.JanitorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.RunLauncher.Kubernetes.Janitor

  @pods "/api/v1/namespaces/symphony-runs/pods"
  @secrets "/api/v1/namespaces/symphony-runs/secrets"
  @config_maps "/api/v1/namespaces/symphony-runs/configmaps"
  @now ~U[2026-10-21 12:00:00Z]

  setup do
    previous = Map.new([:kube_options, :run_launcher], &{&1, Application.get_env(:symphony_elixir, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    :ok
  end

  test "a sweep deletes finished pods past the retention and orphaned run Secrets" do
    parent = self()

    pods = [
      # Finished two hours ago: deleted.
      pod("run-old", "Succeeded", containers: [terminated_at("2026-10-21T10:00:00Z")]),
      # Failed; only an init container ran, two hours ago: deleted.
      pod("run-init", "Failed", init_containers: [terminated_at("2026-10-21T10:00:00Z")], containers: ["junk", %{"state" => %{}}]),
      # Evicted before any container ran: its start time counts.
      pod("run-evicted", "Failed", start_time: "2026-10-21T09:00:00Z"),
      # No start time either: its creation time counts.
      pod("run-created", "Failed", created: "2026-10-21T08:00:00Z"),
      # Finished ten minutes ago: kept for its logs.
      pod("run-recent", "Succeeded", containers: [terminated_at("2026-10-21T11:50:00Z")]),
      # Still running, or terminal without any timestamp: kept.
      pod("run-live", "Running", containers: [terminated_at("2026-10-21T08:00:00Z")]),
      pod("run-untimed", "Succeeded", created: "not-a-time")
    ]

    secrets = [
      # Has a pod: kept.
      secret("run-live", "2026-10-21T08:00:00Z"),
      # No pod, an hour old: deleted with its ConfigMap.
      secret("run-orphan", "2026-10-21T11:00:00Z"),
      # No pod, but young (its pod may be being created): kept.
      secret("run-young", "2026-10-21T11:55:00Z"),
      # Not a run Secret, or without a creation time: kept.
      secret("symphony-github", "2026-10-21T08:00:00Z"),
      secret("run-untimed-secret", nil)
    ]

    respond = fn
      "GET", @pods, conn ->
        send(parent, {:listed, :pods, conn.query_params["labelSelector"]})
        Req.Test.json(conn, %{"items" => pods})

      "GET", @secrets, conn ->
        send(parent, {:listed, :secrets, conn.query_params["labelSelector"]})
        Req.Test.json(conn, %{"items" => secrets})

      "DELETE", path, conn ->
        send(parent, {:deleted, path})
        Req.Test.json(conn, %{})
    end

    assert {:ok, %{pods: deleted_pods, secrets: ["run-orphan"]}} = Janitor.sweep(opts(respond))
    assert deleted_pods == ["run-old", "run-init", "run-evicted", "run-created"]

    assert_received {:listed, :pods, "app.kubernetes.io/name=symphony-runner"}
    assert_received {:listed, :secrets, "app.kubernetes.io/name=symphony-runner"}

    for name <- deleted_pods, do: assert_received({:deleted, @pods <> "/" <> ^name})
    assert_received {:deleted, @secrets <> "/run-orphan"}
    assert_received {:deleted, @config_maps <> "/run-orphan"}
    refute_received {:deleted, @pods <> "/run-recent"}
    refute_received {:deleted, @secrets <> "/run-young"}
  end

  test "a zero retention deletes a pod as soon as it finishes" do
    respond = fn
      "GET", @pods, conn -> Req.Test.json(conn, %{"items" => [pod("run-1", "Succeeded", containers: [terminated_at("2026-10-21T12:00:00Z")])]})
      "GET", @secrets, conn -> Req.Test.json(conn, %{"items" => []})
      "DELETE", _path, conn -> Req.Test.json(conn, %{})
    end

    assert {:ok, %{pods: ["run-1"], secrets: []}} =
             Janitor.sweep(Keyword.put(opts(respond), :settings, settings(%{"finished_pod_retention_ms" => 0})))
  end

  test "an object already gone counts as deleted and a failed delete is logged and left for the next sweep" do
    respond = fn
      "GET", @pods, conn -> Req.Test.json(conn, %{"items" => [pod("run-gone", "Failed", created: "2026-10-21T08:00:00Z"), pod("run-stuck", "Failed", created: "2026-10-21T08:00:00Z")]})
      "GET", @secrets, conn -> Req.Test.json(conn, %{"items" => [secret("run-orphan", "2026-10-21T08:00:00Z")]})
      "DELETE", @pods <> "/run-gone", conn -> Plug.Conn.send_resp(conn, 404, "")
      "DELETE", _path, conn -> Plug.Conn.send_resp(conn, 500, "boom")
    end

    log =
      capture_log(fn ->
        assert {:ok, %{pods: ["run-gone"], secrets: []}} = Janitor.sweep(opts(respond))
      end)

    assert log =~ "Runner janitor could not delete pod name=run-stuck"
    assert log =~ "Runner janitor could not delete secret name=run-orphan"
    assert log =~ "Runner janitor could not delete config_map name=run-orphan"
  end

  test "a failed list or missing credentials is an error" do
    respond = fn
      "GET", @pods, conn -> Req.Test.json(conn, %{"items" => []})
      "GET", @secrets, conn -> Plug.Conn.send_resp(conn, 403, "forbidden")
    end

    assert {:error, {:http_error, 403, "forbidden"}} = Janitor.sweep(opts(respond))
    assert {:error, :not_in_cluster} = Janitor.sweep(settings: settings(%{}))
    # Without explicit settings the loaded config is used.
    assert {:error, :not_in_cluster} = Janitor.sweep()
  end

  test "the janitor sweeps on its interval only while the launcher is Kubernetes" do
    parent = self()

    respond = fn
      "GET", @pods, conn ->
        send(parent, :swept)
        Req.Test.json(conn, %{"items" => [pod("run-old", "Failed", created: "2026-10-21T08:00:00Z")]})

      "GET", @secrets, conn ->
        Req.Test.json(conn, %{"items" => []})

      "DELETE", _path, conn ->
        Req.Test.json(conn, %{})
    end

    Application.put_env(:symphony_elixir, :run_launcher, SymphonyElixir.RunLauncher.Local)
    name = :"janitor_#{System.unique_integer([:positive])}"
    {:ok, janitor} = Janitor.start_link(Keyword.merge(opts(respond), name: name, interval_ms: 10))
    refute_receive :swept, 100

    log =
      capture_log(fn ->
        Application.put_env(:symphony_elixir, :run_launcher, SymphonyElixir.RunLauncher.Kubernetes)
        assert_receive :swept, 1_000
        assert_receive :swept, 1_000
        send(janitor, :unrelated)
        GenServer.stop(janitor)
      end)

    assert log =~ "Runner janitor deleted pods=1 secrets=0"
  end

  test "an empty sweep logs nothing and a failed one is logged" do
    parent = self()
    {:ok, fail?} = Agent.start_link(fn -> false end)

    respond = fn
      "GET", @pods, conn ->
        send(parent, :swept)

        if Agent.get(fail?, & &1),
          do: Plug.Conn.send_resp(conn, 500, "boom"),
          else: Req.Test.json(conn, %{"items" => []})

      "GET", @secrets, conn ->
        Req.Test.json(conn, %{"items" => []})
    end

    Application.put_env(:symphony_elixir, :run_launcher, SymphonyElixir.RunLauncher.Kubernetes)

    log =
      capture_log(fn ->
        {:ok, janitor} = Janitor.start_link(Keyword.merge(opts(respond), name: :"janitor_#{System.unique_integer([:positive])}", interval_ms: 10))
        assert_receive :swept, 1_000
        Agent.update(fail?, fn _ -> true end)
        assert_receive :swept, 1_000
        assert_receive :swept, 1_000
        GenServer.stop(janitor)
      end)

    refute log =~ "Runner janitor deleted"
    assert log =~ "Runner janitor sweep failed"
  end

  test "the interval comes from config, with a default when the config cannot load" do
    # The application already runs the default-named janitor.
    assert {:error, {:already_started, _pid}} = Janitor.start_link()
    {:ok, janitor} = Janitor.start_link(name: :"janitor_#{System.unique_integer([:positive])}")
    assert Process.alive?(janitor)
    GenServer.stop(janitor)

    previous_path = SymphonyElixir.Workflow.workflow_file_path()
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    try do
      SymphonyElixir.Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-janitor-#{System.unique_integer([:positive])}.md"))
      {:ok, janitor} = Janitor.start_link(name: :"janitor_#{System.unique_integer([:positive])}")
      assert Process.alive?(janitor)
      GenServer.stop(janitor)
    after
      SymphonyElixir.Workflow.set_workflow_file_path(previous_path)
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
    end
  end

  defp opts(respond) do
    [
      settings: settings(%{}),
      now: @now,
      base_url: "https://kube.test",
      req_options: [
        retry: false,
        plug: fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          respond.(conn.method, conn.request_path, conn)
        end
      ]
    ]
  end

  defp settings(kubernetes) do
    {:ok, settings} = Schema.parse(%{"agent" => %{"kubernetes" => kubernetes}})
    settings
  end

  defp pod(name, phase, opts) do
    status =
      %{"phase" => phase}
      |> put_present("containerStatuses", opts[:containers])
      |> put_present("initContainerStatuses", opts[:init_containers])
      |> put_present("startTime", opts[:start_time])

    %{"metadata" => %{"name" => name, "creationTimestamp" => opts[:created]}, "status" => status}
  end

  defp secret(name, created), do: %{"metadata" => %{"name" => name, "creationTimestamp" => created}}

  defp terminated_at(at), do: %{"name" => "runner", "state" => %{"terminated" => %{"finishedAt" => at}}}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
