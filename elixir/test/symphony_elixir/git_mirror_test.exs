defmodule SymphonyElixir.GitMirrorTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.{GitMirror, RunRegistry, RunSpec, RunToken}
  alias SymphonyElixir.GitMirror.{Limiter, UploadPack}
  alias SymphonyElixir.RunnerTestSupport, as: Support

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
    end

    test "with several repos a run reads only its own project's repo" do
      context = mirror_context!(two_repos: true)
      settings = Config.settings!()
      repo = context.repo

      assert :ok = GitMirror.authorize(%{project_slug: "project-a", identifier: "PI-1"}, repo, settings)
      assert :ok = GitMirror.authorize(%{"project_slug" => "project-a"}, repo, settings)
      assert {:error, :forbidden} = GitMirror.authorize(%{project_slug: "project-b", identifier: "PI-2"}, repo, settings)
      # A slug whose route has no repo, or no route at all, is denied.
      assert {:error, :forbidden} = GitMirror.authorize(%{project_slug: "no-repo"}, repo, settings)
      assert {:error, :forbidden} = GitMirror.authorize(%{project_slug: "unknown-project"}, repo, settings)
      # No project metadata with more than one repo configured is ambiguous.
      assert {:error, :forbidden} = GitMirror.authorize(%{identifier: "PI-3"}, repo, settings)
      assert {:error, :forbidden} = GitMirror.authorize(%{project_slug: " "}, repo, settings)
      assert {:error, :forbidden} = GitMirror.authorize(nil, repo, settings)

      assert {:ok, %{repo_key: key}} = GitMirror.run_repo("project-b", settings)
      assert key == context.other_repo_source.cache_key
      assert :none = GitMirror.run_repo(nil, settings)
      assert :none = GitMirror.run_repo("no-repo", settings)
    end

    test "with a single repo a run without project metadata may read it" do
      context = mirror_context!()
      settings = Config.settings!()

      assert :ok = GitMirror.authorize(%{identifier: "PI-3"}, context.repo, settings)
      assert :ok = GitMirror.authorize(nil, context.repo, settings)
      # A project slug is still checked, even with one repo.
      assert {:error, :forbidden} = GitMirror.authorize(%{project_slug: "project-c"}, context.repo, settings)
      assert {:error, :forbidden} = GitMirror.authorize(%{project_slug: "unknown-project"}, context.repo, settings)
      assert {:ok, %{repo_key: key}} = GitMirror.run_repo(nil, settings)
      assert key == context.repo_key
    end

    test "the spec's mirror uses the same lookup as authorization" do
      context = mirror_context!()
      settings = Config.settings!()
      url = GitMirror.mirror_url("http://controller:4000/", "run-1", context.repo_source)
      assert url == "http://controller:4000/git/run-1/#{context.repo_key}"

      spec = %RunSpec{run_id: "run-1", epoch: 1, issue: context.issue, controller_url: "http://controller:4000", token: "t"}

      # The target branch comes from the cache's origin/HEAD.
      assert GitMirror.mirror_for(spec, settings) == %{url: url, target_branch: "main"}
      # An issue without a project slug gets the single repo, as it may read it.
      assert %{url: ^url} = GitMirror.mirror_for(%{spec | issue: %{id: "none"}}, settings)
      refute GitMirror.mirror_for(%{spec | issue: %{project_slug: "project-c"}}, settings)
      refute GitMirror.mirror_for(%{spec | controller_url: nil}, settings)

      assert %RunSpec{git_mirror_url: ^url, target_branch: "main"} = RunSpec.attach_git_mirror(spec, settings)

      kept = %{spec | git_mirror_url: "http://elsewhere/git", target_branch: "develop"}
      assert RunSpec.attach_git_mirror(kept, settings) == kept

      {_output, 0} = System.cmd("git", ["-C", context.cache_path, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD"])
      assert GitMirror.mirror_for(spec, settings) == %{url: url, target_branch: nil}

      File.rm_rf!(context.cache_path)
      refute GitMirror.mirror_for(spec, settings)
      assert RunSpec.attach_git_mirror(spec, settings) == spec
    end

    test "a project's configured default branch is the spec's target branch" do
      context = mirror_context!(default_branch: "main")
      spec = %RunSpec{run_id: "run-1", epoch: 1, issue: context.issue, controller_url: "http://c", token: "t"}

      {_output, 0} = System.cmd("git", ["-C", context.cache_path, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD"])
      assert %{target_branch: "main"} = GitMirror.mirror_for(spec, Config.settings!())
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

    test "git_mirror config has defaults and rejects non-positive values" do
      _context = mirror_context!()
      assert %{max_concurrent: 8, idle_timeout_ms: 60_000} = Config.settings!().git_mirror

      write_workflow_file!(Workflow.workflow_file_path(), git_mirror: %{max_concurrent: 0})
      assert {:error, _reason} = Config.settings()

      write_workflow_file!(Workflow.workflow_file_path(), git_mirror: %{max_concurrent: 2, idle_timeout_ms: 500})
      assert %{max_concurrent: 2, idle_timeout_ms: 500} = Config.settings!().git_mirror
    end
  end

  describe "cloning a workspace from the mirror" do
    test "builds the workspace like the cache clone and resumes the issue branch" do
      context = mirror_context!()
      endpoint = Support.start_endpoint!()
      token = RunToken.sign(context.run_id, 1)
      spec = mirror_spec(context, endpoint, token)
      assert spec.target_branch == "main"

      for version <- [0, 2] do
        workspace = Path.join(context.root, "runner-v#{version}")
        {output, status} = run_clone(spec, workspace, protocol_version: version)

        assert status == 0, output
        assert File.read!(Path.join(workspace, "README.md")) == "base\n"
        assert current_branch(workspace) == "symphony/PI-1"
        assert {_output, status} = System.cmd("git", ["-C", workspace, "rev-parse", "--abbrev-ref", "@{upstream}"], stderr_to_stdout: true)
        refute status == 0
        # Without an origin URL the mirror is origin; the token is in no file.
        assert git_config(workspace, "remote.origin.url") == spec.git_mirror_url
        refute File.read!(Path.join([workspace, ".git", "config"])) =~ token
      end

      # A previous run pushed the issue branch; the cache picks it up on its
      # next fetch and a new workspace resumes it with an upstream.
      System.cmd("git", ["-C", context.agent_repo, "checkout", "-q", "-b", "symphony/PI-1"])
      commit_file!(context.agent_repo, "README.md", "work in progress\n", "wip")
      {_output, 0} = System.cmd("git", ["-C", context.agent_repo, "push", "-q", "origin", "symphony/PI-1"])
      File.write!(Path.join([context.cache_path, ".git", "symphony-fetched-at"]), "0")
      assert :ok = Workspace.refresh_repo_cache(context.repo.route, context.settings)

      resumed = Path.join(context.root, "runner-resumed")
      {output, status} = run_clone(spec, resumed, origin_url: context.origin)
      assert status == 0, output
      assert File.read!(Path.join(resumed, "README.md")) == "work in progress\n"
      assert current_branch(resumed) == "symphony/PI-1"
      {upstream, 0} = System.cmd("git", ["-C", resumed, "rev-parse", "--abbrev-ref", "@{upstream}"])
      assert String.trim(upstream) == "origin/symphony/PI-1"
      assert git_config(resumed, "remote.origin.url") == context.origin
      assert git_config(resumed, "push.default") == "current"

      # Another issue starts from the target branch, also without a target
      # branch in the spec (main/master fallback).
      other_spec = %{spec | issue: %{spec.issue | identifier: "PI-9"}, target_branch: nil}
      fresh = Path.join(context.root, "runner-fresh")
      {output, status} = run_clone(other_spec, fresh)
      assert status == 0, output
      assert File.read!(Path.join(fresh, "README.md")) == "base\n"
      assert current_branch(fresh) == "symphony/PI-9"

      missing = Path.join(context.root, "runner-missing")
      {output, status} = run_clone(%{other_spec | target_branch: "nope"}, missing)
      assert status == 43
      assert output =~ "Target branch not found on the mirror: nope"

      assert {:error, :no_git_mirror} = GitMirror.clone_commands(%{spec | git_mirror_url: nil}, fresh)
      assert {:error, :no_git_mirror} = GitMirror.clone_commands(%{spec | token: nil}, fresh)
    end

    test "a cache refresh is visible to a later fetch through the mirror" do
      context = mirror_context!()
      endpoint = Support.start_endpoint!()
      spec = mirror_spec(context, endpoint, RunToken.sign(context.run_id, 1))
      workspace = Path.join(context.root, "runner")
      {output, 0} = run_clone(spec, workspace)
      assert output == ""

      commit_file!(context.agent_repo, "README.md", "next\n", "next")
      System.cmd("git", ["-C", context.agent_repo, "push", "-q", "origin", "main"])
      File.write!(Path.join([context.cache_path, ".git", "symphony-fetched-at"]), "0")
      assert :ok = Workspace.refresh_repo_cache(context.repo.route, context.settings)

      {:ok, %{env: env}} = GitMirror.clone_commands(spec, workspace)
      {fetch_output, fetch_status} = System.cmd("git", ["-C", workspace, "fetch", "--quiet", "origin"], env: env, stderr_to_stdout: true)
      assert fetch_status == 0, fetch_output
      {upstream, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "origin/main"])
      {source, 0} = System.cmd("git", ["-C", context.agent_repo, "rev-parse", "main"])
      assert upstream == source
    end
  end

  describe "a runner's workspace from the mirror" do
    test "a runner without the repo cache clones from the mirror and pushes to the real remote" do
      context = mirror_context!()
      endpoint = Support.start_endpoint!()
      token = RunToken.sign(context.run_id, 1)
      # No target branch in the spec: the route's (none) then main/master.
      spec = %{mirror_spec(context, endpoint, token) | target_branch: nil}
      runner_root = Path.join(Config.workspace_root_for_route(context.repo.route, context.settings), "runner")

      log =
        capture_log(fn ->
          assert {:ok, workspace} =
                   Workspace.create_for_issue(context.issue, nil, settings: context.settings, workspace_root: runner_root, git_mirror: spec)

          send(self(), {:workspace, workspace})
        end)

      assert_received {:workspace, workspace}
      assert log =~ "Cloning workspace repo from the git mirror"
      refute File.dir?(Workspace.repo_cache_path(runner_root, context.repo_source))
      assert File.read!(Path.join(workspace, "README.md")) == "base\n"
      assert current_branch(workspace) == "symphony/PI-1"
      assert git_config(workspace, "remote.origin.url") == context.repo_source.clone_url
      refute File.read!(Path.join([workspace, ".git", "config"])) =~ token

      # The workspace exists now: a later run reuses it without cloning.
      log =
        capture_log(fn ->
          assert {:ok, ^workspace} =
                   Workspace.create_for_issue(context.issue, nil, settings: context.settings, workspace_root: runner_root, git_mirror: spec)
        end)

      refute log =~ "from the git mirror"
    end

    test "where the cache exists, or the mirror serves another repo, the workspace is cloned as before" do
      context = mirror_context!()
      endpoint = Support.start_endpoint!()
      spec = mirror_spec(context, endpoint, RunToken.sign(context.run_id, 1))
      issue = %{context.issue | identifier: "PI-7"}

      log =
        capture_log(fn ->
          assert {:ok, _workspace} =
                   Workspace.create_for_issue(issue, nil, settings: context.settings, git_mirror: spec)

          other = %{spec | git_mirror_url: spec.git_mirror_url <> "-other"}
          runner_root = Path.join(Config.workspace_root_for_route(context.repo.route, context.settings), "runner-other")

          opts = [settings: context.settings, workspace_root: runner_root, git_mirror: other]
          assert {:ok, _workspace} = Workspace.create_for_issue(%{issue | identifier: "PI-8"}, nil, opts)
        end)

      refute log =~ "from the git mirror"
    end

    test "a failed or timed-out mirror clone fails the workspace and discards it" do
      context = mirror_context!()
      endpoint = Support.start_endpoint!()
      spec = %{mirror_spec(context, endpoint, RunToken.sign(context.run_id, 1)) | target_branch: "nope", issue: nil}
      runner_root = Path.join(Config.workspace_root_for_route(context.repo.route, context.settings), "runner")
      workspace = Path.join(runner_root, "PI-1")

      log =
        capture_log(fn ->
          assert {:error, {:workspace_mirror_clone_failed, _repo, 43, output}} =
                   Workspace.create_for_issue(context.issue, nil, settings: context.settings, workspace_root: runner_root, git_mirror: spec)

          assert output =~ "Target branch not found on the mirror: nope"
          refute File.exists?(workspace)

          settings = %{context.settings | hooks: %{context.settings.hooks | timeout_ms: 1}}

          assert {:error, {:workspace_mirror_clone_timeout, _repo, 1}} =
                   Workspace.create_for_issue(context.issue, nil, settings: settings, workspace_root: runner_root, git_mirror: spec)
        end)

      assert log =~ "Workspace clone from the git mirror failed"
      assert log =~ "Workspace clone from the git mirror timed out"
    end
  end

  describe "upload-pack process" do
    test "advertises refs and answers a request" do
      context = mirror_context!()
      sha = git_sha!(context.cache_path)

      assert {:ok, advertisement} = collect(context.cache_path, :advertise, nil)
      assert advertisement =~ "refs/remotes/origin/main"
      assert UploadPack.service_header() == "001e# service=git-upload-pack\n0000"

      assert {:ok, v2} = collect(context.cache_path, :advertise, "version=2")
      assert v2 =~ "version 2"
      assert {:ok, _ignored} = collect(context.cache_path, :advertise, "bad protocol; rm -rf")

      request = request_file!(context, want_body(sha))
      assert {:ok, result} = collect(context.cache_path, {:request, request}, nil)
      assert result =~ "NAK"

      bad = request_file!(context, "not a pkt-line")
      assert {:error, {:git_upload_pack_failed, status}, _acc} = UploadPack.stream(context.cache_path, {:request, bad}, nil, [], [], &cont/2)
      refute status == 0
    end

    test "streams a large pack chunk by chunk" do
      context = mirror_context!()
      sha = push_large_commit!(context, 6_000_000)
      request = request_file!(context, want_body(sha))

      assert {:ok, sizes} =
               UploadPack.stream(context.cache_path, {:request, request}, nil, [], [], fn chunk, sizes ->
                 {:cont, [byte_size(chunk) | sizes]}
               end)

      assert Enum.sum(sizes) > 6_000_000
      assert length(sizes) > 10
      assert Enum.max(sizes) <= 1_048_576
    end

    test "kills git on an idle timeout, a halt, a raising callback or a dead caller" do
      context = mirror_context!()
      tmp = fake_git_dir!(context)

      with_path!(path_with_system(tmp), fn ->
        # `ready` writes once after recording its pid, so the idle timeout
        # only starts counting once the pid is known.
        System.put_env("FAKE_GIT_MODE", "ready")
        assert {:error, :timeout, ["ready\n"]} = UploadPack.stream(context.cache_path, :advertise, nil, [idle_timeout_ms: 5_000], [], &cont/2)
        assert_dead!(fake_pid!(tmp))

        System.put_env("FAKE_GIT_MODE", "spew")
        halt = fn _chunk, acc -> {:halt, [:halted | acc]} end
        assert {:error, :halted, [:halted]} = UploadPack.stream(context.cache_path, :advertise, nil, [], [], halt)
        assert_dead!(fake_pid!(tmp))

        assert_raise RuntimeError, "boom", fn ->
          UploadPack.stream(context.cache_path, :advertise, nil, [], [], fn _chunk, _acc -> raise "boom" end)
        end

        assert_dead!(fake_pid!(tmp))

        System.put_env("FAKE_GIT_MODE", "sleep")
        caller = spawn(fn -> UploadPack.stream(context.cache_path, :advertise, nil, [], [], &cont/2) end)
        pid = fake_pid!(tmp)
        assert alive?(pid)
        Process.exit(caller, :kill)
        assert_dead!(pid)

        System.put_env("FAKE_GIT_MODE", "fail")
        assert {:error, {:git_upload_pack_failed, 42}, []} = UploadPack.stream(context.cache_path, :advertise, nil, [], [], &cont/2)
      end)
    end

    test "reports a missing git or shell" do
      context = mirror_context!()
      tmp = fake_git_dir!(context)
      empty = Path.join(tmp, "empty")
      File.mkdir_p!(empty)

      with_path!(empty, fn ->
        assert {:error, :git_not_found, :acc} = UploadPack.stream(context.cache_path, :advertise, nil, [], :acc, &cont/2)
      end)

      # Only the fake git is on PATH, so there is no `sh`.
      with_path!(tmp, fn ->
        assert {:error, :shell_not_found, :acc} = UploadPack.stream(context.cache_path, :advertise, nil, [], :acc, &cont/2)
      end)
    end

    test "request files are owner-only, in a fresh owner-only directory" do
      context = mirror_context!()

      assert {:ok, dir, path, io} = UploadPack.create_request_file(context.root)
      assert {:ok, other_dir, _other_path, other_io} = UploadPack.create_request_file(context.root)
      refute dir == other_dir
      assert Path.dirname(path) == dir
      assert :ok = :file.write(io, "body")
      :ok = :file.close(io)
      :ok = :file.close(other_io)

      assert File.read!(path) == "body"
      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

      assert :ok = UploadPack.remove_request_dir(dir)
      refute File.exists?(dir)
      assert {:error, :enoent} = UploadPack.create_request_file(Path.join(context.root, "missing"))
    end
  end

  describe "limiter" do
    test "caps holders, frees slots on release and when a holder dies" do
      name = Module.concat(__MODULE__, "Limiter#{System.unique_integer([:positive])}")
      start_supervised!({Limiter, name: name})

      assert {:ok, first} = Limiter.acquire(2, name)
      assert {:ok, _second} = Limiter.acquire(2, name)
      assert :full = Limiter.acquire(2, name)
      assert Limiter.in_use(name) == 2

      assert :ok = Limiter.release(first, name)
      assert :ok = Limiter.release(make_ref(), name)
      assert Limiter.in_use(name) == 1

      parent = self()

      holder =
        spawn(fn ->
          send(parent, {:held, Limiter.acquire(2, name)})
          Process.sleep(:infinity)
        end)

      assert_receive {:held, {:ok, _slot}}
      assert :full = Limiter.acquire(2, name)
      Process.exit(holder, :kill)
      wait_until(fn -> Limiter.in_use(name) == 1 end)
      assert {:ok, _third} = Limiter.acquire(2, name)
    end
  end

  describe "HTTP endpoint" do
    test "authenticates with bearer and basic credentials and fences stale epochs" do
      context = mirror_context!()
      endpoint = Support.start_endpoint!()
      token = RunToken.sign(context.run_id, 1)
      info_url = info_refs_url(context, endpoint)

      assert {:ok, %{status: 200, body: body}} = Req.get(info_url, headers: [{"authorization", "Bearer #{token}"}], retry: false)
      assert String.starts_with?(body, UploadPack.service_header())

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

    test "refuses receive-pack, other projects' repos and unknown or traversing repos" do
      context = mirror_context!(two_repos: true)
      endpoint = Support.start_endpoint!()
      token = RunToken.sign(context.run_id, 1)
      headers = [{"authorization", "Bearer #{token}"}]

      receive_url = "#{endpoint.url}/git/#{context.run_id}/#{context.repo_key}/git-receive-pack"
      assert {:ok, %{status: 403}} = Req.post(receive_url, headers: headers, retry: false)

      receive_info = info_refs_url(context, endpoint) |> String.replace("git-upload-pack", "git-receive-pack")
      assert {:ok, %{status: 403}} = Req.get(receive_info, headers: headers, retry: false)

      unknown = "#{endpoint.url}/git/#{context.run_id}/unknown/info/refs?service=git-upload-pack"
      assert {:ok, %{status: 404}} = Req.get(unknown, headers: headers, retry: false)

      other = "#{endpoint.url}/git/#{context.run_id}/#{context.other_repo_source.cache_key}/info/refs?service=git-upload-pack"
      assert {:ok, %{status: 403, body: "repo_forbidden"}} = Req.get(other, headers: headers, retry: false)

      # A run without a project slug may not pick among several repos.
      Support.record_run!("issue-9", "run-9", project_slug: nil)
      no_slug = "#{endpoint.url}/git/run-9/#{context.repo_key}/info/refs?service=git-upload-pack"
      assert {:ok, %{status: 403}} = Req.get(no_slug, headers: [{"authorization", "Bearer #{RunToken.sign("run-9", 1)}"}], retry: false)

      for repo <- ["%2e%2e", "..%2f..%2fetc", "a%2Fb", String.duplicate("a", 200)] do
        url = "#{endpoint.url}/git/#{context.run_id}/#{repo}/info/refs?service=git-upload-pack"
        assert {:ok, %{status: status}} = Req.get(url, headers: headers, retry: false)
        assert status in [400, 404]
      end

      unsupported = "#{endpoint.url}/git/#{context.run_id}/#{context.repo_key}/info/refs?service=nope"
      assert {:ok, %{status: 400}} = Req.get(unsupported, headers: headers, retry: false)
    end

    test "accepts gzip bodies and enforces the body, inflated size and encoding limits" do
      context = mirror_context!()
      endpoint = Support.start_endpoint!()
      url = upload_pack_url(context, endpoint)
      headers = request_headers(context)
      gzip = [{"content-encoding", "gzip"} | headers]
      body = want_body(git_sha!(context.cache_path))
      max = UploadPack.max_body_bytes()

      assert {:ok, %{status: 200, body: result}} = Req.post(url, headers: gzip, body: :zlib.gzip(body), retry: false)
      assert result =~ "NAK"

      assert {:ok, %{status: 200, body: result}} = Req.post(url, headers: [{"content-encoding", "identity"} | headers], body: body, retry: false)
      assert result =~ "NAK"

      assert {:ok, %{status: 400, body: "invalid_gzip"}} = Req.post(url, headers: gzip, body: "not gzip", retry: false)

      # A gzip stream that never ends is as invalid as a corrupt one.
      truncated = binary_part(:zlib.gzip(body), 0, 20)
      assert {:ok, %{status: 400, body: "invalid_gzip"}} = Req.post(url, headers: gzip, body: truncated, retry: false)

      assert {:ok, %{status: 415}} = Req.post(url, headers: [{"content-encoding", "br"} | headers], body: body, retry: false)

      assert {:ok, %{status: 413}} = Req.post(url, headers: headers, body: :binary.copy("x", max + 1), retry: false)

      # A gzip bomb: a few KB that inflate past the limit is refused while
      # inflating, without ever holding the inflated body.
      bomb = :zlib.gzip(:binary.copy(<<0>>, max * 4))
      assert byte_size(bomb) < 100_000
      assert {:ok, %{status: 413, body: "request_too_large"}} = Req.post(url, headers: gzip, body: bomb, retry: false)

      # A compressed body larger than the limit is refused on its raw size.
      noise = :zlib.gzip(:crypto.strong_rand_bytes(max + 1024))
      assert {:ok, %{status: 413}} = Req.post(url, headers: gzip, body: noise, retry: false)

      # Several reads of a valid gzip body that git then rejects.
      junk = :zlib.gzip(:crypto.strong_rand_bytes(300_000))
      assert {:ok, %{status: 500, body: "git_failed"}} = Req.post(url, headers: gzip, body: junk, retry: false)
    end

    test "streams a large pack as a chunked response" do
      context = mirror_context!()
      endpoint = Support.start_endpoint!()
      sha = push_large_commit!(context, 6_000_000)

      collect_chunks = fn {:data, data}, {request, response} ->
        {:cont, {request, Req.Response.update_private(response, :chunks, [], &[byte_size(data) | &1])}}
      end

      assert {:ok, response} =
               Req.post(upload_pack_url(context, endpoint),
                 headers: request_headers(context),
                 body: want_body(sha),
                 into: collect_chunks,
                 retry: false
               )

      assert response.status == 200
      assert Req.Response.get_header(response, "transfer-encoding") == ["chunked"]
      chunks = Req.Response.get_private(response, :chunks)
      assert Enum.sum(chunks) > 6_000_000
      assert length(chunks) > 10
    end

    test "returns 503 with Retry-After when every upload-pack slot is taken" do
      context = mirror_context!(git_mirror: %{max_concurrent: 1})
      endpoint = Support.start_endpoint!()
      url = info_refs_url(context, endpoint)
      headers = request_headers(context)

      assert {:ok, slot} = Limiter.acquire(1)

      try do
        assert {:ok, %{status: 503, body: "busy"} = response} = Req.get(url, headers: headers, retry: false)
        assert Req.Response.get_header(response, "retry-after") == ["5"]
      after
        Limiter.release(slot)
      end

      assert {:ok, %{status: 200}} = Req.get(url, headers: headers, retry: false)
      assert Limiter.in_use() == 0
    end

    test "maps git failures to 500 before the response starts and cuts it short after" do
      context = mirror_context!(git_mirror: %{idle_timeout_ms: 5_000})
      endpoint = Support.start_endpoint!()
      tmp = fake_git_dir!(context)
      headers = request_headers(context)

      with_path!(path_with_system(tmp), fn ->
        System.put_env("FAKE_GIT_MODE", "sleep")
        assert {:ok, %{status: 500, body: "git_failed"}} = Req.get(info_refs_url(context, endpoint), headers: headers, retry: false)

        System.put_env("FAKE_GIT_MODE", "partial")
        assert {:ok, %{status: 200, body: body}} = Req.get(info_refs_url(context, endpoint), headers: headers, retry: false)
        assert body == UploadPack.service_header() <> "partial\n"

        System.put_env("FAKE_GIT_MODE", "silent")
        assert {:ok, %{status: 200, body: body}} = Req.get(info_refs_url(context, endpoint), headers: headers, retry: false)
        assert body == UploadPack.service_header()
        assert {:ok, %{status: 200, body: ""}} = Req.post(upload_pack_url(context, endpoint), headers: headers, body: "", retry: false)
      end)
    end

    test "kills git when the client disconnects mid-response" do
      context = mirror_context!()
      endpoint = Support.start_endpoint!()
      tmp = fake_git_dir!(context)
      token = RunToken.sign(context.run_id, 1)

      with_path!(path_with_system(tmp), fn ->
        System.put_env("FAKE_GIT_MODE", "spew")
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", endpoint.port, [:binary, active: false])

        request =
          "POST /git/#{context.run_id}/#{context.repo_key}/git-upload-pack HTTP/1.1\r\n" <>
            "host: 127.0.0.1\r\nauthorization: Bearer #{token}\r\ncontent-length: 0\r\n\r\n"

        :ok = :gen_tcp.send(socket, request)
        assert {:ok, "HTTP/1.1 200" <> _rest} = :gen_tcp.recv(socket, 0, 5_000)
        pid = fake_pid!(tmp)
        :ok = :gen_tcp.close(socket)
        assert_dead!(pid)
        wait_until(fn -> Limiter.in_use() == 0 end)
      end)
    end

    test "returns 500 when the cache is not a git repository or the request file fails" do
      context = mirror_context!()
      endpoint = Support.start_endpoint!()
      headers = request_headers(context)

      locked = Path.join(context.root, "locked-tmp")
      File.mkdir_p!(locked)
      File.chmod!(locked, 0o600)
      previous = System.get_env("TMPDIR")

      try do
        System.put_env("TMPDIR", locked)
        assert System.tmp_dir!() == locked
        assert {:ok, %{status: 500, body: "request_file_failed"}} = Req.post(upload_pack_url(context, endpoint), headers: headers, body: "", retry: false)
      after
        if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
        File.chmod!(locked, 0o700)
      end

      File.rm_rf!(context.cache_path)
      File.mkdir_p!(Path.join(context.cache_path, ".git"))
      File.write!(Path.join([context.cache_path, ".git", "symphony-fetched-at"]), "#{System.system_time(:second)}\n")

      assert {:ok, %{status: 500}} = Req.get(info_refs_url(context, endpoint), headers: headers, retry: false)
      assert {:ok, %{status: 500}} = Req.post(upload_pack_url(context, endpoint), headers: headers, body: "", retry: false)
    end
  end

  defp mirror_context!(opts \\ []) do
    root = Path.join(System.tmp_dir!(), "symphony-git-mirror-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    origin = Path.join(root, "origin.git")
    agent_repo = Path.join(root, "agent")
    workspace_root = Path.join(root, "workspaces")
    init_bare_origin!(origin, agent_repo, "base\n")

    project_a =
      case Keyword.get(opts, :default_branch) do
        nil -> %{slug: "project-a", repo: origin}
        branch -> %{slug: "project-a", repo: origin, default_branch: branch}
      end

    projects = [project_a, %{slug: "project-c", repo: nil}]

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
      workspace_root: workspace_root,
      git_mirror: Keyword.get(opts, :git_mirror)
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
        assert {:ok, _workspace} = Workspace.create_for_issue(%Issue{identifier: "PI-2", project_slug: "project-b"})

        %{
          cache_key: source.cache_key,
          cache_path: Workspace.repo_cache_path(Config.workspace_root_for_route(other_route, settings), source)
        }
      end

    Support.setup_runs!(root)
    Support.record_run!("issue-1", "run-1", project_slug: "project-a")
    _ = RunRegistry.load()

    %{
      root: root,
      origin: origin,
      agent_repo: agent_repo,
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

  defp mirror_spec(context, endpoint, token) do
    RunSpec.attach_git_mirror(
      %RunSpec{run_id: context.run_id, epoch: 1, issue: context.issue, controller_url: endpoint.url, token: token},
      context.settings
    )
  end

  defp run_clone(spec, workspace, opts \\ []) do
    {version, opts} = Keyword.pop(opts, :protocol_version, 2)
    {:ok, %{script: script, env: env}} = GitMirror.clone_commands(spec, workspace, opts)
    assert [{"GIT_CONFIG_COUNT", "1"} | rest] = env

    env = [{"GIT_CONFIG_COUNT", "2"}, {"GIT_CONFIG_KEY_1", "protocol.version"}, {"GIT_CONFIG_VALUE_1", "#{version}"} | rest]
    System.cmd("sh", ["-c", script], env: env, stderr_to_stdout: true)
  end

  defp current_branch(workspace) do
    {branch, 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"])
    String.trim(branch)
  end

  defp git_config(workspace, key) do
    {value, 0} = System.cmd("git", ["-C", workspace, "config", key])
    String.trim(value)
  end

  defp request_headers(context) do
    [
      {"authorization", "Bearer #{RunToken.sign(context.run_id, 1)}"},
      {"content-type", "application/x-git-upload-pack-request"}
    ]
  end

  defp info_refs_url(context, endpoint) do
    "#{endpoint.url}/git/#{context.run_id}/#{context.repo_key}/info/refs?service=git-upload-pack"
  end

  defp upload_pack_url(context, endpoint) do
    "#{endpoint.url}/git/#{context.run_id}/#{context.repo_key}/git-upload-pack"
  end

  defp want_body(sha) do
    pkt_line("want #{sha} multi_ack_detailed side-band-64k ofs-delta\n") <> "0000" <> pkt_line("done\n")
  end

  defp request_file!(context, body) do
    path = Path.join(context.root, "request-#{System.unique_integer([:positive])}")
    File.write!(path, body)
    path
  end

  defp collect(cache_path, mode, protocol) do
    case UploadPack.stream(cache_path, mode, protocol, [], [], &cont/2) do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      other -> other
    end
  end

  defp cont(chunk, acc), do: {:cont, [chunk | acc]}

  # A commit with an incompressible file, fetched into the cache, so the pack
  # for it is several MB.
  defp push_large_commit!(context, bytes) do
    File.write!(Path.join(context.agent_repo, "large.bin"), :crypto.strong_rand_bytes(bytes))
    System.cmd("git", ["-C", context.agent_repo, "add", "large.bin"])
    System.cmd("git", ["-C", context.agent_repo, "commit", "-q", "-m", "large"])
    {_output, 0} = System.cmd("git", ["-C", context.agent_repo, "push", "-q", "origin", "main"])
    File.write!(Path.join([context.cache_path, ".git", "symphony-fetched-at"]), "0")
    assert :ok = Workspace.refresh_repo_cache(context.repo.route, context.settings)
    {sha, 0} = System.cmd("git", ["-C", context.cache_path, "rev-parse", "origin/main"])
    String.trim(sha)
  end

  # A fake `git` that records its pid (the port's OS pid, thanks to `exec`)
  # and then sleeps, writes once and sleeps, writes forever, writes and fails,
  # or exits silently.
  defp fake_git_dir!(context) do
    tmp = Path.join(context.root, "fake-git")
    File.mkdir_p!(tmp)
    pid_file = Path.join(tmp, "pid")
    on_exit(fn -> System.delete_env("FAKE_GIT_MODE") end)

    write_script!(tmp, "git", """
    #!/bin/sh
    echo $$ > "#{pid_file}.tmp" && mv "#{pid_file}.tmp" "#{pid_file}"
    case "$FAKE_GIT_MODE" in
      sleep) exec sleep 30 ;;
      ready) echo ready; exec sleep 30 ;;
      spew) while :; do echo spew; done ;;
      partial) echo partial; exit 42 ;;
      silent) exit 0 ;;
      *) exit 42 ;;
    esac
    """)

    tmp
  end

  defp fake_pid!(tmp) do
    path = Path.join(tmp, "pid")
    wait_until(fn -> File.exists?(path) end)
    pid = path |> File.read!() |> String.trim()
    File.rm!(path)
    pid
  end

  defp alive?(pid), do: match?({_output, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  defp assert_dead!(pid), do: wait_until(fn -> not alive?(pid) end)

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)
    end
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
    {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "origin/main"])
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
