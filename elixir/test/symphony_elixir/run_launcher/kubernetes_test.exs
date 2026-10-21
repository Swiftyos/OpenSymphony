defmodule SymphonyElixir.RunLauncher.KubernetesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.RunLauncher.Kubernetes
  alias SymphonyElixir.RunSpec

  @ref "k8s:symphony-runs/run-run-1"

  setup do
    previous = Application.get_env(:symphony_elixir, :kube_options)
    Application.delete_env(:symphony_elixir, :kube_options)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :kube_options)
        value -> Application.put_env(:symphony_elixir, :kube_options, value)
      end
    end)

    %{spec: spec()}
  end

  test "start creates the Secret, then the Pod, and returns the reference", %{spec: spec} do
    parent = self()

    respond = fn
      "POST", "/api/v1/namespaces/symphony-runs/secrets", _body, conn ->
        send(parent, :secret_created)
        Req.Test.json(conn, %{"kind" => "Secret"})

      "POST", "/api/v1/namespaces/symphony-runs/pods", _body, conn ->
        send(parent, :pod_created)
        Req.Test.json(conn, %{"kind" => "Pod"})

      "GET", "/api/v1/namespaces/symphony-runs/pods/run-run-1", _body, conn ->
        send(parent, :pod_polled)
        Req.Test.json(conn, %{"status" => %{"phase" => "Succeeded"}})

      "DELETE", "/api/v1/namespaces/symphony-runs/secrets/run-run-1", _body, conn ->
        send(parent, :secret_deleted)
        Req.Test.json(conn, %{})
    end

    assert {:ok, pid, ref} = Kubernetes.start(spec, opts(spec, respond))
    monitor = Process.monitor(pid)
    assert ref == @ref
    assert_receive :secret_created
    assert_receive :pod_created
    assert_receive :pod_polled
    assert_receive :secret_deleted
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
  end

  test "start accepts the behaviour's function and a spec option", %{spec: spec} do
    respond = fn _method, _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Running"}}) end

    assert {:ok, pid, @ref} = Kubernetes.start(fn -> :ok end, Keyword.put(opts(spec, respond), :spec, spec))
    Process.exit(pid, :kill)
  end

  test "start rejects a missing or invalid spec from the function form", %{spec: spec} do
    assert {:error, :missing_run_spec} = Kubernetes.start(fn -> :ok end, [])

    assert {:error, {:invalid_run_spec, :nope}} =
             Kubernetes.start(fn -> :ok end, spec: :nope)

    assert {:error, {:invalid_settings, :nope}} = Kubernetes.start(spec, settings: :nope)
    assert {:error, _reason} = Kubernetes.start(spec, [])
  end

  test "a failed Pod create deletes the Secret and returns the error", %{spec: spec} do
    parent = self()

    respond = fn
      "POST", "/api/v1/namespaces/symphony-runs/secrets", _body, conn ->
        send(parent, :secret_created)
        Req.Test.json(conn, %{"kind" => "Secret"})

      "POST", "/api/v1/namespaces/symphony-runs/pods", _body, conn ->
        Plug.Conn.send_resp(conn, 422, "rejected")

      "DELETE", "/api/v1/namespaces/symphony-runs/secrets/run-run-1", _body, conn ->
        send(parent, :secret_cleaned)
        Req.Test.json(conn, %{})
    end

    assert {:error, {:http_error, 422, "rejected"}} = Kubernetes.start(spec, opts(spec, respond))
    assert_receive :secret_created
    assert_receive :secret_cleaned
  end

  test "a failed Secret create does not create a Pod", %{spec: spec} do
    respond = fn _method, _path, _body, conn -> Plug.Conn.send_resp(conn, 409, "exists") end

    assert {:error, {:http_error, 409, "exists"}} = Kubernetes.start(spec, opts(spec, respond))
  end

  test "alive? is true for Pending and Running pods and false otherwise" do
    for phase <- ["Pending", "Running"] do
      put_kube_options(phase_responder(phase))
      assert Kubernetes.alive?(@ref)
    end

    for phase <- ["Succeeded", "Failed", "Unknown"] do
      put_kube_options(phase_responder(phase))
      refute Kubernetes.alive?(@ref)
    end

    put_kube_options(fn _method, _path, _body, conn -> Req.Test.json(conn, %{}) end)
    refute Kubernetes.alive?(@ref)

    put_kube_options(fn _method, _path, _body, conn -> Plug.Conn.send_resp(conn, 404, "") end)
    refute Kubernetes.alive?(@ref)

    refute Kubernetes.alive?("local:not-a-pod")
    refute Kubernetes.alive?("k8s:namespace-only")
    refute Kubernetes.alive?("k8s:/missing-namespace")
    refute Kubernetes.alive?(nil)
  end

  test "alive? is false when no Kubernetes client can be configured" do
    refute Kubernetes.alive?(@ref)
  end

  test "stop deletes the Pod and Secret and ignores missing objects and bad references" do
    parent = self()

    put_kube_options(fn method, path, _body, conn ->
      send(parent, {:deleted, method, path})
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert :ok = Kubernetes.stop(@ref)
    assert_receive {:deleted, "DELETE", "/api/v1/namespaces/symphony-runs/pods/run-run-1"}
    assert_receive {:deleted, "DELETE", "/api/v1/namespaces/symphony-runs/secrets/run-run-1"}

    assert :ok = Kubernetes.stop("k8s:bad")
    assert :ok = Kubernetes.stop(nil)
  end

  test "stop is a no-op when no Kubernetes client can be configured" do
    assert :ok = Kubernetes.stop(@ref)
  end

  test "the monitor keeps polling while the pod is pending", %{spec: spec} do
    {:ok, agent} = Agent.start_link(fn -> [:pending, :succeeded] end)

    respond = fn
      "POST", _path, _body, conn ->
        Req.Test.json(conn, %{})

      "GET", _path, _body, conn ->
        case Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end) do
          :pending -> Req.Test.json(conn, %{"status" => %{"phase" => "Pending"}})
          :succeeded -> Req.Test.json(conn, %{"status" => %{"phase" => "Succeeded"}})
        end

      "DELETE", _path, _body, conn ->
        Req.Test.json(conn, %{})
    end

    assert {:ok, pid, @ref} = Kubernetes.start(spec, opts(spec, respond))
    assert_down(pid, :normal)
  end

  test "the monitor exits with the pod failure reason", %{spec: spec} do
    respond = fn
      "POST", _path, _body, conn -> Req.Test.json(conn, %{})
      "GET", _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Failed", "reason" => "OOMKilled"}})
      "DELETE", _path, _body, conn -> Req.Test.json(conn, %{})
    end

    assert {:ok, pid, @ref} = Kubernetes.start(spec, opts(spec, respond))
    assert_down(pid, {:pod_failed, "OOMKilled"})
  end

  test "a failed pod without a reason uses the generic reason", %{spec: spec} do
    respond = fn
      "POST", _path, _body, conn -> Req.Test.json(conn, %{})
      "GET", _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Failed"}})
      "DELETE", _path, _body, conn -> Req.Test.json(conn, %{})
    end

    assert {:ok, pid, @ref} = Kubernetes.start(spec, opts(spec, respond))
    assert_down(pid, {:pod_failed, "failed"})
  end

  test "the monitor exits :pod_lost when the pod disappears", %{spec: spec} do
    respond = fn
      "POST", _path, _body, conn -> Req.Test.json(conn, %{})
      "GET", _path, _body, conn -> Plug.Conn.send_resp(conn, 404, "")
      "DELETE", _path, _body, conn -> Plug.Conn.send_resp(conn, 404, "")
    end

    assert {:ok, pid, @ref} = Kubernetes.start(spec, opts(spec, respond))
    assert_down(pid, :pod_lost)
  end

  test "a transient poll error is retried", %{spec: spec} do
    {:ok, agent} = Agent.start_link(fn -> [:error, :succeeded] end)

    respond = fn
      "POST", _path, _body, conn ->
        Req.Test.json(conn, %{})

      "GET", _path, _body, conn ->
        case Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end) do
          :error -> Plug.Conn.send_resp(conn, 500, "not yet")
          :succeeded -> Req.Test.json(conn, %{"status" => %{"phase" => "Succeeded"}})
        end

      "DELETE", _path, _body, conn ->
        Req.Test.json(conn, %{})
    end

    log =
      capture_log(fn ->
        assert {:ok, pid, @ref} = Kubernetes.start(spec, opts(spec, respond))
        assert_down(pid, :normal)
      end)

    assert log =~ "Runner pod poll failed"
  end

  test "a Secret cleanup failure is logged and does not stop the run from finishing", %{spec: spec} do
    respond = fn
      "POST", _path, _body, conn -> Req.Test.json(conn, %{})
      "GET", _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Succeeded"}})
      "DELETE", _path, _body, conn -> Plug.Conn.send_resp(conn, 500, "boom")
    end

    log =
      capture_log(fn ->
        assert {:ok, pid, @ref} = Kubernetes.start(spec, opts(spec, respond))
        assert_down(pid, :normal)
      end)

    assert log =~ "Runner Secret cleanup failed"
  end

  defp opts(_spec, respond) do
    [
      settings: settings(),
      base_url: "https://kube.test",
      poll_interval_ms: 10,
      req_options: [retry: false, plug: plug(respond)]
    ]
  end

  defp assert_down(pid, reason) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}, 2_000
  end

  defp put_kube_options(respond) do
    Application.put_env(:symphony_elixir, :kube_options,
      base_url: "https://kube.test",
      req_options: [retry: false, plug: plug(respond)]
    )
  end

  defp plug(respond) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      respond.(conn.method, conn.request_path, body, conn)
    end
  end

  defp phase_responder(phase) do
    fn _method, _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => phase}}) end
  end

  defp settings do
    assert {:ok, settings} =
             Schema.parse(%{
               "workspace" => %{"root" => "/workspace"},
               "agent" => %{
                 "kubernetes" => %{
                   "runner_image" => "registry.test/symphony:test",
                   "agent_tools_image" => "registry.test/tools:test"
                 }
               }
             })

    settings
  end

  defp spec do
    %RunSpec{
      run_id: "run-1",
      epoch: 1,
      attempt: 1,
      issue: %{id: "issue-1", identifier: "MT-1"},
      controller_url: "http://symphony:4000",
      token: "run-token"
    }
  end
end
