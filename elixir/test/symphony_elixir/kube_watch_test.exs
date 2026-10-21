defmodule SymphonyElixir.KubeWatchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Kube

  @pods "/api/v1/namespaces/runs/pods"

  defp client(plug) do
    {:ok, client} = Kube.client(base_url: "https://kube.test", req_options: [retry: false, plug: plug])
    client
  end

  defp lines(events), do: Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))

  defp pod_event(type, name, version) do
    %{"type" => type, "object" => %{"metadata" => %{"name" => name, "resourceVersion" => version}}}
  end

  describe "list_pods_with_version/4" do
    test "follows continue tokens and returns every page's items with the list's resourceVersion" do
      parent = self()

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(parent, {:list, conn.request_path, conn.query_params})

        case conn.query_params["continue"] do
          nil ->
            Req.Test.json(conn, %{"metadata" => %{"continue" => "page-2", "resourceVersion" => "10"}, "items" => [%{"metadata" => %{"name" => "a"}}]})

          "page-2" ->
            Req.Test.json(conn, %{"metadata" => %{"resourceVersion" => "10"}, "items" => [%{"metadata" => %{"name" => "b"}}, "junk"]})
        end
      end

      assert {:ok, [%{"metadata" => %{"name" => "a"}}, %{"metadata" => %{"name" => "b"}}], "10"} =
               Kube.list_pods_with_version(client(plug), "runs", "app=x", limit: 1)

      assert_receive {:list, @pods, %{"labelSelector" => "app=x", "limit" => "1"}}
      assert_receive {:list, @pods, %{"continue" => "page-2", "limit" => "1"}}
    end

    test "an expired continue token is :gone and other errors pass through" do
      gone = fn conn -> Plug.Conn.send_resp(conn, 410, ~s({"kind":"Status","code":410})) end
      assert {:error, :gone} = Kube.list_pods_with_version(client(gone), "runs", "app=x")

      forbidden = fn conn -> Plug.Conn.send_resp(conn, 403, "no") end
      assert {:error, {:http_error, 403, "no"}} = Kube.list_pods_with_version(client(forbidden), "runs", "app=x")

      no_metadata = fn conn -> Req.Test.json(conn, %{"items" => nil}) end
      assert {:ok, [], nil} = Kube.list_pods_with_version(client(no_metadata), "runs", "app=x")
    end
  end

  describe "watch_pods/6" do
    test "streams events in batches from the resourceVersion with bookmarks and ends :closed" do
      parent = self()

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(parent, {:watch, conn.request_path, conn.query_params, Plug.Conn.get_req_header(conn, "accept-encoding")})

        # The last line has no newline: it still counts when the stream ends.
        body =
          lines([pod_event("ADDED", "a", "11"), %{"type" => "BOOKMARK", "object" => %{"metadata" => %{"resourceVersion" => "12"}}}]) <>
            Jason.encode!(pod_event("DELETED", "a", "13"))

        Plug.Conn.send_resp(conn, 200, body)
      end

      assert {:ok, :closed} =
               Kube.watch_pods(client(plug), "runs", "app=x", "10", &send(parent, {:events, &1}), timeout_seconds: 5)

      assert_receive {:watch, @pods, params, []}

      assert params == %{
               "labelSelector" => "app=x",
               "watch" => "1",
               "allowWatchBookmarks" => "true",
               "timeoutSeconds" => "5",
               "resourceVersion" => "10"
             }

      assert_receive {:events, [%{"type" => "ADDED"}, %{"type" => "BOOKMARK"}]}
      assert_receive {:events, [%{"type" => "DELETED"}]}
    end

    test "without a resourceVersion the watch starts from now, and an empty stream is :closed" do
      parent = self()

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(parent, {:params, conn.query_params})
        Plug.Conn.send_resp(conn, 200, "\n")
      end

      assert {:ok, :closed} = Kube.watch_pods(client(plug), "runs", "app=x", nil, fn _events -> flunk("no events") end)
      assert_receive {:params, params}
      refute Map.has_key?(params, "resourceVersion")
    end

    test "a 410 ERROR event is :gone and another is a watch error; its batch is dropped, so a rewatch replays it" do
      parent = self()

      gone = fn conn ->
        Plug.Conn.send_resp(conn, 200, lines([pod_event("MODIFIED", "a", "5"), %{"type" => "ERROR", "object" => %{"code" => 410, "reason" => "Expired"}}]))
      end

      assert {:error, :gone} = Kube.watch_pods(client(gone), "runs", "app=x", "1", &send(parent, {:events, &1}))
      refute_received {:events, _events}

      error = fn conn -> Plug.Conn.send_resp(conn, 200, lines([%{"type" => "ERROR", "object" => %{"code" => 500}}])) end
      assert {:error, {:watch_error, %{"code" => 500}}} = Kube.watch_pods(client(error), "runs", "app=x", "1", fn _ -> :ok end)

      trailing_error = fn conn -> Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"type" => "ERROR", "object" => %{"code" => 410}})) end
      assert {:error, :gone} = Kube.watch_pods(client(trailing_error), "runs", "app=x", "1", fn _ -> :ok end)
    end

    test "an unparseable line stops the watch" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "not json\n") end
      assert {:error, {:invalid_watch_event, "not json"}} = Kube.watch_pods(client(plug), "runs", "app=x", "1", fn _ -> :ok end)
    end

    test "HTTP errors keep their status and body, and a transport error passes through" do
      gone = fn conn -> Plug.Conn.send_resp(conn, 410, "gone") end
      assert {:error, :gone} = Kube.watch_pods(client(gone), "runs", "app=x", "1", fn _ -> :ok end)

      missing = fn conn -> Plug.Conn.send_resp(conn, 404, "") end
      assert {:error, :not_found} = Kube.watch_pods(client(missing), "runs", "app=x", "1", fn _ -> :ok end)

      forbidden = fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"reason":"Forbidden"})) end
      assert {:error, {:http_error, 403, %{"reason" => "Forbidden"}}} = Kube.watch_pods(client(forbidden), "runs", "app=x", "1", fn _ -> :ok end)

      down = fn conn -> Req.Test.transport_error(conn, :econnrefused) end

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Kube.watch_pods(client(down), "runs", "app=x", "1", fn _ -> :ok end)
    end
  end

  describe "line handling" do
    test "split_lines keeps the unfinished rest of a chunk for the next one" do
      assert {[], "{\"ty"} = Kube.split_lines("{\"ty")
      assert {["a", "b"], ""} = Kube.split_lines("a\n\nb\n")
      assert {["a"], "partial"} = Kube.split_lines("a\npartial")
    end

    test "events split across chunks decode once complete" do
      line = Jason.encode!(pod_event("ADDED", "a", "1"))
      {first, second} = String.split_at(line <> "\n", 10)

      {[], rest} = Kube.split_lines(first)
      {[complete], ""} = Kube.split_lines(rest <> second)
      assert {:ok, [%{"type" => "ADDED"}]} = Kube.decode_watch_lines([complete])
      assert {:error, {:invalid_watch_event, _line}} = Kube.decode_watch_lines([~s({"type":"ADDED"})])
    end
  end
end
