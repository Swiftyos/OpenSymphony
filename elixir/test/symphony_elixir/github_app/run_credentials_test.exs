# credo:disable-for-this-file Credo.Check.Readability.MaxLineLength
defmodule SymphonyElixir.GitHubApp.RunCredentialsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubApp.RunCredentials
  alias SymphonyElixir.RunLauncher.Kubernetes
  alias SymphonyElixir.RunLauncher.Kubernetes.PodSpec
  alias SymphonyElixir.RunLauncher.Process, as: ProcessLauncher
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.RunWatcher

  @token "ghs_" <> String.duplicate("k", 36)
  @expires "2030-01-01T01:00:00Z"
  @secrets "/api/v1/namespaces/symphony-runs/secrets"
  @pods "/api/v1/namespaces/symphony-runs/pods"

  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:ok, pem: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])}
  end

  setup do
    run_id = "run-gh-#{System.unique_integer([:positive])}"
    on_exit(fn -> RunWatcher.stop(run_id) end)

    %{
      spec: %RunSpec{
        run_id: run_id,
        epoch: 1,
        issue: %{id: "issue-1", identifier: "MT-1", project_slug: "p", labels: []},
        controller_url: "http://symphony.symphony.svc:4000",
        token: "run-token"
      }
    }
  end

  defp settings(pem, extra \\ %{}) do
    base = %{
      "tracker" => %{
        "kind" => "memory",
        "projects" => [%{"slug" => "p", "repo" => "octo/home", "repos" => [%{"name" => "docs", "repo" => "octo/docs"}]}]
      },
      "workspace" => %{"root" => "/workspace"},
      "agent" => %{
        "kubernetes" => %{
          "runner_image" => "registry.test/symphony:test",
          "agent_tools_image" => "registry.test/tools:test",
          "controller_url" => "http://symphony.symphony.svc:4000"
        }
      }
    }

    base = if pem, do: Map.put(base, "github_app", %{"app_id" => 42, "private_key" => pem, "installation_id" => 7}), else: base
    {:ok, settings} = Schema.parse(Map.merge(base, extra))
    settings
  end

  # Records every token request (path and body) and answers with @token.
  defp github_plug(parent, status \\ 201) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:github_request, conn.method, conn.request_path, Jason.decode!(body)})

      if status in 200..299 do
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"token" => @token, "expires_at" => @expires})
      else
        Plug.Conn.send_resp(conn, status, "{}")
      end
    end
  end

  describe "attach/3" do
    test "mints a token for the run's home repository only, with the configured permissions", %{pem: pem, spec: spec} do
      assert {spec, credentials} = RunCredentials.attach(spec, settings(pem), plug: github_plug(self()), cache: false)

      assert spec.github_host == "github.com"
      assert credentials.token == @token
      assert credentials.host == "github.com"
      assert DateTime.to_iso8601(credentials.expires_at) == @expires

      assert_receive {:github_request, "POST", "/app/installations/7/access_tokens", body}
      # The project's first repo is the home repo; the reference repo gets nothing.
      assert body["repositories"] == ["home"]
      assert body["permissions"] == %{"contents" => "write", "pull_requests" => "write", "metadata" => "read"}
      refute Map.has_key?(body["permissions"], "workflows")
      refute Map.has_key?(body["permissions"], "administration")
      refute_receive {:github_request, _method, _path, _body}
    end

    test "a repo label picks a different home repo", %{pem: pem, spec: spec} do
      spec = %{spec | issue: %{spec.issue | labels: ["repo/docs"]}}
      assert {_spec, %{token: @token}} = RunCredentials.attach(spec, settings(pem), plug: github_plug(self()), cache: false)
      assert_receive {:github_request, "POST", _path, %{"repositories" => ["docs"]}}
    end

    test "without github_app nothing changes", %{spec: spec} do
      assert {^spec, nil} = RunCredentials.attach(spec, settings(nil), plug: fn _conn -> flunk("no GitHub call expected") end)
      assert RunCredentials.env(nil) == []
      assert :ok = RunCredentials.write_file("/nonexistent/spec.json", nil)
    end

    test "a failed mint still marks the spec so the runner asks for a token later", %{pem: pem, spec: spec} do
      log =
        capture_log(fn ->
          assert {%RunSpec{github_host: "github.com"}, nil} =
                   RunCredentials.attach(spec, settings(pem), plug: github_plug(self(), 403), cache: false)
        end)

      assert log =~ "GitHub App token unavailable at launch"
      refute log =~ "ghs_"
    end
  end

  test "env/1 is the git and gh environment plus the expiry", %{pem: pem, spec: spec} do
    {_spec, credentials} = RunCredentials.attach(spec, settings(pem), plug: github_plug(self()), cache: false)
    env = Map.new(RunCredentials.env(credentials))

    assert env["GH_TOKEN"] == @token
    assert env["GIT_CONFIG_COUNT"] == "1"
    assert env["GIT_CONFIG_KEY_0"] == "http.https://github.com/.extraHeader"
    assert env["GIT_CONFIG_VALUE_0"] == "Authorization: Basic " <> Base.encode64("x-access-token:" <> @token)
    assert env["SYMPHONY_GITHUB_TOKEN_EXPIRES_AT"] == @expires
  end

  test "refresh/3 returns the token JSON, or not configured", %{pem: pem, spec: spec} do
    assert {:ok, %{"token" => @token, "expires_at" => @expires, "host" => "github.com"}} =
             RunCredentials.refresh(spec, settings(pem), plug: github_plug(self()), cache: false)

    assert_receive {:github_request, "POST", _path, %{"repositories" => ["home"]}}
    assert {:error, :github_app_not_configured} = RunCredentials.refresh(spec, settings(nil))
    assert {:error, :forbidden} = RunCredentials.refresh(spec, settings(pem), plug: github_plug(self(), 403), cache: false)
  end

  describe "the Kubernetes run Secret" do
    setup %{pem: pem, spec: spec} do
      {spec, credentials} = RunCredentials.attach(spec, settings(pem), plug: github_plug(self()), cache: false)
      %{spec: spec, credentials: credentials}
    end

    test "carries the token as env keys the runner reads by secretKeyRef, never as a literal in the pod", %{pem: pem, spec: spec, credentials: credentials} do
      assert {:ok, rendered} = PodSpec.render(spec, settings(pem), %{file_name: "symphony.yml", content: "x: 1\n"}, github: credentials)

      data = rendered.secret["stringData"]
      assert data["GH_TOKEN"] == @token
      assert data["GIT_CONFIG_KEY_0"] == "http.https://github.com/.extraHeader"
      assert data["GIT_CONFIG_VALUE_0"] =~ "Authorization: Basic "
      assert data["SYMPHONY_GITHUB_TOKEN_EXPIRES_AT"] == @expires
      # spec.json has the host, never the token.
      spec_json = Jason.decode!(data["spec.json"])
      assert spec_json["github_host"] == "github.com"
      refute data["spec.json"] =~ @token

      [container] = rendered.pod["spec"]["containers"]
      env = Map.new(container["env"], &{&1["name"], &1})

      for name <- ~w(GH_TOKEN GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_TERMINAL_PROMPT SYMPHONY_GITHUB_TOKEN_EXPIRES_AT) do
        assert env[name]["valueFrom"]["secretKeyRef"] == %{"name" => rendered.name, "key" => name}
        refute Map.has_key?(env[name], "value")
      end

      pod_json = Jason.encode!(rendered.pod)
      refute pod_json =~ @token
      refute pod_json =~ Base.encode64("x-access-token:" <> @token)
      refute Enum.any?(container["args"], &(&1 =~ "ghs_"))
    end

    test "the run's token comes after secret_env, so it wins over a static GH_TOKEN", %{pem: pem, spec: spec, credentials: credentials} do
      settings = settings(pem, %{"agent" => put_in(settings_agent(), ["kubernetes", "secret_env"], [%{"env" => "GH_TOKEN", "secret" => "static", "key" => "token"}])})

      assert {:ok, rendered} = PodSpec.render(spec, settings, %{file_name: "symphony.yml", content: ""}, github: credentials)
      [container] = rendered.pod["spec"]["containers"]
      names = Enum.map(container["env"], & &1["name"])
      assert Enum.count(names, &(&1 == "GH_TOKEN")) == 2
      assert List.last(Enum.filter(container["env"], &(&1["name"] == "GH_TOKEN")))["valueFrom"]["secretKeyRef"]["name"] == rendered.name
    end

    test "without github_app the Secret and pod are unchanged", %{spec: spec} do
      spec = %{spec | github_host: nil}
      assert {:ok, rendered} = PodSpec.render(spec, settings(nil), %{file_name: "symphony.yml", content: ""})
      assert Map.keys(rendered.secret["stringData"]) == ["spec.json"]
      [container] = rendered.pod["spec"]["containers"]
      assert Enum.map(container["env"], & &1["name"]) == ["PATH"]
    end

    test "secret_env may not hand the App private key to a runner", %{spec: spec} do
      settings = settings(nil, %{"agent" => put_in(settings_agent(), ["kubernetes", "secret_env"], [%{"env" => "GITHUB_APP_PRIVATE_KEY", "secret" => "app", "key" => "pem"}])})
      assert {:error, {:invalid_kubernetes_config, message}} = PodSpec.render(spec, settings, %{file_name: "symphony.yml", content: ""})
      assert message =~ "GITHUB_APP_PRIVATE_KEY"
    end
  end

  describe "Kubernetes.start_process/2" do
    test "mints at launch and creates the Secret with the token", %{pem: pem, spec: spec} do
      parent = self()
      config_path = config_file!("github_app:\n  app_id: 42\n  private_key: $GITHUB_APP_PRIVATE_KEY\n")

      kube = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case {conn.method, conn.request_path} do
          {"POST", @secrets} -> send(parent, {:secret, Jason.decode!(body)})
          _other -> :ok
        end

        case {conn.method, conn.request_path} do
          {"POST", @pods} -> Req.Test.json(conn, %{"metadata" => %{"uid" => "uid-1"}})
          {"GET", _path} -> Req.Test.json(conn, %{"status" => %{"phase" => "Running"}})
          _other -> Req.Test.json(conn, %{})
        end
      end

      capture_log(fn ->
        assert {:ok, watcher, _ref} =
                 Kubernetes.start_process(spec,
                   settings: settings(pem),
                   config_path: config_path,
                   base_url: "https://kube.test",
                   token: "kube-token",
                   req_options: [retry: false, plug: kube],
                   github_app: [plug: github_plug(parent), cache: false]
                 )

        RunWatcher.stop(watcher)
      end)

      assert_receive {:github_request, "POST", _path, %{"repositories" => ["home"]}}
      assert_receive {:secret, %{"stringData" => %{"GH_TOKEN" => @token} = data}}
      assert Jason.decode!(data["spec.json"])["github_host"] == "github.com"
    end

    test "a runner config with a literal private key is refused before anything is created", %{pem: pem, spec: spec} do
      config_path = config_file!("github_app:\n  app_id: 42\n  private_key: |\n    " <> String.replace(pem, "\n", "\n    "))

      capture_log(fn ->
        assert {:error, {:runner_config, ^config_path, :contains_private_key}} =
                 Kubernetes.start_process(spec,
                   settings: settings(pem),
                   config_path: config_path,
                   base_url: "https://kube.test",
                   token: "kube-token",
                   req_options: [plug: fn _conn -> flunk("no API call expected") end]
                 )
      end)
    end
  end

  describe "Process launcher" do
    setup do
      root = Path.join(System.tmp_dir!(), "gh-process-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      previous_root = Application.get_env(:symphony_elixir, :state_root)
      previous_key = System.get_env("GITHUB_APP_PRIVATE_KEY")
      Application.put_env(:symphony_elixir, :state_root, Path.join(root, "state"))
      System.put_env("GITHUB_APP_PRIVATE_KEY", "controller-only-key")

      on_exit(fn ->
        if previous_root, do: Application.put_env(:symphony_elixir, :state_root, previous_root), else: Application.delete_env(:symphony_elixir, :state_root)
        if previous_key, do: System.put_env("GITHUB_APP_PRIVATE_KEY", previous_key), else: System.delete_env("GITHUB_APP_PRIVATE_KEY")
        File.rm_rf(root)
      end)

      %{root: root}
    end

    test "writes an owner-only github-token.json and starts the runner without the App key", %{pem: pem, spec: spec, root: root} do
      out = Path.join(root, "runner.env")
      token_copy = Path.join(root, "token.json")
      command = "sh -c 'cp \"$(dirname \"$1\")/github-token.json\" #{token_copy}; env > #{out}' runner {spec}"

      capture_log(fn ->
        assert {:ok, watcher, _ref} =
                 ProcessLauncher.start_process(spec,
                   command: command,
                   settings: settings(pem),
                   github_app: [plug: github_plug(self()), cache: false],
                   startup_check_ms: 5_000
                 )

        assert wait_for(fn -> File.exists?(out) and File.read!(out) =~ "PATH=" end)
        RunWatcher.stop(watcher)
      end)

      refute File.read!(out) =~ "GITHUB_APP_PRIVATE_KEY"
      assert %{"token" => @token, "expires_at" => @expires, "host" => "github.com"} = Jason.decode!(File.read!(token_copy))

      token_file = RunSpec.github_token_path(RunSpec.path(spec.run_id))
      assert %{mode: mode} = File.stat!(token_file)
      assert Bitwise.band(mode, 0o077) == 0
      assert {:ok, %RunSpec{github_host: "github.com", token: "run-token"}} = RunSpec.read(RunSpec.path(spec.run_id))
      refute File.read!(RunSpec.path(spec.run_id)) =~ @token

      # Ending the run removes the token file with the spec.
      :ok = RunSpec.delete(spec.run_id)
      refute File.exists?(token_file)
    end

    test "without github_app no token file is written", %{spec: spec, root: root} do
      out = Path.join(root, "runner.done")

      capture_log(fn ->
        assert {:ok, watcher, _ref} = ProcessLauncher.start_process(spec, command: "touch #{out}", settings: settings(nil))
        assert wait_for(fn -> File.exists?(out) end)
        RunWatcher.stop(watcher)
      end)

      refute File.exists?(RunSpec.github_token_path(RunSpec.path(spec.run_id)))
      assert {:ok, %RunSpec{github_host: nil}} = RunSpec.read(RunSpec.path(spec.run_id))
    end
  end

  defp settings_agent do
    %{
      "kubernetes" => %{
        "runner_image" => "registry.test/symphony:test",
        "agent_tools_image" => "registry.test/tools:test",
        "controller_url" => "http://symphony.symphony.svc:4000"
      }
    }
  end

  defp config_file!(content) do
    directory = Path.join(System.tmp_dir!(), "gh-runner-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    path = Path.join(directory, "symphony.yml")
    File.write!(path, content)
    path
  end

  defp wait_for(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) > deadline -> :timeout
        true -> Process.sleep(20) && nil
      end
    end)
    |> Enum.find(& &1)
    |> Kernel.==(:ok)
  end
end
