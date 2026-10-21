defmodule SymphonyElixir.GitMirrorTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.{GitMirror, RunRegistry, RunSpec, RunToken}
  alias SymphonyElixir.GitMirror.UploadPack
  alias SymphonyElixir.RunnerTestSupport, as: Support

  @moduletag :tmp_dir

  describe "repo lookup and authorization" do
    test "resolves configured, cached repos and rejects anything else" do
      context = mirror_context!(two_repos: true)
      settings = Config.settings!()
      own = context.repo_source
      other = context.other_repo_source

      assert GitMirror.repo_key(own) == own.cache_key
      assert {:ok, repo} = GitMirror.resolve(own.cache_key, settings)
      assert repo.repo_source == own
      assert repo.cache_path == context.cache_path

      assert {:error, :unknown_repo} = GitMirror.resolve("missing", settings)
      assert {:error, :unknown_repo} = GitMirror.resolve("..", settings)
      assert {:error, :unknown_repo} = GitMirror.resolve("../etc", settings)
      assert {:error, :unknown_repo} = GitMirror.resolve(String.duplicate("a", 129), settings)
      assert {:error, :unknown_repo} = GitMirror.resolve(nil, settings)

      # A configured repo whose cache does not exist yet is not servable.
      File.rm_rf!(context.other_cache_path)
      assert {:error, :unknown_repo} = GitMirror.resolve(other.cache_key, settings)

      assert :ok = GitMirror.authorize(%{project_slug: "project-a", identifier: "PI-1"}, repo, settings)
      assert {:error, :forbidden} = GitMirror.authorize(%{project_slug: "project-b", identifier: "PI-2"}, repo, settings)
      assert :ok = GitMirror.authorize(%{identifier: "PI-3"}, repo, settings)
      assert :ok = GitMirror.authorize(%{project_slug: "no-repo", identifier: "PI-4"}, repo, settings)
      assert :ok = GitMirror.authorize(nil, repo, settings)
      assert :ok = GitMirror.authorize(%{"project_slug" => "project-a"}, repo, settings)
    end

    test "builds mirror and clone URLs and only offers a mirror when the cache exists" do
      context = mirror_context!()
      settings = Config.settings!()
      url = GitMirror.mirror_url("http://controller:4000/", "run-1", context.repo_source)
      assert url == "http://controller:4000/git/run-1/#{context.repo_key}"

      spec = %RunSpec{
        run_id: "run-1",
        epoch: 1,
        issue: context.issue,
        controller_url: "http://controller:4000",
        token: "a token/with+chars"
      }

      assert GitMirror.mirror_url_for(spec, settings) == url

      assert GitMirror.clone_url(%{spec | git_mirror_url: url}) ==
               "http://x-access-token:a+token%2Fwith%2Bchars@controller:4000/git/run-1/#{context.repo_key}"

      refute GitMirror.clone_url(spec)
      refute GitMirror.clone_url(%{spec | token: nil, git_mirror_url: url})
      refute GitMirror.mirror_url_for(%{spec | controller_url: nil}, settings)
      refute GitMirror.mirror_url_for(%{spec | issue: %{id: "none"}}, settings)

      File.rm_rf!(context.cache_path)
      refute GitMirror.mirror_url_for(spec, settings)
    end

    test "stale? follows the cache freshness marker" do
      context = mirror_context!()
      marker = Path.join([context.cache_path, ".git", "symphony-fetched-at"])
      now = System.system_time(:second)

      assert GitMirror.stale?(context.cache_path, 0)
      refute GitMirror.stale?(context.cache_path, 60_000)

      File.write!(marker, "#{now - 120}\n")
      assert GitMirror.stale?(context.cache_path, 60_000)
      refute GitMirror.stale?(context.cache_path, 130_000)

      File.write!(marker, "not-a-time\n")
      assert GitMirror.stale?(context.cache_path, 60_000)

      File.rm!(marker)
      assert GitMirror.stale?(context.cache_path, 60_000)
    end

    test "maybe_refresh asks the refresher only when the cache is stale" do
      context = mirror_context!()
      settings = Config.settings!()
      parent = self()
      refresher = spawn_link(fn -> refresh_loop(parent) end)

      assert :ok = GitMirror.maybe_refresh(context.repo, put_in(settings.workspace.repo_cache.max_age_ms, 60_000), refresher: refresher)
      refute_received :refreshed

      marker = Path.join([context.cache_path, ".git", "symphony-fetched-at"])
      File.write!(marker, "0\n")

      assert :ok = GitMirror.maybe_refresh(context.repo, put_in(settings.workspace.repo_cache.max_age_ms, 60_000), refresher: refresher)
      assert_receive :refreshed
    end
  end

  describe "upload-pack process" do
    test "advertises refs, runs a request, and handles protocol headers" do
      context = mirror_context!()
      sha = git_sha!(context.cache_path)
      body = pkt_line("want #{sha} multi_ack_detailed side-band-64k ofs-delta\n") <> "0000" <> pkt_line("done\n")

      assert {:ok, advertisement} = UploadPack.advertise(context.cache_path, nil)
      assert advertisement =~ "0000"
      assert advertisement =~ "# service=git-upload-pack\n"
      assert advertisement =~ "refs/heads/main"

      assert {:ok, v2} = UploadPack.advertise(context.cache_path, "version=2")
      assert v2 =~ "version 2"

      assert {:ok, result} = UploadPack.result(context.cache_path, body, nil)
      assert result =~ "NAK"

      assert {:error, {:git_upload_pack_failed, status}} = UploadPack.result(context.cache_path, "not a pkt-line", nil)
      refute status == 0
    end

    test "times out and reports a missing git, FIFO or shell" do
      context = mirror_context!()
      tmp = Path.join(System.tmp_dir!(), "symphony-git-mirror-fake-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      fake_git =
        write_script!(tmp, "git", """
        #!/bin/sh
        if [ "$FAKE_GIT_MODE" = "sleep" ]; then sleep 5; fi
        if [ "$FAKE_GIT_MODE" = "fail" ]; then exit 42; fi
        echo fake
        """)

      _ = fake_git

      with_path!(path_with_system(tmp), fn ->
        System.put_env("FAKE_GIT_MODE", "sleep")
        assert {:error, :timeout} = UploadPack.advertise(context.cache_path, nil, 50)

        System.put_env("FAKE_GIT_MODE", "fail")
        assert {:error, {:git_upload_pack_failed, 42}} = UploadPack.result(context.cache_path, "", nil, 1_000)

        # The fake child exits without reading; a large body makes the FIFO
        # writer see a broken pipe, which the writer turns into an error.
        assert {:error, {:git_upload_pack_failed, 42}} =
                 UploadPack.result(context.cache_path, :binary.copy("x", 1_000_000), nil, 1_000)
      end)

      System.delete_env("FAKE_GIT_MODE")

      empty = Path.join(tmp, "empty")
      File.mkdir_p!(empty)
      with_path!(empty, fn -> assert {:error, :git_not_found} = UploadPack.advertise(context.cache_path, nil) end)

      write_script!(tmp, "mkfifo", "#!/bin/sh\nexit 7\n")
      with_path!(tmp, fn -> assert {:error, {:fifo_failed, 7}} = UploadPack.advertise(context.cache_path, nil) end)

      File.rm!(Path.join(tmp, "mkfifo"))
      write_script!(tmp, "mkfifo", "#!/bin/sh\nexit 0\n")
      with_path!(tmp, fn -> assert {:error, :shell_not_found} = UploadPack.advertise(context.cache_path, nil) end)
    end
  end

  describe "HTTP endpoint" do
    test "clones and fetches through the mirror with protocol v0 and v2" do
      context = mirror_context!()
      endpoint = start_mirror_endpoint!(context)
      token = RunToken.sign(context.run_id, 1)

      for version <- [0, 2] do
        destination = Path.join(context.root, "clone-v#{version}")
        url = clone_url(context, endpoint, token)

        {output, status} =
          System.cmd("git", ["-c", "protocol.version=#{version}", "clone", "--quiet", url, destination],
            stderr_to_stdout: true,
            env: [{"GIT_TERMINAL_PROMPT", "0"}]
          )

        assert status == 0, output
        assert File.read!(Path.join(destination, "README.md")) == "base\n"
      end

      destination = Path.join(context.root, "clone-v2")
      commit_file!(context.agent_repo, "README.md", "next\n", "next")
      System.cmd("git", ["-C", context.agent_repo, "push", "-q", "origin", "main"])
      # The production cache sync updates local branches, which is what the
      # mirror advertises; a bare fetch alone would leave refs/heads/main behind.
      File.write!(Path.join([context.cache_path, ".git", "symphony-fetched-at"]), "0")
      assert :ok = Workspace.refresh_repo_cache(context.repo.route, context.settings)

      {fetch_output, fetch_status} =
        System.cmd("git", ["-C", destination, "fetch", "--quiet", "origin"], stderr_to_stdout: true)

      assert fetch_status == 0, fetch_output
      {upstream, 0} = System.cmd("git", ["-C", destination, "rev-parse", "origin/main"])
      {source, 0} = System.cmd("git", ["-C", context.agent_repo, "rev-parse", "main"])
      assert upstream == source
    end

    test "authenticates with bearer and basic credentials and fences stale epochs" do
      context = mirror_context!()
      endpoint = start_mirror_endpoint!(context)
      token = RunToken.sign(context.run_id, 1)
      info_url = info_refs_url(context, endpoint)

      assert {:ok, %{status: 200}} = Req.get(info_url, headers: [{"authorization", "Bearer #{token}"}], retry: false)

      basic = Base.encode64("x-access-token:#{token}")
      assert {:ok, %{status: 200}} = Req.get(info_url, headers: [{"authorization", "Basic #{basic}"}], retry: false)

      assert {:ok, %{status: 401}} = Req.get(info_url, retry: false)
      assert {:ok, %{status: 401}} = Req.get(info_url, headers: [{"authorization", "Bearer wrong"}], retry: false)
      assert {:ok, %{status: 401}} = Req.get(info_url, headers: [{"authorization", "Basic not-base64"}], retry: false)
      assert {:ok, %{status: 401}} = Req.get(info_url, headers: [{"authorization", "Basic #{Base.encode64("nocolon")}"}], retry: false)
      assert {:ok, %{status: 401}} = Req.get(info_url, headers: [{"authorization", "Basic #{Base.encode64("user:")}"}], retry: false)
      assert {:ok, %{status: 401}} = Req.get(info_url, headers: [{"authorization", "Digest value"}], retry: false)

      Support.record_run!("issue-1", context.run_id, epoch: 2, project_slug: "project-a")
      assert {:ok, %{status: 409}} = Req.get(info_url, headers: [{"authorization", "Bearer #{token}"}], retry: false)
    end

    test "refuses receive-pack and rejects unknown or traversing repos" do
      context = mirror_context!(two_repos: true)
      endpoint = start_mirror_endpoint!(context)
      token = RunToken.sign(context.run_id, 1)
      headers = [{"authorization", "Bearer #{token}"}]

      receive_url = "#{endpoint.url}/git/#{context.run_id}/#{context.repo_key}/git-receive-pack"
      assert {:ok, %{status: 403}} = Req.post(receive_url, headers: headers, retry: false)

      receive_info = info_refs_url(context, endpoint) |> String.replace("git-upload-pack", "git-receive-pack")
      assert {:ok, %{status: 403}} = Req.get(receive_info, headers: headers, retry: false)

      unknown = "#{endpoint.url}/git/#{context.run_id}/unknown/info/refs?service=git-upload-pack"
      assert {:ok, %{status: 404}} = Req.get(unknown, headers: headers, retry: false)

      other = "#{endpoint.url}/git/#{context.run_id}/#{context.other_repo_source.source.cache_key}/info/refs?service=git-upload-pack"
      assert {:ok, %{status: 403}} = Req.get(other, headers: headers, retry: false)

      other = "#{endpoint.url}/git/#{context.run_id}/#{context.other_repo_source.cache_key}/info/refs?service=git-upload-pack"
      assert {:ok, %{status: 403}} = Req.get(other, headers: headers, retry: false)

      for repo <- ["%2e%2e", "..%2f..%2fetc", "a%2Fb", String.duplicate("a", 200)] do
        url = "#{endpoint.url}/git/#{context.run_id}/#{repo}/info/refs?service=git-upload-pack"
        assert {:ok, %{status: status}} = Req.get(url, headers: headers, retry: false)
        assert status in [400, 404]
      end

      unsupported = "#{endpoint.url}/git/#{context.run_id}/#{context.repo_key}/info/refs?service=nope"
      assert {:ok, %{status: 400}} = Req.get(unsupported, headers: headers, retry: false)
    end

    test "accepts gzip bodies and enforces the body and encoding limits" do
      context = mirror_context!()
      endpoint = start_mirror_endpoint!(context)
      token = RunToken.sign(context.run_id, 1)
      url = upload_pack_url(context, endpoint)
      headers = [{"authorization", "Bearer #{token}"}, {"content-type", "application/x-git-upload-pack-request"}]

      sha = git_sha!(context.cache_path)
      body = pkt_line("want #{sha} multi_ack_detailed side-band-64k ofs-delta\n") <> "0000" <> pkt_line("done\n")

      assert {:ok, %{status: 200, body: result}} =
               Req.post(url, headers: [{"content-encoding", "gzip"} | headers], body: :zlib.gzip(body), retry: false)

      assert result =~ "NAK"

      assert {:ok, %{status: 400}} =
               Req.post(url, headers: [{"content-encoding", "gzip"} | headers], body: "not gzip", retry: false)

      assert {:ok, %{status: 415}} =
               Req.post(url, headers: [{"content-encoding", "br"} | headers], body: body, retry: false)

      assert {:ok, %{status: 413}} =
               Req.post(url, headers: headers, body: :binary.copy("x", UploadPack.max_body_bytes() + 1), retry: false)

      assert {:ok, %{status: 413}} =
               Req.post(url, headers: headers, body: :binary.copy("x", UploadPack.max_body_bytes() + 2), retry: false)

      assert {:ok, %{status: 413}} =
               Req.post(url, headers: headers, body: :binary.copy("x", UploadPack.max_body_bytes() + 2), retry: false)
    end

    test "returns 500 when the cache is not a git repository" do
      context = mirror_context!()
      endpoint = start_mirror_endpoint!(context)
      token = RunToken.sign(context.run_id, 1)
      headers = [{"authorization", "Bearer #{token}"}]

      File.rm_rf!(context.cache_path)
      File.mkdir_p!(Path.join(context.cache_path, ".git"))
      File.write!(Path.join([context.cache_path, ".git", "symphony-fetched-at"]), "#{System.system_time(:second)}\n")

      assert {:ok, %{status: 500}} = Req.get(info_refs_url(context, endpoint), headers: headers, retry: false)
      assert {:ok, %{status: 500}} = Req.post(upload_pack_url(context, endpoint), headers: headers, body: "", retry: false)
    end
  end

  defp mirror_context!(opts \\ []) do
    root = Path.join(System.tmp_dir!(), "symphony-git-mirror-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    origin = Path.join(root, "origin.git")
    agent_repo = Path.join(root, "agent")
    workspace_root = Path.join(root, "workspaces")
    init_bare_origin!(origin, agent_repo, "base\n")

    projects = [%{slug: "project-a", repo: origin}, %{slug: "project-c", repo: nil}]

    other =
      if Keyword.get(opts, :two_repos, false) do
        other_origin = Path.join(root, "other.git")
        other_agent = Path.join(root, "other-agent")
        init_bare_origin!(other_origin, other_agent, "other\n")
        [%{slug: "project-b", repo: other_origin}]
      else
        []
      end

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_projects: projects ++ other ++ [%{slug: "no-repo"}],
      workspace_root: workspace_root
    )

    issue = %Issue{id: "issue-1", identifier: "PI-1", project_slug: "project-a"}
    assert {:ok, _workspace} = Workspace.create_for_issue(issue)

    settings = Config.settings!()
    repo_source = Config.project_repo_source_for_issue(issue, settings)
    route = Config.linear_project_route(issue, settings)
    cache_path = Workspace.repo_cache_path(Config.workspace_root_for_route(route, settings), repo_source)
    {:ok, repo} = GitMirror.resolve(repo_source.cache_key, settings)

    other_repo_source =
      if other == [] do
        nil
      else
        source = Config.repo_source(hd(other).repo)
        other_route = Enum.find(Config.linear_project_routes(settings), &(&1.slug == "project-b"))

        %{cache_key: source.cache_key}
        |> Map.put(:source, source)
        |> Map.put(:route, other_route)
        |> Map.put(:cache_path, Workspace.repo_cache_path(Config.workspace_root_for_route(other_route, settings), source))
        |> tap(fn _ ->
          assert {:ok, _workspace} =
                   Workspace.create_for_issue(%Issue{identifier: "PI-2", project_slug: "project-b"})
        end)
      end

    Support.setup_runs!(root)
    Support.record_run!("issue-1", "run-1", project_slug: "project-a")
    _ = RunRegistry.load()

    %{
      root: root,
      origin: origin,
      agent_repo: agent_repo,
      workspace_root: workspace_root,
      issue: issue,
      settings: settings,
      repo_source: repo_source,
      repo_key: repo_source.cache_key,
      cache_path: cache_path,
      repo: repo,
      other_repo_source: other_repo_source,
      other_cache_path: if(other_repo_source, do: other_repo_source.cache_path),
      run_id: "run-1"
    }
  end

  defp start_mirror_endpoint!(context) do
    endpoint = Support.start_endpoint!()
    Process.put(:mirror_endpoint, endpoint)
    _ = context
    endpoint
  end

  defp clone_url(context, endpoint, token) do
    spec = %RunSpec{
      run_id: context.run_id,
      epoch: 1,
      issue: context.issue,
      controller_url: endpoint.url,
      token: token,
      git_mirror_url: "#{endpoint.url}/git/#{context.run_id}/#{context.repo_key}"
    }

    assert url = GitMirror.clone_url(spec)
    url
  end

  defp info_refs_url(context, endpoint) do
    "#{endpoint.url}/git/#{context.run_id}/#{context.repo_key}/info/refs?service=git-upload-pack"
  end

  defp upload_pack_url(context, endpoint) do
    "#{endpoint.url}/git/#{context.run_id}/#{context.repo_key}/git-upload-pack"
  end

  defp refresh_loop(parent) do
    receive do
      {:"$gen_cast", :refresh_now} ->
        send(parent, :refreshed)
        refresh_loop(parent)
    end
  end

  defp with_path!(path, fun) do
    previous = System.get_env("PATH")
    System.put_env("PATH", path)
    on_exit(fn -> restore_path(previous) end)

    try do
      fun.()
    after
      restore_path(previous)
    end
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)

  defp path_with_system(dir) do
    [dir, System.get_env("PATH")] |> Enum.reject(&is_nil/1) |> Enum.join(":")
  end

  defp write_script!(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    File.chmod!(path, 0o755)
    path
  end

  defp pkt_line(payload) do
    length = byte_size(payload) + 4
    (length |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase()) <> payload
  end

  defp git_sha!(repo) do
    {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "main"])
    String.trim(sha)
  end

  defp init_bare_origin!(origin, agent_repo, readme_contents) do
    System.cmd("git", ["init", "--bare", "-q", "-b", "main", origin])
    File.mkdir_p!(agent_repo)
    File.write!(Path.join(agent_repo, "README.md"), readme_contents)
    System.cmd("git", ["-C", agent_repo, "init", "-q", "-b", "main"])
    System.cmd("git", ["-C", agent_repo, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", agent_repo, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", agent_repo, "add", "README.md"])
    System.cmd("git", ["-C", agent_repo, "commit", "-q", "-m", "initial"])
    System.cmd("git", ["-C", agent_repo, "remote", "add", "origin", origin])
    System.cmd("git", ["-C", agent_repo, "push", "-q", "-u", "origin", "main"])
    :ok
  end

  defp commit_file!(repo, relative_path, contents, message) do
    File.write!(Path.join(repo, relative_path), contents)
    System.cmd("git", ["-C", repo, "add", relative_path])
    System.cmd("git", ["-C", repo, "commit", "-q", "-m", message])
  end
end
