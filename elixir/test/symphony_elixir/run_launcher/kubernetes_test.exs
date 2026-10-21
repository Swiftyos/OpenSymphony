defmodule SymphonyElixir.RunLauncher.KubernetesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Capacity.Metrics
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.RunLauncher
  alias SymphonyElixir.RunLauncher.Kubernetes
  alias SymphonyElixir.RunLauncher.Kubernetes.PodSpec
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.RunWatcher

  @pods "/api/v1/namespaces/symphony-runs/pods"
  @secrets "/api/v1/namespaces/symphony-runs/secrets"
  @config_maps "/api/v1/namespaces/symphony-runs/configmaps"

  setup do
    previous = Application.get_env(:symphony_elixir, :kube_options)
    Application.delete_env(:symphony_elixir, :kube_options)

    run_id = "run-#{System.unique_integer([:positive])}"
    name = PodSpec.resource_name(run_id)

    on_exit(fn ->
      RunWatcher.stop(run_id)

      case previous do
        nil -> Application.delete_env(:symphony_elixir, :kube_options)
        value -> Application.put_env(:symphony_elixir, :kube_options, value)
      end
    end)

    %{
      spec: spec(run_id),
      run_id: run_id,
      name: name,
      ref: "k8s:symphony-runs/" <> name,
      pod: @pods <> "/" <> name,
      secret: @secrets <> "/" <> name,
      config_map: @config_maps <> "/" <> name,
      config_path: config_file("symphony.yml", "workspace:\n  root: /workspace\n")
    }
  end

  describe "starting a run" do
    test "creates the Secret, ConfigMap and Pod, owns them by the pod and returns a watcher", ctx do
      parent = self()
      %{pod: pod_path, secret: secret_path, config_map: config_map_path, name: name} = ctx

      respond = fn
        "POST", @secrets, body, conn ->
          send(parent, {:secret_created, Jason.decode!(body)})
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

        "GET", ^pod_path, _body, conn ->
          Req.Test.json(conn, %{"status" => %{"phase" => "Running"}})
      end

      log =
        capture_log(fn ->
          assert {:ok, watcher, ref} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
          assert ref == ctx.ref
          assert RunWatcher.last_seen(ctx.run_id)
          monitor = Process.monitor(watcher)

          # The pod's end reaches the orchestrator like a process run's: the
          # runner's finished event ends the watcher.
          RunWatcher.finished(ctx.run_id, "normal")
          assert_receive {:DOWN, ^monitor, :process, ^watcher, :normal}, 2_000
        end)

      assert log =~ "Started runner pod"
      assert_receive {:secret_created, %{"stringData" => %{"spec.json" => spec_json}}}
      assert Jason.decode!(spec_json)["controller_url"] == "http://symphony.symphony.svc:4000"
      assert_receive {:config_map_created, %{"data" => %{"symphony.yml" => "workspace:\n  root: /workspace\n"}}}
      assert_receive {:pod_created, pod}
      assert Enum.at(hd(pod["spec"]["containers"])["args"], 2) == "/etc/symphony/symphony.yml"

      owner = %{"metadata" => %{"ownerReferences" => [%{"apiVersion" => "v1", "kind" => "Pod", "name" => name, "uid" => "pod-uid-1"}]}}
      assert_receive {:patched, ^secret_path, ^owner}
      assert_receive {:patched, ^config_map_path, ^owner}
    end

    test "RunLauncher.start hands the Kubernetes launcher the run spec", ctx do
      respond = fn
        "POST", @pods, _body, conn -> Req.Test.json(conn, %{"metadata" => %{"uid" => "uid"}})
        _method, _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Pending"}})
      end

      capture_log(fn ->
        assert {:ok, watcher, ref} = RunLauncher.start(Kubernetes, %{fun: fn -> :ok end, spec: ctx.spec}, opts(ctx, respond))
        assert ref == ctx.ref
        RunWatcher.stop(watcher)
      end)
    end

    test "start/2 takes a spec or a request carrying one, and rejects a bare function", ctx do
      respond = fn
        "POST", @pods, _body, conn -> Req.Test.json(conn, %{"metadata" => %{"uid" => "uid"}})
        _method, _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Running"}})
      end

      capture_log(fn ->
        assert {:ok, watcher, _ref} = Kubernetes.start(ctx.spec, opts(ctx, respond))
        RunWatcher.stop(watcher)
        assert {:ok, watcher, _ref} = Kubernetes.start(%{spec: ctx.spec}, opts(ctx, respond))
        RunWatcher.stop(watcher)
      end)

      assert {:error, :missing_run_spec} = Kubernetes.start(fn -> :ok end, [])
      assert {:error, :missing_run_spec} = Kubernetes.start(:nope, [])
    end

    test "invalid settings and missing credentials are errors", ctx do
      capture_log(fn ->
        assert {:error, {:invalid_settings, :nope}} = Kubernetes.start_process(ctx.spec, settings: :nope)
        # The loaded config configures no runner images.
        assert {:error, {:invalid_kubernetes_config, _message}} = Kubernetes.start_process(ctx.spec)

        assert {:error, _reason} =
                 Kubernetes.start_process(ctx.spec, settings: settings(), config_path: ctx.config_path)
      end)
    end

    test "an unreadable runner config is an error before anything is created", ctx do
      missing = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.yml")
      respond = fn _method, _path, _body, _conn -> flunk("no API call expected") end

      capture_log(fn ->
        assert {:error, {:runner_config, ^missing, :enoent}} =
                 Kubernetes.start_process(ctx.spec, Keyword.put(opts(ctx, respond), :config_path, missing))
      end)
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
        assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, base_opts)
        RunWatcher.stop(watcher)
      end)

      assert_receive {:config_map, %{"WORKFLOW.md" => "---\n---\nPrompt"}}

      Application.put_env(:symphony_elixir, :startup_mode, :global)
      Application.put_env(:symphony_elixir, :symphony_config_path, global)

      capture_log(fn ->
        assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, base_opts)
        RunWatcher.stop(watcher)
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
        assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
        RunWatcher.stop(watcher)
      end)

      %{secret: secret, config_map: config_map} = ctx
      assert_receive {:deleted, ^secret}
      assert_receive {:recreated, @secrets}
      assert_receive {:deleted, ^config_map}
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
        assert {:error, {:http_error, 403, "forbidden"}} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
      end)

      secret = ctx.secret
      assert_receive {:deleted, ^secret}
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

      capture_log(fn ->
        assert {:error, {:http_error, 422, "invalid"}} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
      end)

      %{secret: secret, config_map: config_map} = ctx
      assert_receive {:deleted, ^secret}
      assert_receive {:deleted, ^config_map}
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

      capture_log(fn ->
        assert {:error, {:http_error, 422, "rejected"}} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
      end)

      %{secret: secret, config_map: config_map, pod: pod} = ctx
      assert_receive {:deleted, ^secret}
      assert_receive {:deleted, ^config_map}
      refute_received {:deleted, ^pod}
    end

    test "a Pod create timeout reads the pod back and continues when it exists", ctx do
      parent = self()
      pod_path = ctx.pod

      respond = fn
        "POST", @pods, _body, conn ->
          Req.Test.transport_error(conn, :timeout)

        "POST", _path, _body, conn ->
          Req.Test.json(conn, %{})

        "GET", ^pod_path, _body, conn ->
          Req.Test.json(conn, %{"metadata" => %{"uid" => "uid-2"}, "status" => %{"phase" => "Pending"}})

        "PATCH", path, _body, conn ->
          send(parent, {:patched, path})
          Req.Test.json(conn, %{})
      end

      log =
        capture_log(fn ->
          assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
          %{secret: secret, config_map: config_map} = ctx
          assert_receive {:patched, ^secret}
          assert_receive {:patched, ^config_map}
          RunWatcher.stop(watcher)
        end)

      assert log =~ "the pod exists"
    end

    test "a Pod create timeout cleans up when the pod does not exist", ctx do
      parent = self()
      pod_path = ctx.pod

      respond = fn
        "POST", @pods, _body, conn ->
          Req.Test.transport_error(conn, :timeout)

        "POST", _path, _body, conn ->
          Req.Test.json(conn, %{})

        "GET", ^pod_path, _body, conn ->
          Plug.Conn.send_resp(conn, 404, "")

        "DELETE", path, _body, conn ->
          send(parent, {:deleted, path})
          Req.Test.json(conn, %{})
      end

      capture_log(fn ->
        assert {:error, %Req.TransportError{reason: :timeout}} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
      end)

      %{secret: secret, config_map: config_map, pod: pod} = ctx
      assert_receive {:deleted, ^secret}
      assert_receive {:deleted, ^config_map}
      refute_received {:deleted, ^pod}
    end

    test "a Pod create timeout with an unreadable pod removes the pod and its objects", ctx do
      parent = self()
      pod_path = ctx.pod

      respond = fn
        "POST", @pods, _body, conn ->
          Req.Test.transport_error(conn, :timeout)

        "POST", _path, _body, conn ->
          Req.Test.json(conn, %{})

        "GET", ^pod_path, _body, conn ->
          Req.Test.transport_error(conn, :econnrefused)

        "DELETE", path, _body, conn ->
          send(parent, {:deleted, path})
          Req.Test.json(conn, %{})
      end

      capture_log(fn ->
        assert {:error, %Req.TransportError{reason: :timeout}} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
      end)

      %{secret: secret, config_map: config_map, pod: pod} = ctx
      assert_receive {:deleted, ^pod}
      assert_receive {:deleted, ^secret}
      assert_receive {:deleted, ^config_map}
    end

    test "a failed ownerReference patch is logged and the run continues", ctx do
      respond = fn
        "POST", @pods, _body, conn -> Req.Test.json(conn, %{"metadata" => %{"uid" => "uid"}})
        "POST", _path, _body, conn -> Req.Test.json(conn, %{})
        "PATCH", _path, _body, conn -> Plug.Conn.send_resp(conn, 403, "forbidden")
        "GET", _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Running"}})
      end

      log =
        capture_log(fn ->
          assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
          RunWatcher.stop(watcher)
        end)

      assert log =~ "Runner secret ownerReference failed"
      assert log =~ "Runner config_map ownerReference failed"
    end

    test "a pod without a uid gets no ownerReference", ctx do
      respond = fn _method, _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Running"}}) end

      log =
        capture_log(fn ->
          # A spec without an issue still gets its watcher.
          assert {:ok, watcher, _ref} = Kubernetes.start_process(%{ctx.spec | issue: nil}, opts(ctx, respond))
          RunWatcher.stop(watcher)
        end)

      assert log =~ "Runner pod has no uid"
    end

    test "a watcher that cannot start removes the pod and its objects", ctx do
      parent = self()
      # Another watcher already holds the run.
      {:ok, existing} = RunWatcher.start(%{run_id: ctx.run_id}, "fake:held", launcher: __MODULE__, poll_interval_ms: 60_000)

      respond = fn
        "POST", @pods, _body, conn ->
          Req.Test.json(conn, %{"metadata" => %{"uid" => "uid"}})

        "DELETE", path, _body, conn ->
          send(parent, {:deleted, path})
          Req.Test.json(conn, %{})

        _method, _path, _body, conn ->
          Req.Test.json(conn, %{})
      end

      capture_log(fn ->
        assert {:error, {:watcher_failed, {:already_watched, ^existing}}} =
                 Kubernetes.start_process(ctx.spec, opts(ctx, respond))
      end)

      %{secret: secret, config_map: config_map, pod: pod} = ctx
      assert_receive {:deleted, ^pod}
      assert_receive {:deleted, ^secret}
      assert_receive {:deleted, ^config_map}
      RunWatcher.stop(existing)
    end
  end

  describe "launch metrics" do
    test "a started launch and a failed one are counted, the failure by a bounded reason", ctx do
      Metrics.reset()

      started = fn
        "POST", @pods, _body, conn -> Req.Test.json(conn, %{"metadata" => %{"uid" => "uid"}})
        _method, _path, _body, conn -> Req.Test.json(conn, %{"status" => %{"phase" => "Pending"}})
      end

      rejected = fn
        "POST", @pods, _body, conn -> Plug.Conn.send_resp(conn, 422, "rejected")
        _method, _path, _body, conn -> Req.Test.json(conn, %{})
      end

      capture_log(fn ->
        assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, opts(ctx, started))
        RunWatcher.stop(watcher)
        assert {:error, _reason} = Kubernetes.start_process(ctx.spec, opts(ctx, rejected))
      end)

      counters =
        for %{name: name, labels: labels, value: value} <- Metrics.snapshot().counters,
            into: %{},
            do: {{name, labels}, value}

      assert counters[{"symphony_runner_launches_total", [{"outcome", "started"}]}] == 1
      assert counters[{"symphony_runner_launches_total", [{"outcome", "failed"}]}] == 1
      assert counters[{"symphony_runner_launch_failures_total", [{"reason", "http_422"}]}] == 1
    end

    test "failure reasons never carry free text" do
      assert Kubernetes.launch_failure_reason({:invalid_settings, :x}) == "settings"
      assert Kubernetes.launch_failure_reason({:runner_config, "/p", :enoent}) == "runner_config"
      assert Kubernetes.launch_failure_reason({:watcher_failed, :x}) == "watcher"
      assert Kubernetes.launch_failure_reason({:http_error, 403, "no"}) == "http_403"
      assert Kubernetes.launch_failure_reason(:not_in_cluster) == "kube_client"
      assert Kubernetes.launch_failure_reason({:in_cluster_config, :enoent}) == "kube_client"
      assert Kubernetes.launch_failure_reason(%Req.TransportError{reason: :timeout}) == "transport"
      assert Kubernetes.launch_failure_reason(:missing_controller_url) == "render"
      assert Kubernetes.launch_failure_reason({:invalid_kubernetes_config, "message"}) == "render"
      assert Kubernetes.launch_failure_reason("free text") == "other"
    end
  end

  describe "the run's watcher" do
    test "keeps watching a pending pod and exits :runner_lost when it ends without a finished event", ctx do
      respond = sequence_responder([pending(), pending(), phase_body("Succeeded")])

      capture_log(fn ->
        assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
        assert_down(watcher, :runner_lost)
      end)
    end

    test "exits with the pod's own failure reason", ctx do
      respond = sequence_responder([%{"status" => %{"phase" => "Failed", "reason" => "DeadlineExceeded"}}])

      capture_log(fn ->
        assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
        assert_down(watcher, {:pod_failed, "DeadlineExceeded"})
      end)
    end

    test "a finished event during the grace period wins over the pod's failure", ctx do
      respond = sequence_responder([%{"status" => %{"phase" => "Failed", "reason" => "Error"}}])

      capture_log(fn ->
        assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, Keyword.put(opts(ctx, respond), :lost_grace_ms, 10_000))
        Process.sleep(50)
        RunWatcher.finished(ctx.run_id, "normal")
        assert_down(watcher, :normal)
      end)
    end

    test "exits :runner_lost when the pod disappears", ctx do
      respond = fn
        "POST", _path, _body, conn -> Req.Test.json(conn, %{})
        "PATCH", _path, _body, conn -> Req.Test.json(conn, %{})
        "GET", _path, _body, conn -> Plug.Conn.send_resp(conn, 404, "")
      end

      capture_log(fn ->
        assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
        assert_down(watcher, :runner_lost)
      end)
    end

    test "retries a transient API error and a short burst of 401/403", ctx do
      respond = sequence_responder([{500, "not yet"}, {401, "expired"}, {403, "forbidden"}, pending(), {401, "expired"}, phase_body("Failed")])

      log =
        capture_log(fn ->
          assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, opts(ctx, respond))
          assert_down(watcher, {:pod_failed, "failed"})
        end)

      assert log =~ "Run watcher could not check"
      assert log =~ "Run watcher check unauthorized"
    end

    test "exits once a 401/403 persists past the timeout", ctx do
      respond = sequence_responder([{401, "expired"}, {403, "forbidden"}])

      log =
        capture_log(fn ->
          assert {:ok, watcher, _ref} = Kubernetes.start_process(ctx.spec, Keyword.put(opts(ctx, respond), :unauthorized_timeout_ms, 5))
          assert_down(watcher, {:pod_monitor_unauthorized, {:http_error, 403, "forbidden"}})
        end)

      assert log =~ "unauthorized for too long"
    end
  end

  describe "status/1 and alive?/1" do
    test "a pending or running pod is alive", ctx do
      for phase <- ["Pending", "Running"] do
        put_kube_options(phase_responder(phase))
        assert Kubernetes.status(ctx.ref) == :alive
        assert Kubernetes.alive?(ctx.ref)
      end
    end

    test "a succeeded or missing pod is gone, and a failed one says why", ctx do
      put_kube_options(phase_responder("Succeeded"))
      assert Kubernetes.status(ctx.ref) == {:gone, nil}
      refute Kubernetes.alive?(ctx.ref)

      put_kube_options(fn _method, _path, _body, conn -> Plug.Conn.send_resp(conn, 404, "") end)
      assert Kubernetes.status(ctx.ref) == {:gone, nil}

      statuses = [
        %{"name" => "agent-tools", "state" => %{"terminated" => %{"reason" => "Completed", "exitCode" => 0}}},
        %{"name" => "runner", "state" => %{"terminated" => %{"reason" => "OOMKilled", "exitCode" => 137}}}
      ]

      put_kube_options(body_responder(%{"status" => %{"phase" => "Failed", "containerStatuses" => statuses}}))
      assert Kubernetes.status(ctx.ref) == {:gone, {:pod_failed, "OOMKilled (exit code 137)"}}

      for {terminated, expected} <- [
            {%{"exitCode" => 2}, "failed (exit code 2)"},
            {%{"reason" => "Error"}, "Error"},
            {%{"reason" => ""}, "failed"}
          ] do
        statuses = ["not-a-map", %{"name" => "runner", "state" => %{"terminated" => terminated}}]
        put_kube_options(body_responder(%{"status" => %{"phase" => "Failed", "containerStatuses" => statuses}}))
        assert Kubernetes.status(ctx.ref) == {:gone, {:pod_failed, expected}}
      end

      for status <- [
            %{"phase" => "Failed"},
            %{"phase" => "Failed", "containerStatuses" => [%{"name" => "runner", "state" => %{"running" => %{}}}]}
          ] do
        put_kube_options(body_responder(%{"status" => status}))
        assert Kubernetes.status(ctx.ref) == {:gone, {:pod_failed, "failed"}}
      end
    end

    test "an unknown phase or an API error is unknown, and a refusal is unauthorized", ctx do
      put_kube_options(phase_responder("Unknown"))
      assert Kubernetes.status(ctx.ref) == {:unknown, {:pod_phase, "Unknown"}}
      refute Kubernetes.alive?(ctx.ref)

      put_kube_options(body_responder(%{}))
      assert Kubernetes.status(ctx.ref) == {:unknown, {:pod_phase, nil}}

      put_kube_options(fn _method, _path, _body, conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
      assert {:unknown, {:http_error, 500, "boom"}} = Kubernetes.status(ctx.ref)

      put_kube_options(fn _method, _path, _body, conn -> Plug.Conn.send_resp(conn, 403, "no") end)
      assert {:unauthorized, {:http_error, 403, "no"}} = Kubernetes.status(ctx.ref)
    end

    test "a bad reference is gone and missing credentials are unauthorized", ctx do
      assert {:unauthorized, :not_in_cluster} = Kubernetes.status(ctx.ref)
      refute Kubernetes.alive?(ctx.ref)

      for ref <- ["local:not-a-pod", "k8s:namespace-only", "k8s:/missing-namespace", nil] do
        assert Kubernetes.status(ref) == {:gone, nil}
        refute Kubernetes.alive?(ref)
      end
    end

    test "RunLauncher.status/2 uses it", ctx do
      put_kube_options(phase_responder("Running"))
      assert RunLauncher.status(Kubernetes, ctx.ref) == :alive
    end
  end

  describe "stop/1 and release/1" do
    test "stop deletes a live pod with its Secret and ConfigMap", ctx do
      parent = self()

      put_kube_options(fn
        "GET", _path, _body, conn ->
          Req.Test.json(conn, %{"status" => %{"phase" => "Running"}})

        method, path, _body, conn ->
          send(parent, {method, path})
          Plug.Conn.send_resp(conn, 404, "")
      end)

      assert :ok = Kubernetes.stop(ctx.ref)
      %{pod: pod, secret: secret, config_map: config_map} = ctx
      assert_receive {"DELETE", ^pod}
      assert_receive {"DELETE", ^secret}
      assert_receive {"DELETE", ^config_map}
    end

    test "stop deletes a pod it cannot read", ctx do
      parent = self()

      put_kube_options(fn
        "GET", _path, _body, conn ->
          Plug.Conn.send_resp(conn, 500, "boom")

        method, path, _body, conn ->
          send(parent, {method, path})
          Req.Test.json(conn, %{})
      end)

      assert :ok = Kubernetes.stop(ctx.ref)
      pod = ctx.pod
      assert_receive {"DELETE", ^pod}
    end

    test "stop keeps a finished pod for its logs", ctx do
      parent = self()

      put_kube_options(fn
        "GET", _path, _body, conn ->
          Req.Test.json(conn, %{"status" => %{"phase" => "Failed"}})

        method, path, _body, conn ->
          send(parent, {method, path})
          Req.Test.json(conn, %{})
      end)

      assert :ok = Kubernetes.stop(ctx.ref)
      %{pod: pod, secret: secret, config_map: config_map} = ctx
      assert_receive {"DELETE", ^secret}
      assert_receive {"DELETE", ^config_map}
      refute_received {"DELETE", ^pod}
    end

    test "release deletes only the Secret and ConfigMap and logs a failed delete", ctx do
      parent = self()

      put_kube_options(fn method, path, _body, conn ->
        send(parent, {method, path})
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      log = capture_log(fn -> assert :ok = Kubernetes.release(ctx.ref) end)

      %{pod: pod, secret: secret, config_map: config_map} = ctx
      assert_receive {"DELETE", ^secret}
      assert_receive {"DELETE", ^config_map}
      refute_received {_method, ^pod}
      assert log =~ "Runner secret cleanup failed"
      assert log =~ "Runner config_map cleanup failed"

      assert :ok = RunLauncher.release(Kubernetes, ctx.ref)
      assert_receive {"DELETE", ^secret}
    end

    test "bad references and missing credentials are no-ops", ctx do
      assert :ok = Kubernetes.stop(ctx.ref)
      assert :ok = Kubernetes.release(ctx.ref)

      put_kube_options(fn _method, _path, _body, _conn -> flunk("no API call expected") end)

      for ref <- ["k8s:bad", nil] do
        assert :ok = Kubernetes.stop(ref)
        assert :ok = Kubernetes.release(ref)
      end
    end
  end

  test "the controller URL runner pods use comes from agent.kubernetes.controller_url" do
    assert Kubernetes.controller_url(settings()) == "http://symphony.symphony.svc:4000"
    assert RunLauncher.controller_url(Kubernetes, settings()) == "http://symphony.symphony.svc:4000"
    assert RunLauncher.controller_url(SymphonyElixir.RunLauncher.Process, settings()) == RunSpec.controller_url()
  end

  test "runner pods export to agent.kubernetes.otlp_endpoint when it is set" do
    assert Kubernetes.otlp_override(settings()) == nil
    assert RunLauncher.otlp_override(Kubernetes, settings()) == nil
    assert RunLauncher.otlp_override(SymphonyElixir.RunLauncher.Process, settings()) == nil
    assert RunLauncher.otlp_override(SymphonyElixir.RunLauncher.Local, settings()) == nil

    assert {:ok, with_collector} =
             Schema.parse(%{
               "agent" => %{"kubernetes" => %{"otlp_endpoint" => "http://otel-collector.symphony.svc:4317", "otlp_protocol" => "grpc"}}
             })

    assert RunLauncher.otlp_override(Kubernetes, with_collector) == %{endpoint: "http://otel-collector.symphony.svc:4317", protocol: "grpc"}
  end

  # The fake launcher of the "held" watcher above: it is never polled.
  @doc false
  def alive?(_ref), do: true

  defp opts(ctx, respond) do
    [
      settings: settings(),
      config_path: ctx.config_path,
      base_url: "https://kube.test",
      poll_interval_ms: 10,
      lost_grace_ms: 20,
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
    assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}, 3_000
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

  defp phase_responder(phase), do: body_responder(phase_body(phase))

  defp body_responder(body) do
    fn _method, _path, _body, conn -> Req.Test.json(conn, body) end
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
                   "agent_tools_image" => "registry.test/tools:test",
                   "controller_url" => "http://symphony.symphony.svc:4000"
                 }
               }
             })

    settings
  end

  defp spec(run_id) do
    %RunSpec{
      run_id: run_id,
      epoch: 1,
      attempt: 1,
      issue: %{id: "issue-1", identifier: "MT-1"},
      controller_url: "http://symphony.symphony.svc:4000",
      token: "run-token"
    }
  end
end
