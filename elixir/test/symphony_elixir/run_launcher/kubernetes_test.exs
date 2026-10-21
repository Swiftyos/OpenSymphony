defmodule SymphonyElixir.RunLauncher.KubernetesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.RunLauncher.Kubernetes
  alias SymphonyElixir.RunSpec

  # "run-" <> Base.encode16("run-1", case: :lower)
  @name "run-72756e2d31"
  @ref "k8s:symphony-runs/" <> @name
  @pods "/api/v1/namespaces/symphony-runs/pods"
  @pod @pods <> "/" <> @name
  @secrets "/api/v1/namespaces/symphony-runs/secrets"
  @secret @secrets <> "/" <> @name
  @config_maps "/api/v1/namespaces/symphony-runs/configmaps"
  @config_map @config_maps <> "/" <> @name

  setup do
    previous = Application.get_env(:symphony_elixir, :kube_options)
    Application.delete_env(:symphony_elixir, :kube_options)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :kube_options)
        value -> Application.put_env(:symphony_elixir, :kube_options, value)
      end
    end)

    %{spec: spec(), config_path: config_file("symphony.yml", "workspace:\n  root: /workspace\n")}
  end

  test "start creates the Secret, ConfigMap and Pod, owns them by the pod and returns the reference", ctx do
    parent = self()

    respond = fn
      "POST", @secrets, _body, conn ->
        send(parent, :secret_created)
        Req.Test.json(conn, %{"kind" => "Secret"})

      "POST", @config_maps, body, conn ->
        send(parent, {:config_map_created, Jason.decode!(body)})
        Req.Test.json(conn, %{"kind" => "ConfigMap"})

      "POST", @pods, body, conn ->
        send(parent, {:pod_created, Jason.decode!(body)})
        Req.Test.json(conn, %{"kind" => "Pod", "metadata" => %{"uid" => "pod-uid-1"}})

      "PATCH", path, body, conn ->
        send(parent, {:patched, path, Jason.decode!(body)})
        Req.Test.json(conn, %{})

      "GET", @pod, _body, conn ->
        send(parent, :pod_polled)
        Req.Test.json(conn, %{"status" => %{"phase" => "Succeeded"}})

      "DELETE", path, _body, conn ->
        send(parent, {:deleted, path})
        Req.Test.json(conn, %{})
    end

    assert {:ok, pid, ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
    monitor = Process.monitor(pid)
    assert ref == @ref
    assert_receive :secret_created
    assert_receive {:config_map_created, %{"data" => %{"symphony.yml" => "workspace:\n  root: /workspace\n"}}}
    assert_receive {:pod_created, pod}
    assert Enum.at(hd(pod["spec"]["containers"])["args"], 2) == "/etc/symphony/symphony.yml"

    owner = %{"metadata" => %{"ownerReferences" => [%{"apiVersion" => "v1", "kind" => "Pod", "name" => @name, "uid" => "pod-uid-1"}]}}
    assert_receive {:patched, @secret, ^owner}
    assert_receive {:patched, @config_map, ^owner}

    assert_receive :pod_polled
    assert_receive {:deleted, @secret}
    assert_receive {:deleted, @config_map}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
  end

  test "start accepts the behaviour's function and a spec option", ctx do
    respond = fn _method, _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Running"}}) end

    log =
      capture_log(fn ->
        assert {:ok, pid, @ref} = Kubernetes.start(fn -> :ok end, Keyword.put(opts(ctx, respond), :spec, ctx.spec))
        Process.exit(pid, :kill)
      end)

    assert log =~ "Runner pod has no uid"
  end

  test "start rejects a missing or invalid spec from the function form", ctx do
    assert {:error, :missing_run_spec} = Kubernetes.start(fn -> :ok end, [])

    assert {:error, {:invalid_run_spec, :nope}} =
             Kubernetes.start(fn -> :ok end, spec: :nope)

    assert {:error, {:invalid_settings, :nope}} = Kubernetes.start(ctx.spec, settings: :nope)
    assert {:error, _reason} = Kubernetes.start(ctx.spec, [])
  end

  test "an unreadable runner config is an error before anything is created", ctx do
    missing = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.yml")
    respond = fn _method, _path, _body, _conn -> flunk("no API call expected") end

    assert {:error, {:runner_config, ^missing, :enoent}} =
             Kubernetes.start(ctx.spec, Keyword.put(opts(ctx, respond), :config_path, missing))
  end

  test "the runner gets the controller's own config file by mode", ctx do
    workflow = config_file("WORKFLOW.md", "---\n---\nPrompt")
    global = config_file("prod.yml", "agent: {}\n")
    previous = Map.new([:startup_mode, :workflow_file_path, :symphony_config_path], &{&1, Application.get_env(:symphony_elixir, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    parent = self()

    respond = fn
      "POST", @config_maps, body, conn ->
        send(parent, {:config_map, Jason.decode!(body)["data"]})
        Req.Test.json(conn, %{})

      _method, _path, _body, conn ->
        Req.Test.json(conn, %{"status" => %{"phase" => "Running"}})
    end

    base_opts = Keyword.delete(opts(ctx, respond), :config_path)

    Application.put_env(:symphony_elixir, :startup_mode, :legacy)
    Application.put_env(:symphony_elixir, :workflow_file_path, workflow)

    capture_log(fn ->
      assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, base_opts)
      Process.exit(pid, :kill)
    end)

    assert_receive {:config_map, %{"WORKFLOW.md" => "---\n---\nPrompt"}}

    Application.put_env(:symphony_elixir, :startup_mode, :global)
    Application.put_env(:symphony_elixir, :symphony_config_path, global)

    capture_log(fn ->
      assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, base_opts)
      Process.exit(pid, :kill)
    end)

    assert_receive {:config_map, %{"symphony.yml" => "agent: {}\n"}}
  end

  test "a leftover Secret and ConfigMap from a crashed attempt are replaced", ctx do
    parent = self()
    {:ok, seen} = Agent.start_link(fn -> MapSet.new() end)

    first_time? = fn path -> Agent.get_and_update(seen, &{not MapSet.member?(&1, path), MapSet.put(&1, path)}) end

    respond = fn
      "POST", path, _body, conn when path in [@secrets, @config_maps] ->
        if first_time?.(path) do
          Plug.Conn.send_resp(conn, 409, "exists")
        else
          send(parent, {:recreated, path})
          Req.Test.json(conn, %{})
        end

      "DELETE", path, _body, conn ->
        send(parent, {:deleted, path})
        Req.Test.json(conn, %{})

      "POST", @pods, _body, conn ->
        Req.Test.json(conn, %{"metadata" => %{"uid" => "uid"}})

      _method, _path, _body, conn ->
        Req.Test.json(conn, %{"status" => %{"phase" => "Running"}})
    end

    capture_log(fn ->
      assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
      Process.exit(pid, :kill)
    end)

    assert_receive {:deleted, @secret}
    assert_receive {:recreated, @secrets}
    assert_receive {:deleted, @config_map}
    assert_receive {:recreated, @config_maps}
  end

  test "a conflict that cannot be replaced is returned and no pod is created", ctx do
    parent = self()

    respond = fn
      "POST", @pods, _body, _conn ->
        flunk("no pod expected")

      "POST", _path, _body, conn ->
        Plug.Conn.send_resp(conn, 409, "exists")

      "DELETE", path, _body, conn ->
        send(parent, {:deleted, path})
        Plug.Conn.send_resp(conn, 403, "forbidden")
    end

    capture_log(fn ->
      assert {:error, {:http_error, 403, "forbidden"}} = Kubernetes.start(ctx.spec, opts(ctx, respond))
    end)

    assert_receive {:deleted, @secret}
  end

  test "a failed ConfigMap create deletes the Secret and creates no pod", ctx do
    parent = self()

    respond = fn
      "POST", @secrets, _body, conn ->
        Req.Test.json(conn, %{})

      "POST", @config_maps, _body, conn ->
        Plug.Conn.send_resp(conn, 422, "invalid")

      "POST", @pods, _body, _conn ->
        flunk("no pod expected")

      "DELETE", path, _body, conn ->
        send(parent, {:deleted, path})
        Plug.Conn.send_resp(conn, 404, "")
    end

    assert {:error, {:http_error, 422, "invalid"}} = Kubernetes.start(ctx.spec, opts(ctx, respond))
    assert_receive {:deleted, @secret}
    assert_receive {:deleted, @config_map}
  end

  test "a rejected Pod create deletes the Secret and ConfigMap and returns the error", ctx do
    parent = self()

    respond = fn
      "POST", @pods, _body, conn ->
        Plug.Conn.send_resp(conn, 422, "rejected")

      "POST", _path, _body, conn ->
        Req.Test.json(conn, %{})

      "GET", _path, _body, _conn ->
        flunk("a rejection needs no read-back")

      "DELETE", path, _body, conn ->
        send(parent, {:deleted, path})
        Req.Test.json(conn, %{})
    end

    assert {:error, {:http_error, 422, "rejected"}} = Kubernetes.start(ctx.spec, opts(ctx, respond))
    assert_receive {:deleted, @secret}
    assert_receive {:deleted, @config_map}
    refute_received {:deleted, @pod}
  end

  test "a Pod create timeout reads the pod back and continues when it exists", ctx do
    parent = self()

    respond = fn
      "POST", @pods, _body, conn ->
        Req.Test.transport_error(conn, :timeout)

      "POST", _path, _body, conn ->
        Req.Test.json(conn, %{})

      "GET", @pod, _body, conn ->
        Req.Test.json(conn, %{"metadata" => %{"uid" => "uid-2"}, "status" => %{"phase" => "Pending"}})

      "PATCH", path, _body, conn ->
        send(parent, {:patched, path})
        Req.Test.json(conn, %{})
    end

    log =
      capture_log(fn ->
        assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
        assert_receive {:patched, @secret}
        assert_receive {:patched, @config_map}
        Process.exit(pid, :kill)
      end)

    assert log =~ "the pod exists"
  end

  test "a Pod create timeout cleans up when the pod does not exist", ctx do
    parent = self()

    respond = fn
      "POST", @pods, _body, conn ->
        Req.Test.transport_error(conn, :timeout)

      "POST", _path, _body, conn ->
        Req.Test.json(conn, %{})

      "GET", @pod, _body, conn ->
        Plug.Conn.send_resp(conn, 404, "")

      "DELETE", path, _body, conn ->
        send(parent, {:deleted, path})
        Req.Test.json(conn, %{})
    end

    assert {:error, %Req.TransportError{reason: :timeout}} = Kubernetes.start(ctx.spec, opts(ctx, respond))
    assert_receive {:deleted, @secret}
    assert_receive {:deleted, @config_map}
    refute_received {:deleted, @pod}
  end

  test "a Pod create timeout with an unreadable pod removes the pod and its objects", ctx do
    parent = self()

    respond = fn
      "POST", @pods, _body, conn ->
        Req.Test.transport_error(conn, :timeout)

      "POST", _path, _body, conn ->
        Req.Test.json(conn, %{})

      "GET", @pod, _body, conn ->
        Req.Test.transport_error(conn, :econnrefused)

      "DELETE", path, _body, conn ->
        send(parent, {:deleted, path})
        Req.Test.json(conn, %{})
    end

    assert {:error, %Req.TransportError{reason: :timeout}} = Kubernetes.start(ctx.spec, opts(ctx, respond))
    assert_receive {:deleted, @pod}
    assert_receive {:deleted, @secret}
    assert_receive {:deleted, @config_map}
  end

  test "a failed ownerReference patch is logged and the run continues", ctx do
    respond = fn
      "POST", @pods, _body, conn -> Req.Test.json(conn, %{"metadata" => %{"uid" => "uid"}})
      "POST", _path, _body, conn -> Req.Test.json(conn, %{})
      "PATCH", _path, _body, conn -> Plug.Conn.send_resp(conn, 403, "forbidden")
      "GET", _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Succeeded"}})
      "DELETE", _path, _body, conn -> Req.Test.json(conn, %{})
    end

    log =
      capture_log(fn ->
        assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
        assert_down(pid, :normal)
      end)

    assert log =~ "Runner secret ownerReference failed"
    assert log =~ "Runner config_map ownerReference failed"
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

  test "stop deletes the Pod, Secret and ConfigMap and ignores missing objects and bad references" do
    parent = self()

    put_kube_options(fn method, path, _body, conn ->
      send(parent, {:deleted, method, path})
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert :ok = Kubernetes.stop(@ref)
    assert_receive {:deleted, "DELETE", @pod}
    assert_receive {:deleted, "DELETE", @secret}
    assert_receive {:deleted, "DELETE", @config_map}

    assert :ok = Kubernetes.stop("k8s:bad")
    assert :ok = Kubernetes.stop(nil)
  end

  test "stop is a no-op when no Kubernetes client can be configured" do
    assert :ok = Kubernetes.stop(@ref)
  end

  test "the monitor keeps polling while the pod is pending", ctx do
    respond = sequence_responder([pending(), pending(), pending(), phase_body("Succeeded")])

    assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
    assert_down(pid, :normal)
  end

  test "the monitor exits with the pod's own failure reason", ctx do
    respond = sequence_responder([%{"status" => %{"phase" => "Failed", "reason" => "DeadlineExceeded"}}])

    assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
    assert_down(pid, {:pod_failed, "DeadlineExceeded"})
  end

  test "the monitor reports the runner container's terminated reason and exit code", ctx do
    statuses = [
      %{"name" => "agent-tools", "state" => %{"terminated" => %{"reason" => "Completed", "exitCode" => 0}}},
      %{"name" => "runner", "state" => %{"terminated" => %{"reason" => "OOMKilled", "exitCode" => 137}}}
    ]

    respond = sequence_responder([%{"status" => %{"phase" => "Failed", "containerStatuses" => statuses}}])

    assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
    assert_down(pid, {:pod_failed, "OOMKilled (exit code 137)"})
  end

  test "a terminated runner without a reason or exit code still has a failure reason", ctx do
    for {terminated, expected} <- [
          {%{"exitCode" => 2}, "failed (exit code 2)"},
          {%{"reason" => "Error"}, "Error"},
          {%{"reason" => ""}, "failed"}
        ] do
      statuses = ["not-a-map", %{"name" => "runner", "state" => %{"terminated" => terminated}}]
      respond = sequence_responder([%{"status" => %{"phase" => "Failed", "containerStatuses" => statuses}}])

      assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
      assert_down(pid, {:pod_failed, expected})
    end
  end

  test "a failed pod without a reason or runner state uses the generic reason", ctx do
    for status <- [
          %{"phase" => "Failed"},
          %{"phase" => "Failed", "containerStatuses" => [%{"name" => "runner", "state" => %{"running" => %{}}}]}
        ] do
      respond = sequence_responder([%{"status" => status}])

      assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
      assert_down(pid, {:pod_failed, "failed"})
    end
  end

  test "the monitor exits :pod_lost when the pod disappears", ctx do
    respond = fn
      "POST", _path, _body, conn -> Req.Test.json(conn, %{})
      "GET", _path, _body, conn -> Plug.Conn.send_resp(conn, 404, "")
      "DELETE", _path, _body, conn -> Plug.Conn.send_resp(conn, 404, "")
    end

    capture_log(fn ->
      assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
      assert_down(pid, :pod_lost)
    end)
  end

  test "a transient poll error is retried", ctx do
    respond = sequence_responder([{500, "not yet"}, phase_body("Succeeded")])

    log =
      capture_log(fn ->
        assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
        assert_down(pid, :normal)
      end)

    assert log =~ "Runner pod poll failed"
  end

  test "a short burst of 401/403 is retried and a success resets it", ctx do
    respond = sequence_responder([{401, "expired"}, {403, "forbidden"}, pending(), {401, "expired"}, phase_body("Succeeded")])

    log =
      capture_log(fn ->
        assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
        assert_down(pid, :normal)
      end)

    assert log =~ "Runner pod poll failed"
  end

  test "a 401/403 that persists past the timeout exits the monitor", ctx do
    respond = sequence_responder([{401, "expired"}, {403, "forbidden"}])

    log =
      capture_log(fn ->
        assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, Keyword.put(opts(ctx, respond), :unauthorized_timeout_ms, 5))
        assert_down(pid, {:pod_monitor_unauthorized, {:http_error, 403, "forbidden"}})
      end)

    assert log =~ "unauthorized for too long"
  end

  test "a Secret or ConfigMap cleanup failure is logged and does not stop the run from finishing", ctx do
    respond = fn
      "POST", _path, _body, conn -> Req.Test.json(conn, %{})
      "PATCH", _path, _body, conn -> Req.Test.json(conn, %{})
      "GET", _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Succeeded"}})
      "DELETE", _path, _body, conn -> Plug.Conn.send_resp(conn, 500, "boom")
    end

    log =
      capture_log(fn ->
        assert {:ok, pid, @ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
        assert_down(pid, :normal)
      end)

    assert log =~ "Runner secret cleanup failed"
    assert log =~ "Runner config_map cleanup failed"
  end

  defp opts(ctx, respond) do
    [
      settings: settings(),
      config_path: ctx.config_path,
      base_url: "https://kube.test",
      poll_interval_ms: 10,
      req_options: [retry: false, plug: plug(respond)]
    ]
  end

  # Creates and patches succeed (the pod with a uid); each GET answers the next
  # body (or {status, body}) in the list, the last one repeating.
  defp sequence_responder(polls) do
    {:ok, agent} = Agent.start_link(fn -> polls end)

    fn
      "POST", @pods, _body, conn ->
        Req.Test.json(conn, %{"metadata" => %{"uid" => "uid"}})

      "GET", _path, _body, conn ->
        respond_with(conn, Agent.get_and_update(agent, &next_poll/1))

      _method, _path, _body, conn ->
        Req.Test.json(conn, %{})
    end
  end

  defp next_poll([last]), do: {last, [last]}
  defp next_poll([next | rest]), do: {next, rest}

  defp respond_with(conn, {status, body}), do: Plug.Conn.send_resp(conn, status, body)
  defp respond_with(conn, body), do: Req.Test.json(conn, body)

  defp pending, do: phase_body("Pending")
  defp phase_body(phase), do: %{"status" => %{"phase" => phase}}

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

  defp config_file(name, content) do
    directory = Path.join(System.tmp_dir!(), "kube-runner-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    path = Path.join(directory, name)
    File.write!(path, content)
    path
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
