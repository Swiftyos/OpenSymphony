defmodule SymphonyElixir.KubeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Kube

  setup do
    previous = Application.get_env(:symphony_elixir, :kube_options)
    Application.delete_env(:symphony_elixir, :kube_options)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :kube_options)
        value -> Application.put_env(:symphony_elixir, :kube_options, value)
      end
    end)

    :ok
  end

  test "an explicit client uses the base URL, token and request options" do
    parent = self()

    assert {:ok, client} =
             Kube.client(
               base_url: "https://kube.test/",
               token: "token-1",
               req_options: [
                 plug: fn conn ->
                   send(parent, {:request, Plug.Conn.get_req_header(conn, "authorization")})
                   Req.Test.json(conn, %{"ok" => true})
                 end
               ]
             )

    assert {:ok, %{"ok" => true}} = Kube.get_pod(client, "symphony-runs", "run-1")
    assert_receive {:request, ["Bearer token-1"]}
  end

  test "list_pods and list_secrets list by label selector and return the items" do
    parent = self()

    assert {:ok, client} =
             Kube.client(
               base_url: "https://kube.test",
               req_options: [
                 retry: false,
                 plug: fn conn ->
                   conn = Plug.Conn.fetch_query_params(conn)
                   send(parent, {:list, conn.method, conn.request_path, conn.query_params})

                   case conn.request_path do
                     "/api/v1/namespaces/runs/pods" -> Req.Test.json(conn, %{"items" => [%{"metadata" => %{"name" => "run-1"}}, "junk"]})
                     "/api/v1/namespaces/runs/secrets" -> Req.Test.json(conn, %{"kind" => "SecretList"})
                     _other -> Plug.Conn.send_resp(conn, 403, "forbidden")
                   end
                 end
               ]
             )

    assert {:ok, [%{"metadata" => %{"name" => "run-1"}}]} = Kube.list_pods(client, "runs", "app=x")
    assert_receive {:list, "GET", "/api/v1/namespaces/runs/pods", %{"labelSelector" => "app=x"}}
    assert {:ok, []} = Kube.list_secrets(client, "runs", "app=x")
    assert {:error, {:http_error, 403, "forbidden"}} = Kube.list_pods(client, "other", "app=x")
  end

  test "a client without a token sends no authorization header" do
    parent = self()

    assert {:ok, client} =
             Kube.client(
               base_url: "https://kube.test",
               req_options: [
                 plug: fn conn ->
                   send(parent, {:request, Plug.Conn.get_req_header(conn, "authorization")})
                   Req.Test.json(conn, %{})
                 end
               ]
             )

    assert {:ok, %{}} = Kube.get_pod(client, "symphony-runs", "run-1")
    assert_receive {:request, []}
  end

  test "application options are used when no explicit ones are given" do
    Application.put_env(:symphony_elixir, :kube_options, base_url: "https://app.test", token: "app-token")
    parent = self()

    assert {:ok, client} =
             Kube.client(
               req_options: [
                 plug: fn conn ->
                   send(parent, {:request, Plug.Conn.get_req_header(conn, "authorization")})
                   Req.Test.json(conn, %{})
                 end
               ]
             )

    assert {:ok, %{}} = Kube.get_pod(client, "ns", "run-1")
    assert_receive {:request, ["Bearer app-token"]}
    assert {:ok, _client} = Kube.client()
  end

  test "in-cluster config reads the token, CA and service-account variables" do
    directory = service_account_dir(%{"token" => "token-from-file", "ca.crt" => ca_pem()})
    parent = self()

    assert {:ok, client} =
             Kube.client(
               service_account_dir: directory,
               env: %{"KUBERNETES_SERVICE_HOST" => "10.0.0.1", "KUBERNETES_SERVICE_PORT" => "6443"},
               req_options: [
                 plug: fn conn ->
                   send(parent, {:request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})
                   Req.Test.json(conn, %{"status" => %{"phase" => "Pending"}})
                 end
               ]
             )

    assert {:ok, %{"status" => %{"phase" => "Pending"}}} = Kube.get_pod(client, "ns", "run-1")
    assert_receive {:request, "/api/v1/namespaces/ns/pods/run-1", ["Bearer token-from-file"]}
  end

  test "in-cluster config brackets an IPv6 API server host" do
    directory = service_account_dir(%{"token" => "token", "ca.crt" => ca_pem()})
    parent = self()

    assert {:ok, client} =
             Kube.client(
               service_account_dir: directory,
               env: %{"KUBERNETES_SERVICE_HOST" => "fd00::1", "KUBERNETES_SERVICE_PORT" => "443"},
               req_options: [
                 plug: fn conn ->
                   send(parent, {:request, conn.request_path})
                   Req.Test.json(conn, %{})
                 end
               ]
             )

    assert {:ok, %{}} = Kube.get_pod(client, "ns", "run-1")
    assert_receive {:request, "/api/v1/namespaces/ns/pods/run-1"}
  end

  test "in-cluster config fails without the host, port, token or CA" do
    directory = service_account_dir(%{"token" => "token", "ca.crt" => ca_pem()})

    assert {:error, :not_in_cluster} =
             Kube.client(service_account_dir: directory, env: %{"KUBERNETES_SERVICE_PORT" => "443"})

    assert {:error, :not_in_cluster} =
             Kube.client(service_account_dir: directory, env: %{"KUBERNETES_SERVICE_HOST" => "10.0.0.1"})

    assert {:error, {:in_cluster_config, :enoent}} =
             Kube.client(
               service_account_dir: service_account_dir(%{"ca.crt" => ca_pem()}),
               env: %{"KUBERNETES_SERVICE_HOST" => "10.0.0.1", "KUBERNETES_SERVICE_PORT" => "443"}
             )

    assert {:error, {:in_cluster_config, :enoent}} =
             Kube.client(
               service_account_dir: service_account_dir(%{"token" => "token"}),
               env: %{"KUBERNETES_SERVICE_HOST" => "10.0.0.1", "KUBERNETES_SERVICE_PORT" => "443"}
             )
  end

  test "in-cluster TLS verifies the API server with the decoded CA certificates" do
    %{cert: der} = :public_key.pkix_test_root_cert(~c"Kube Test CA", [])
    pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    directory = service_account_dir(%{"token" => "token", "ca.crt" => pem})

    assert {:ok, client} =
             Kube.client(
               service_account_dir: directory,
               env: %{"KUBERNETES_SERVICE_HOST" => "10.0.0.1", "KUBERNETES_SERVICE_PORT" => "443"},
               req_options: [connect_options: [timeout: 1_000, transport_opts: [depth: 3]]]
             )

    connect_options = client.req.options.connect_options
    assert connect_options[:timeout] == 1_000
    transport_opts = connect_options[:transport_opts]
    assert transport_opts[:cacerts] == [der]
    assert transport_opts[:verify] == :verify_peer
    assert transport_opts[:depth] == 3
    refute Keyword.has_key?(transport_opts, :cacertfile)
    assert [match_fun: match_fun] = transport_opts[:customize_hostname_check]
    assert is_function(match_fun, 2)
  end

  test "explicit credentials leave TLS options to the caller" do
    assert {:ok, client} = Kube.client(base_url: "https://kube.test", token: "token")
    refute Map.has_key?(client.req.options, :connect_options)
  end

  test "in-cluster config rejects a CA file without a certificate" do
    directory = service_account_dir(%{"token" => "token", "ca.crt" => "not a certificate"})

    assert {:error, {:in_cluster_config, :invalid_ca_certificate}} =
             Kube.client(
               service_account_dir: directory,
               env: %{"KUBERNETES_SERVICE_HOST" => "10.0.0.1", "KUBERNETES_SERVICE_PORT" => "443"}
             )
  end

  test "the in-cluster token is re-read on every request" do
    directory = service_account_dir(%{"token" => "first-token\n", "ca.crt" => ca_pem()})
    parent = self()

    assert {:ok, client} =
             Kube.client(
               service_account_dir: directory,
               env: %{"KUBERNETES_SERVICE_HOST" => "10.0.0.1", "KUBERNETES_SERVICE_PORT" => "443"},
               req_options: [
                 retry: false,
                 plug: fn conn ->
                   send(parent, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
                   Req.Test.json(conn, %{})
                 end
               ]
             )

    assert {:ok, %{}} = Kube.get_pod(client, "ns", "run-1")
    assert_receive {:authorization, ["Bearer first-token"]}

    File.write!(Path.join(directory, "token"), "rotated-token")
    assert {:ok, %{}} = Kube.get_pod(client, "ns", "run-1")
    assert_receive {:authorization, ["Bearer rotated-token"]}

    File.rm!(Path.join(directory, "token"))
    assert {:error, %File.Error{reason: :enoent}} = Kube.get_pod(client, "ns", "run-1")
    refute_receive {:authorization, _header}
  end

  test "config maps are created, patched and deleted, and secrets are patched" do
    parent = self()

    client =
      client!(
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:request, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "content-type"), body})
          Req.Test.json(conn, %{"kind" => "ok"})
        end
      )

    config_map = %{"apiVersion" => "v1", "kind" => "ConfigMap", "metadata" => %{"name" => "run-1"}}
    patch = %{"metadata" => %{"ownerReferences" => [%{"kind" => "Pod", "uid" => "uid-1"}]}}

    assert {:ok, _} = Kube.create_config_map(client, "symphony-runs", config_map)
    assert_receive {:request, "POST", "/api/v1/namespaces/symphony-runs/configmaps", _type, body}
    assert Jason.decode!(body) == config_map

    assert {:ok, _} = Kube.patch_config_map(client, "symphony-runs", "run-1", patch)
    assert_receive {:request, "PATCH", "/api/v1/namespaces/symphony-runs/configmaps/run-1", ["application/merge-patch+json"], body}
    assert Jason.decode!(body) == patch

    assert {:ok, _} = Kube.patch_secret(client, "symphony-runs", "run-1", patch)
    assert_receive {:request, "PATCH", "/api/v1/namespaces/symphony-runs/secrets/run-1", ["application/merge-patch+json"], body}
    assert Jason.decode!(body) == patch

    assert {:ok, _} = Kube.delete_config_map(client, "symphony-runs", "run-1")
    assert_receive {:request, "DELETE", "/api/v1/namespaces/symphony-runs/configmaps/run-1", _type, ""}
  end

  test "pods are created, read and deleted at the namespaced API paths" do
    parent = self()

    client =
      client!(
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:request, conn.method, conn.request_path, body})

          cond do
            conn.request_path == "/api/v1/namespaces/symphony-runs/pods/run-1" and conn.method == "GET" ->
              Req.Test.json(conn, %{"metadata" => %{"name" => "run-1"}, "status" => %{"phase" => "Running"}})

            conn.method == "POST" ->
              Req.Test.json(conn, %{"kind" => "Pod"})

            true ->
              Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"status" => "Success"}))
          end
        end
      )

    pod = %{"apiVersion" => "v1", "kind" => "Pod", "metadata" => %{"name" => "run-1"}}

    assert {:ok, %{"kind" => "Pod"}} = Kube.create_pod(client, "symphony-runs", pod)
    assert_receive {:request, "POST", "/api/v1/namespaces/symphony-runs/pods", body}
    assert Jason.decode!(body) == pod

    assert {:ok, %{"status" => %{"phase" => "Running"}}} = Kube.get_pod(client, "symphony-runs", "run-1")
    assert_receive {:request, "GET", "/api/v1/namespaces/symphony-runs/pods/run-1", ""}

    assert {:ok, %{"status" => "Success"}} = Kube.delete_pod(client, "symphony-runs", "run-1")
    assert_receive {:request, "DELETE", "/api/v1/namespaces/symphony-runs/pods/run-1", ""}
  end

  test "secrets are created and deleted at the namespaced API paths" do
    parent = self()

    client =
      client!(
        plug: fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:request, conn.method, conn.request_path})

          if conn.method == "POST" do
            Req.Test.json(conn, %{"kind" => "Secret"})
          else
            Plug.Conn.send_resp(conn, 200, "")
          end
        end
      )

    secret = %{"apiVersion" => "v1", "kind" => "Secret", "metadata" => %{"name" => "run-1"}}

    assert {:ok, %{"kind" => "Secret"}} = Kube.create_secret(client, "symphony-runs", secret)
    assert_receive {:request, "POST", "/api/v1/namespaces/symphony-runs/secrets"}

    assert {:ok, %{}} = Kube.delete_secret(client, "symphony-runs", "run-1")
    assert_receive {:request, "DELETE", "/api/v1/namespaces/symphony-runs/secrets/run-1"}
  end

  test "a missing object is :not_found and a rejected request keeps its status" do
    client =
      client!(
        plug: fn
          %{request_path: "/api/v1/namespaces/ns/pods/missing"} = conn -> Plug.Conn.send_resp(conn, 404, "not found")
          conn -> Plug.Conn.send_resp(conn, 500, "boom")
        end
      )

    assert {:error, :not_found} = Kube.get_pod(client, "ns", "missing")
    assert {:error, {:http_error, 500, "boom"}} = Kube.delete_pod(client, "ns", "broken")
    assert {:error, {:http_error, 500, "boom"}} = Kube.delete_secret(client, "ns", "broken")
  end

  test "transport errors and empty or nil response bodies are handled" do
    refused = client!(plug: fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert {:error, %Req.TransportError{reason: :econnrefused}} = Kube.get_pod(refused, "ns", "run-1")

    nil_body = client!(plug: fn conn -> Req.Test.json(conn, nil) end)
    assert {:ok, %{}} = Kube.get_pod(nil_body, "ns", "run-1")

    empty_body = client!(plug: fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
    assert {:ok, %{}} = Kube.get_pod(empty_body, "ns", "run-1")

    invalid_body = client!(plug: fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)
    assert {:ok, %{}} = Kube.get_pod(invalid_body, "ns", "run-1")

    array_body = client!(plug: fn conn -> Plug.Conn.send_resp(conn, 200, Jason.encode!([%{"name" => "run-1"}])) end)
    assert {:ok, %{}} = Kube.get_pod(array_body, "ns", "run-1")

    list_body = client!(plug: fn conn -> Req.Test.json(conn, [%{"name" => "run-1"}]) end)
    assert {:ok, %{}} = Kube.get_pod(list_body, "ns", "run-1")
  end

  test "error bodies that are empty or nil become an empty map" do
    nil_error = client!(plug: fn conn -> Plug.Conn.put_status(conn, 500) |> Req.Test.json(nil) end)
    assert {:error, {:http_error, 500, %{}}} = Kube.get_pod(nil_error, "ns", "run-1")

    empty_error = client!(plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
    assert {:error, {:http_error, 500, %{}}} = Kube.get_pod(empty_error, "ns", "run-1")

    nil_body_error = client!(plug: fn conn -> Req.Test.json(conn, nil) end)
    assert {:ok, %{}} = Kube.get_pod(nil_body_error, "ns", "run-1")
  end

  test "in-cluster config reads the process environment when no env map is given" do
    directory = service_account_dir(%{"token" => "token", "ca.crt" => ca_pem()})
    previous_host = System.get_env("KUBERNETES_SERVICE_HOST")
    previous_port = System.get_env("KUBERNETES_SERVICE_PORT")
    System.put_env("KUBERNETES_SERVICE_HOST", "10.0.0.1")
    System.put_env("KUBERNETES_SERVICE_PORT", "443")

    on_exit(fn ->
      restore_env("KUBERNETES_SERVICE_HOST", previous_host)
      restore_env("KUBERNETES_SERVICE_PORT", previous_port)
    end)

    assert {:ok, _client} =
             Kube.client(
               service_account_dir: directory,
               req_options: [plug: fn conn -> Req.Test.json(conn, %{}) end]
             )
  end

  defp client!(req_options) do
    assert {:ok, client} = Kube.client([base_url: "https://kube.test"] ++ [req_options: Keyword.put_new(req_options, :retry, false)])
    client
  end

  defp ca_pem do
    %{cert: der} = :public_key.pkix_test_root_cert(~c"Kube Test CA", [])
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp service_account_dir(files) do
    directory = Path.join(System.tmp_dir!(), "kube-service-account-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    Enum.each(files, fn {name, body} -> File.write!(Path.join(directory, name), body) end)
    on_exit(fn -> File.rm_rf(directory) end)

    directory
  end
end
