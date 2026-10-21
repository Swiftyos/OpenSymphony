defmodule SymphonyElixir.RunLauncher.Kubernetes.PodWatchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Capacity.Metrics
  alias SymphonyElixir.RunLauncher.Kubernetes
  alias SymphonyElixir.RunLauncher.Kubernetes.PodWatch

  @pods "/api/v1/namespaces/runs/pods"

  setup do
    Metrics.reset()
    on_exit(&Metrics.reset/0)
    %{table: :"pod_watch_test_#{System.unique_integer([:positive])}"}
  end

  # Each request to the pods collection gets the next response in `script`:
  # `{:list, body}`, `{:watch, events}` (a stream that ends), `{:status,
  # status, body}`, `:crash` or `:block` (a watch that stays open). The last
  # entry repeats.
  defp start_watch!(ctx, script, opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> script end)
    parent = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      kind = if conn.query_params["watch"] == "1", do: :watch, else: :list
      send(parent, {:request, kind, conn.request_path, conn.query_params})
      respond(conn, Agent.get_and_update(agent, &next/1))
    end

    opts =
      Keyword.merge(
        [
          name: nil,
          table: ctx.table,
          enabled: true,
          namespace: "runs",
          base_url: "https://kube.test",
          req_options: [retry: false, plug: plug],
          min_backoff_ms: 10,
          gauge_interval_ms: 10,
          check_interval_ms: 60_000
        ],
        opts
      )

    start_supervised!({PodWatch, opts}, id: ctx.table)
  end

  defp next([last]), do: {last, [last]}
  defp next([item | rest]), do: {item, rest}

  defp respond(conn, {:list, body}), do: Req.Test.json(conn, body)
  defp respond(conn, {:watch, events}), do: Plug.Conn.send_resp(conn, 200, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
  defp respond(conn, {:status, status, body}), do: Plug.Conn.send_resp(conn, status, body)
  defp respond(conn, {:raw, body}), do: Plug.Conn.send_resp(conn, 200, body)
  defp respond(conn, {:transport, reason}), do: Req.Test.transport_error(conn, reason)
  defp respond(_conn, :crash), do: raise("watch crashed")

  defp respond(conn, :block) do
    receive do
      :never -> conn
    after
      30_000 -> Plug.Conn.send_resp(conn, 200, "")
    end
  end

  defp pod(name, phase, extra \\ %{}) do
    %{
      "metadata" => %{"name" => name, "resourceVersion" => "1", "creationTimestamp" => "2026-10-21T10:00:00Z", "labels" => %{"big" => "dropped"}},
      "spec" => %{"containers" => [%{"name" => "runner"}]},
      "status" => %{"phase" => phase}
    }
    |> deep_merge(extra)
  end

  defp deep_merge(left, right), do: Map.merge(left, right, fn _key, l, r -> if is_map(l) and is_map(r), do: deep_merge(l, r), else: r end)

  defp list(pods, version), do: {:list, %{"metadata" => %{"resourceVersion" => version}, "items" => pods}}

  defp event(type, pod, version), do: %{"type" => type, "object" => put_in(pod, ["metadata", "resourceVersion"], version)}

  defp running(name) do
    pod(name, "Running", %{
      "status" => %{"containerStatuses" => [%{"name" => "runner", "state" => %{"running" => %{"startedAt" => "2026-10-21T10:00:42Z"}}}]}
    })
  end

  defp eventually(fun, attempts \\ 200) do
    case fun.() do
      truthy when truthy not in [nil, false] ->
        truthy

      _falsy when attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      falsy ->
        flunk("condition never held: #{inspect(falsy)}")
    end
  end

  defp counter(name, labels) do
    labels = Enum.map(labels, fn {key, value} -> {to_string(key), value} end) |> Enum.sort()
    Enum.find_value(Metrics.snapshot().counters, 0, &(&1.name == name and &1.labels == labels and &1.value))
  end

  defp gauge(name, labels) do
    labels = Enum.map(labels, fn {key, value} -> {to_string(key), value} end) |> Enum.sort()
    Enum.find_value(Metrics.snapshot().gauges, &(&1.name == name and &1.labels == labels and &1.value))
  end

  defp histogram_count(name) do
    Enum.find_value(Metrics.snapshot().histograms, 0, &(&1.name == name and &1.count))
  end

  test "lists, watches from the list's version, applies events and rewatches from the last version", ctx do
    gated = pod("c", "Pending", %{"spec" => %{"schedulingGates" => [%{"name" => "kueue.x-k8s.io/admission"}]}})

    start_watch!(ctx, [
      list([pod("a", "Pending"), pod("b", "Running"), pod("gone", "Pending")], "10"),
      {:watch,
       [
         event("MODIFIED", running("a"), "11"),
         event("ADDED", gated, "12"),
         event("DELETED", pod("gone", "Pending"), "13"),
         %{"type" => "BOOKMARK", "object" => %{"metadata" => %{"resourceVersion" => "20"}}}
       ]},
      :block
    ])

    assert_receive {:request, :list, @pods, %{"labelSelector" => "app.kubernetes.io/name=symphony-runner"}}
    assert_receive {:request, :watch, @pods, %{"resourceVersion" => "10", "allowWatchBookmarks" => "true"}}
    # The bookmark moved the version on, so the next watch starts after it.
    assert_receive {:request, :watch, @pods, %{"resourceVersion" => "20"}}, 2_000

    assert {:ok, %{"status" => %{"phase" => "Running"}} = cached} = PodWatch.lookup("runs", "a", ctx.table)
    # Only what the watchers and metrics need is kept.
    assert cached["metadata"] |> Map.keys() |> Enum.sort() == ["creationTimestamp", "name", "resourceVersion"]
    assert cached["spec"] == %{}
    assert {:ok, _pod} = PodWatch.lookup("runs", "c", ctx.table)
    assert :miss = PodWatch.lookup("runs", "gone", ctx.table)
    assert :stale = PodWatch.lookup("other-namespace", "a", ctx.table)
    assert PodWatch.synced?("runs", ctx.table)

    # a went Pending -> Running 42s after it was created.
    assert histogram_count("symphony_runner_pod_start_seconds") == 1
    assert [%{sum: 42.0}] = Enum.filter(Metrics.snapshot().histograms, &(&1.name == "symphony_runner_pod_start_seconds"))
    assert counter("symphony_runner_pod_watch_reconnects_total", reason: "closed") == 1

    eventually(fn -> gauge("symphony_runner_pods", phase: "running") == 2 end)
    assert gauge("symphony_runner_pods", phase: "pending") == 1
    assert gauge("symphony_runner_pods", phase: "failed") == 0
    assert gauge("symphony_runner_pods_waiting", reason: "scheduling_gated") == 1
    assert gauge("symphony_runner_pods_waiting", reason: "unschedulable") == 0
    assert gauge("symphony_runner_pod_watch_synced", []) == 1
  end

  test "a 410 Gone relists and replaces the cache; a Failed transition is counted by reason", ctx do
    oom =
      pod("a", "Failed", %{
        "status" => %{"containerStatuses" => [%{"name" => "runner", "state" => %{"terminated" => %{"reason" => "OOMKilled", "exitCode" => 137}}}]}
      })

    start_watch!(ctx, [
      list([pod("a", "Running"), pod("b", "Running")], "10"),
      {:watch, [%{"type" => "ERROR", "object" => %{"code" => 410}}]},
      list([oom], "30"),
      :block
    ])

    assert_receive {:request, :watch, @pods, %{"resourceVersion" => "10"}}
    assert_receive {:request, :list, @pods, _params}, 2_000
    assert_receive {:request, :watch, @pods, %{"resourceVersion" => "30"}}, 2_000

    assert :miss = PodWatch.lookup("runs", "b", ctx.table)
    assert {:ok, %{"status" => %{"phase" => "Failed"}}} = PodWatch.lookup("runs", "a", ctx.table)
    assert counter("symphony_runner_pod_watch_reconnects_total", reason: "gone") == 1
    assert counter("symphony_runner_pod_failures_total", reason: "OOMKilled") == 1
  end

  test "watch errors back off and rewatch; a cache failing past stale_after_ms is stale until an event arrives", ctx do
    log =
      capture_log(fn ->
        start_watch!(
          ctx,
          [
            list([pod("a", "Running")], "10"),
            {:status, 500, "boom"},
            {:status, 500, "boom"},
            {:watch, [event("MODIFIED", pod("a", "Running"), "11")]},
            :block
          ],
          stale_after_ms: 0
        )

        assert_receive {:request, :watch, _path, %{"resourceVersion" => "10"}}
        assert_receive {:request, :watch, _path, %{"resourceVersion" => "10"}}, 2_000
        assert_receive {:request, :watch, _path, %{"resourceVersion" => "10"}}, 2_000
        assert_receive {:request, :watch, _path, %{"resourceVersion" => "11"}}, 2_000
      end)

    assert log =~ "Runner pod watch failed"
    assert counter("symphony_runner_pod_watch_reconnects_total", reason: "http_500") == 2
    # The MODIFIED event proved the watch healthy again.
    assert {:ok, _pod} = PodWatch.lookup("runs", "a", ctx.table)
  end

  test "while the watch keeps failing a synced cache goes stale", ctx do
    capture_log(fn ->
      start_watch!(ctx, [list([pod("a", "Running")], "10"), {:status, 403, "forbidden"}], stale_after_ms: 0, min_backoff_ms: 5_000)
      assert_receive {:request, :watch, _path, _params}
      eventually(fn -> PodWatch.lookup("runs", "a", ctx.table) == :stale end)
    end)

    assert counter("symphony_runner_pod_watch_reconnects_total", reason: "http_403") == 1
    eventually(fn -> gauge("symphony_runner_pod_watch_synced", []) == 0 end)
  end

  test "a failed list is retried; a crashed watch task is a reconnect", ctx do
    capture_log(fn ->
      start_watch!(ctx, [{:status, 500, "no"}, list([], "5"), :crash, :block])
      assert_receive {:request, :list, _path, _params}
      assert :stale = PodWatch.lookup("runs", "a", ctx.table)
      assert_receive {:request, :list, _path, _params}, 2_000
      assert_receive {:request, :watch, _path, %{"resourceVersion" => "5"}}, 2_000
      assert_receive {:request, :watch, _path, %{"resourceVersion" => "5"}}, 2_000
    end)

    assert counter("symphony_runner_pod_watch_reconnects_total", reason: "list_http_500") == 1
    assert counter("symphony_runner_pod_watch_reconnects_total", reason: "crashed") == 1
  end

  test "turning the launcher away from Kubernetes stops the watch and clears the cache", ctx do
    {:ok, enabled} = Agent.start_link(fn -> true end)
    pid = start_watch!(ctx, [list([pod("a", "Running")], "10"), :block, list([pod("a", "Running")], "40"), :block], enabled: fn -> Agent.get(enabled, & &1) end)

    assert_receive {:request, :watch, _path, _params}
    assert {:ok, _pod} = PodWatch.lookup("runs", "a", ctx.table)

    Agent.update(enabled, fn _ -> false end)
    send(pid, :check)
    eventually(fn -> PodWatch.lookup("runs", "a", ctx.table) == :stale end)
    assert gauge("symphony_runner_pod_watch_synced", []) == 0
    assert gauge("symphony_runner_pods", phase: "running") == nil

    # Stray messages for an inactive or replaced watch are ignored.
    send(pid, :relist)
    send(pid, {:pod_events, make_ref(), [event("ADDED", pod("x", "Running"), "1")]})
    send(pid, :unexpected)
    assert :stale = PodWatch.lookup("runs", "x", ctx.table)

    Agent.update(enabled, fn _ -> true end)
    send(pid, :check)
    assert_receive {:request, :list, _path, _params}
    eventually(fn -> match?({:ok, _pod}, PodWatch.lookup("runs", "a", ctx.table)) end)
  end

  test "a watch that cannot get a client or a namespace stays idle", ctx do
    log =
      capture_log(fn ->
        start_watch!(ctx, [list([], "1")], base_url: nil, env: %{}, service_account_dir: "/nonexistent")
        Process.sleep(30)
      end)

    assert log =~ "Runner pod watch could not start"
    refute_received {:request, _kind, _path, _params}
    assert :stale = PodWatch.lookup("runs", "a", ctx.table)
  end

  test "every way a watch or list fails is a bounded reconnect reason", ctx do
    capture_log(fn ->
      start_watch!(ctx, [
        list([], "1"),
        {:status, 404, ""},
        {:transport, :econnrefused},
        {:raw, "not json\n"},
        {:watch, [%{"type" => "ERROR", "object" => %{"code" => 500}}]},
        {:watch, [%{"type" => "ERROR", "object" => %{"code" => 410}}]},
        {:status, 410, "expired"},
        list([], "2"),
        :block
      ])

      assert_receive {:request, :watch, _path, %{"resourceVersion" => "2"}}, 3_000
    end)

    for reason <- ["not_found", "transport", "invalid_event", "watch_error", "gone", "list_gone"] do
      assert counter("symphony_runner_pod_watch_reconnects_total", reason: reason) == 1, reason
    end
  end

  test "odd events are ignored and odd pods still count", ctx do
    pending = pod("a", "Pending", %{"metadata" => %{"creationTimestamp" => "2026-10-21T10:00:00Z"}})

    started =
      pod("a", "Running", %{
        "status" => %{"startTime" => "2026-10-21T10:00:05Z", "containerStatuses" => [%{"name" => "agent-tools", "state" => %{"terminated" => %{}}}]}
      })

    bad_time = pod("b", "Pending", %{"metadata" => %{"creationTimestamp" => "not a time"}})

    start_watch!(ctx, [
      list([pending, bad_time, %{"metadata" => %{"name" => "phaseless"}}, %{"metadata" => %{}}, %{"metadata" => %{"name" => "c"}, "status" => %{"phase" => "Pending"}}], "1"),
      {:watch,
       [
         %{"type" => "ADDED", "object" => %{"metadata" => %{}}},
         %{"type" => "DELETED", "object" => %{"metadata" => %{}}},
         %{"type" => "BOOKMARK", "object" => %{"metadata" => %{}}},
         %{"type" => "SOMETHING", "object" => %{}},
         # The runner container has not reported yet: the pod's start time counts.
         event("MODIFIED", started, "5"),
         # Unparseable times record nothing.
         event("MODIFIED", pod("b", "Running", %{"metadata" => %{"creationTimestamp" => "not a time"}}), "6"),
         %{"type" => "MODIFIED", "object" => %{"metadata" => %{"name" => "c", "resourceVersion" => "7"}, "status" => %{"phase" => "Running"}}}
       ]},
      :block
    ])

    assert_receive {:request, :watch, _path, %{"resourceVersion" => "7"}}, 2_000
    assert [%{count: 1, sum: 5.0}] = Enum.filter(Metrics.snapshot().histograms, &(&1.name == "symphony_runner_pod_start_seconds"))
    eventually(fn -> gauge("symphony_runner_pods", phase: "running") == 3 end)
    assert gauge("symphony_runner_pods", phase: "unknown") == 1
  end

  test "the namespace comes from the config; stopping mid-backoff cancels the retry", ctx do
    {:ok, enabled} = Agent.start_link(fn -> true end)

    capture_log(fn ->
      pid =
        start_watch!(ctx, [{:status, 500, "no"}],
          namespace: nil,
          min_backoff_ms: 60_000,
          enabled: fn -> Agent.get(enabled, & &1) end
        )

      assert_receive {:request, :list, "/api/v1/namespaces/" <> _configured, _params}
      Agent.update(enabled, fn _ -> false end)
      send(pid, :check)
      eventually(fn -> gauge("symphony_runner_pod_watch_synced", []) == 0 end)
    end)
  end

  test "without an explicit switch it follows the launcher, and stays off in tests", ctx do
    previous = Application.get_env(:symphony_elixir, :run_launcher)
    Application.put_env(:symphony_elixir, :run_launcher, Kubernetes)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :run_launcher)
        launcher -> Application.put_env(:symphony_elixir, :run_launcher, launcher)
      end
    end)

    plug = fn _conn -> flunk("the pod watch is off in tests") end
    pid = start_supervised!({PodWatch, name: nil, table: ctx.table, namespace: "runs", base_url: "https://kube.test", req_options: [plug: plug]})
    send(pid, :check)
    :sys.get_state(pid)
    assert :stale = PodWatch.lookup("runs", "a", ctx.table)
  end

  test "a list that raises is a failed list, not a crash", ctx do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    plug = fn conn ->
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 -> raise "plug exploded"
        _later -> respond(conn, :block)
      end
    end

    log =
      capture_log(fn ->
        pid =
          start_supervised!({PodWatch, name: nil, table: ctx.table, enabled: true, namespace: "runs", min_backoff_ms: 60_000, base_url: "https://kube.test", req_options: [retry: false, plug: plug]})

        :sys.get_state(pid)
        assert Process.alive?(pid)
      end)

    assert log =~ "Runner pod list failed"
    assert counter("symphony_runner_pod_watch_reconnects_total", reason: "list_transport") == 1
  end

  test "the default table and name are the application's" do
    assert PodWatch.lookup("runs", "a") in [:stale, :miss] or match?({:ok, _pod}, PodWatch.lookup("runs", "a"))
    assert is_boolean(PodWatch.synced?("runs"))
    assert {:error, {:already_started, _pid}} = PodWatch.start_link()
  end

  test "lookups before any watch has started are stale" do
    assert :stale = PodWatch.lookup("runs", "a", :pod_watch_test_missing_table)
    refute PodWatch.synced?("runs", :pod_watch_test_missing_table)
    assert PodWatch.table() == :symphony_runner_pod_cache
  end

  test "waiting_reason tells Kueue's gate from an unschedulable pod" do
    assert PodWatch.waiting_reason(pod("a", "Pending", %{"spec" => %{"schedulingGates" => [%{"name" => "g"}]}})) == "scheduling_gated"

    unschedulable = pod("a", "Pending", %{"status" => %{"conditions" => [%{"type" => "PodScheduled", "status" => "False", "reason" => "Unschedulable"}]}})
    assert PodWatch.waiting_reason(unschedulable) == "unschedulable"
    assert PodWatch.waiting_reason(pod("a", "Pending")) == nil
    assert PodWatch.waiting_reason(pod("a", "Running")) == nil
  end

  describe "Kubernetes.status/2 with the cache" do
    test "answers from the cache and fetches only a missing pod", ctx do
      start_watch!(ctx, [list([pod("cached", "Running"), pod("failed", "Failed", %{"status" => %{"reason" => "Evicted"}})], "10"), :block])
      assert_receive {:request, :watch, _path, _params}

      parent = self()

      get = fn conn ->
        send(parent, {:get, conn.request_path})
        Req.Test.json(conn, %{"status" => %{"phase" => "Pending"}})
      end

      opts = [pod_cache: ctx.table, base_url: "https://kube.test", req_options: [retry: false, plug: get]]

      assert :alive = Kubernetes.status("k8s:runs/cached", opts)
      assert {:gone, {:pod_failed, "Evicted"}} = Kubernetes.status("k8s:runs/failed", opts)
      refute_received {:get, _path}

      assert :alive = Kubernetes.status("k8s:runs/new", opts)
      assert_received {:get, "/api/v1/namespaces/runs/pods/new"}

      # Another namespace is not in this cache.
      assert :alive = Kubernetes.status("k8s:elsewhere/cached", opts)
      assert_received {:get, "/api/v1/namespaces/elsewhere/pods/cached"}

      assert counter("symphony_runner_pod_status_checks_total", source: "cache") == 2
      assert counter("symphony_runner_pod_status_checks_total", source: "miss") == 1
      assert counter("symphony_runner_pod_status_checks_total", source: "stale") == 1
    end
  end
end
