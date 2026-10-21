# credo:disable-for-this-file Credo.Check.Readability.MaxLineLength
defmodule SymphonyElixir.GitHubAppTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubApp
  alias SymphonyElixir.GitHubApp.Cache
  alias SymphonyElixir.Redaction
  alias SymphonyElixir.RunSpec

  setup_all do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    {:ok, pem: pem, public_key: {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}}
  end

  defp config(pem, overrides \\ []) do
    struct(
      %Schema.GitHubApp{
        app_id: 123_456,
        private_key: pem,
        installation_id: 987_654,
        base_url: "https://api.github.com",
        permissions: GitHubApp.default_permissions()
      },
      overrides
    )
  end

  defp at(iso), do: iso |> DateTime.from_iso8601() |> elem(1)

  defp decode_segment(segment) do
    segment |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp token_response(expires_at \\ "2030-01-01T00:10:00Z") do
    fn conn -> Req.Test.json(conn, %{"token" => "ghs_test_installation_token_1234567890", "expires_at" => expires_at}) end
  end

  test "configured? is opt-in and needs an app id and private key", %{pem: pem} do
    refute GitHubApp.configured?()
    refute GitHubApp.configured?(%Schema{github_app: %Schema.GitHubApp{}})
    refute GitHubApp.configured?(config(pem, app_id: nil))
    refute GitHubApp.configured?(config(pem, private_key: "  "))
    assert GitHubApp.configured?(config(pem))
  end

  test "app_jwt is a verifiable RS256 JWT with the app claims", %{pem: pem, public_key: public_key} do
    now = at("2030-01-01T00:00:00Z")

    assert {:ok, jwt} = GitHubApp.app_jwt(config(pem), now: now)
    [header, claims, signature] = String.split(jwt, ".")

    assert decode_segment(header) == %{"alg" => "RS256", "typ" => "JWT"}
    assert decode_segment(claims) == %{"iat" => DateTime.to_unix(now) - 60, "exp" => DateTime.to_unix(now) + 9 * 60, "iss" => 123_456}

    signing_input = header <> "." <> claims
    signature = Base.url_decode64!(signature, padding: false)
    assert :public_key.verify(signing_input, :sha256, signature, public_key)
  end

  test "app_jwt accepts clock and integer now, and rejects bad keys", %{pem: pem} do
    clock = fn -> at("2030-01-01T00:00:00Z") end
    assert {:ok, _jwt} = GitHubApp.app_jwt(config(pem), clock: clock)
    assert {:ok, _jwt} = GitHubApp.app_jwt(config(pem), now: 1_893_456_000)
    assert {:error, :invalid_private_key} = GitHubApp.app_jwt(config("not a pem"))
    assert {:error, :invalid_private_key} = GitHubApp.app_jwt(config("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n"))
    assert GitHubApp.app_jwt(config(pem), now: 1_893_456_000) == GitHubApp.app_jwt(config(pem), now: 1_893_456_000)
  end

  test "app_jwt accepts a PEM whose line breaks are literal \\n sequences", %{pem: pem, public_key: public_key} do
    escaped = String.replace(pem, "\n", "\\n")
    refute escaped =~ "\n"

    assert {:ok, jwt} = GitHubApp.app_jwt(config(escaped), now: 1_893_456_000)
    [header, claims, signature] = String.split(jwt, ".")
    assert :public_key.verify(header <> "." <> claims, :sha256, Base.url_decode64!(signature, padding: false), public_key)
  end

  test "app_jwt errors are opaque atoms that never carry key material" do
    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
    ec_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec_key)])
    assert {:error, :invalid_private_key} = GitHubApp.app_jwt(config(ec_pem))

    # A structurally valid RSA key the crypto library refuses to sign with.
    broken = {:RSAPrivateKey, :"two-prime", 0, 65_537, 0, 0, 0, 0, 0, 0, :asn1_NOVALUE}
    broken_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, broken)])
    assert {:error, :jwt_signing_failed} = GitHubApp.app_jwt(config(broken_pem))

    garbage = "-----BEGIN RSA PRIVATE KEY-----\nc2VjcmV0LWtleS1tYXRlcmlhbA==\n-----END RSA PRIVATE KEY-----\n"
    assert {:error, :invalid_private_key} = GitHubApp.app_jwt(config(garbage))
    assert {:error, :invalid_private_key} = GitHubApp.app_jwt(config(<<0xFF, 0xFE>>))
  end

  test "app_jwt without configuration returns a stable error", %{pem: pem} do
    refute GitHubApp.configured?(nil)
    assert {:error, :github_app_not_configured} = GitHubApp.app_jwt(%Schema.GitHubApp{})
    assert {:error, :github_app_not_configured} = GitHubApp.app_jwt(config(pem, private_key: nil))
  end

  test "permission validation is an allowlist of repository permissions", %{pem: pem} do
    assert {:ok, %{"contents" => "write"}} = GitHubApp.validate_permissions(%{"contents" => "write"})
    assert {:ok, %{"contents" => "write"}} = GitHubApp.validate_permissions(%{contents: :write})

    for key <- GitHubApp.allowed_permissions() do
      assert {:ok, %{^key => "read"}} = GitHubApp.validate_permissions(%{key => "read"})
    end

    assert GitHubApp.allowed_permissions() == ~w(contents pull_requests metadata issues checks statuses)

    for key <- ["workflows", "administration", "organization_projects", "org_members", "members", "secrets", "actions", "environments", "deployments", "pages"] do
      assert {:error, {:forbidden_permissions, [^key]}} = GitHubApp.validate_permissions(%{key => "write"})
    end

    assert {:error, {:forbidden_permissions, ["actions", "secrets"]}} =
             GitHubApp.validate_permissions(%{"secrets" => "read", "contents" => "read", "actions" => "write"})

    # GitHub grants every installation permission for an empty map.
    assert {:error, {:invalid_permissions, :empty}} = GitHubApp.validate_permissions(%{})
    assert {:error, {:invalid_permissions, :empty}} = GitHubApp.installation_token("octo/repo", config: config(pem, permissions: %{}), cache: false)

    assert {:error, {:invalid_permissions, ["contents"]}} = GitHubApp.validate_permissions(%{"contents" => "admin"})
    assert {:error, {:invalid_permissions, :not_a_map}} = GitHubApp.validate_permissions(:nope)
    assert {:error, {:invalid_permissions, :empty}} = GitHubApp.validate_permissions(%{})
    assert {:error, :github_app_not_configured} = GitHubApp.installation_token("octo/repo", config: %Schema.GitHubApp{})
    assert {:error, {:invalid_repository, "no-slash"}} = GitHubApp.installation_token("no-slash", config: config(pem), cache: false)

    for repo <- ["octo/..", "../repo", "./repo", "octo/.", "octo/repo/extra", "octo/re po"] do
      assert {:error, {:invalid_repository, ^repo}} = GitHubApp.installation_token(repo, config: config(pem), cache: false)
    end

    assert {:ok, _token} = GitHubApp.installation_token("octo/.github", config: config(pem), cache: false, plug: token_response())
    assert {:ok, _token} = GitHubApp.installation_token("octo/repo..x", config: config(pem), cache: false, plug: token_response())
    assert {:ok, _token} = GitHubApp.installation_token(%{kind: :github_slug, raw: "octo/repo"}, config: config(pem), cache: false, plug: token_response())
    assert {:error, :github_app_not_configured} = GitHubApp.installation_token("octo/repo")
    assert {:error, :github_app_not_configured} = GitHubApp.installation_token("octo/repo", cache: false)
    assert {:error, {:forbidden_permissions, ["workflows"]}} = GitHubApp.installation_token("octo/repo", config: config(pem, permissions: %{"workflows" => "write"}), cache: false)
  end

  test "installation_token posts repository-scoped permissions", %{pem: pem} do
    parent = self()

    plug = fn conn ->
      assert conn.request_path == "/app/installations/987654/access_tokens"
      assert conn.method == "POST"
      assert ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
      assert [_header, _claims, _signature] = String.split(jwt, ".")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, Jason.decode!(body)})
      Req.Test.json(conn, %{"token" => "ghs_test_installation_token_1234567890", "expires_at" => "2030-01-01T00:10:00Z"})
    end

    now = at("2030-01-01T00:00:00Z")

    assert {:ok, %{token: "ghs_test_installation_token_1234567890", expires_at: expires_at}} =
             GitHubApp.installation_token("octo/repo", config: config(pem), cache: false, plug: plug, now: now)

    assert expires_at == at("2030-01-01T00:10:00Z")

    assert_receive {:body,
                    %{
                      "repositories" => ["repo"],
                      "permissions" => %{"contents" => "write", "metadata" => "read", "pull_requests" => "write"}
                    }}
  end

  test "access: :read requests the configured contents and metadata as read only", %{pem: pem} do
    parent = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:permissions, Jason.decode!(body)["permissions"]})
      token_response().(conn)
    end

    assert {:ok, _token} = GitHubApp.installation_token("octo/repo", config: config(pem), cache: false, plug: plug, access: :read)
    assert_receive {:permissions, %{"contents" => "read", "metadata" => "read"} = permissions}
    assert map_size(permissions) == 2

    assert GitHubApp.read_permissions(%{"contents" => "write", "issues" => "write", "pull_requests" => "write"}) == %{"contents" => "read", "metadata" => "read"}
    assert GitHubApp.read_permissions(%{issues: :write}) == %{"metadata" => "read"}

    # Read and write tokens for one repo are cached separately.
    name = :"github_app_cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: name})
    clock = fn -> at("2030-01-01T00:00:00Z") end
    assert {:ok, _} = GitHubApp.installation_token("octo/repo", config: config(pem), cache: name, plug: plug, clock: clock, access: :read)
    assert {:ok, _} = GitHubApp.installation_token("octo/repo", config: config(pem), cache: name, plug: plug, clock: clock)
    assert_receive {:permissions, %{"contents" => "read"}}
    assert_receive {:permissions, %{"contents" => "write"}}
  end

  test "installation discovery uses GET /repos/{owner}/{repo}/installation", %{pem: pem} do
    parent = self()

    plug = fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/octo/repo/installation"} ->
          Req.Test.json(conn, %{"id" => 42})

        {"POST", "/app/installations/42/access_tokens"} ->
          send(parent, :posted)
          token_response().(conn)
      end
    end

    assert {:ok, %{token: _token}} = GitHubApp.installation_token("octo/repo", config: config(pem, installation_id: nil), cache: false, plug: plug)
    assert_receive :posted
  end

  test "tokens are cached per repo and refreshed five minutes before expiry", %{pem: pem} do
    name = :"github_app_cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: name})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    plug = fn conn ->
      Agent.update(counter, &(&1 + 1))
      Req.Test.json(conn, %{"token" => "ghs_test_installation_token_1234567890", "expires_at" => "2030-01-01T00:10:00Z"})
    end

    config = config(pem)
    first = fn -> GitHubApp.installation_token("octo/repo", config: config, cache: name, plug: plug, clock: fn -> at("2030-01-01T00:00:00Z") end) end
    later = fn -> GitHubApp.installation_token("octo/repo", config: config, cache: name, plug: plug, clock: fn -> at("2030-01-01T00:04:59Z") end) end
    expiring = fn -> GitHubApp.installation_token("octo/repo", config: config, cache: name, plug: plug, clock: fn -> at("2030-01-01T00:05:01Z") end) end

    assert {:ok, %{token: _}} = first.()
    assert {:ok, %{token: _}} = later.()
    assert Agent.get(counter, & &1) == 1
    assert {:ok, %{token: _}} = expiring.()
    assert Agent.get(counter, & &1) == 2
  end

  test "min_ttl_ms decides when a cached token is too close to expiry", %{pem: pem} do
    name = :"github_app_cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: name})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # Every mint returns a token valid for one hour from the clock's "now".
    {:ok, now} = Agent.start_link(fn -> at("2030-01-01T00:00:00Z") end)
    clock = fn -> Agent.get(now, & &1) end
    advance = fn seconds -> Agent.update(now, &DateTime.add(&1, seconds)) end

    plug = fn conn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      expires_at = clock.() |> DateTime.add(3600) |> DateTime.to_iso8601()
      Req.Test.json(conn, %{"token" => "ghs_token_number_#{n}_abcdefghijklmnopqrstu", "expires_at" => expires_at})
    end

    fetch = fn opts -> GitHubApp.installation_token("octo/repo", [config: config(pem), cache: name, plug: plug, clock: clock] ++ opts) end
    agent_ttl = [min_ttl_ms: 50 * 60 * 1000]

    assert {:ok, %{token: "ghs_token_number_1" <> _}} = fetch.([])

    # 9 minutes later: 51 minutes left, enough for both callers.
    advance.(9 * 60)
    assert {:ok, %{token: "ghs_token_number_1" <> _}} = fetch.(agent_ttl)
    assert {:ok, %{token: "ghs_token_number_1" <> _}} = fetch.([])

    # 11 minutes in: 49 minutes left. An agent gets a fresh token...
    advance.(2 * 60)
    assert {:ok, %{token: "ghs_token_number_2" <> _}} = fetch.(agent_ttl)
    # ...which then serves workspace syncs too.
    assert {:ok, %{token: "ghs_token_number_2" <> _}} = fetch.([])

    # A workspace sync keeps reusing token 2 until five minutes before its expiry.
    advance.(54 * 60)
    assert {:ok, %{token: "ghs_token_number_2" <> _}} = fetch.([])
    advance.(2 * 60)
    assert {:ok, %{token: "ghs_token_number_3" <> _}} = fetch.([])
    assert Agent.get(counter, & &1) == 3

    assert Cache.default_min_ttl_ms() == 5 * 60 * 1000
    assert {:ok, %{token: "x"}} = Cache.fetch(name, :ttl_zero, clock, fn -> {:ok, %{token: "x", expires_at: DateTime.add(clock.(), 1)}} end, 0)
    assert {:ok, %{token: "x"}} = Cache.fetch(name, :ttl_zero, clock, fn -> {:ok, %{token: "y", expires_at: DateTime.add(clock.(), 1)}} end, 0)
  end

  test "concurrent cache misses share one mint request", %{pem: pem} do
    name = :"github_app_cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: name})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    plug = fn conn ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(50)
      Req.Test.json(conn, %{"token" => "ghs_test_installation_token_1234567890", "expires_at" => "2030-01-01T00:10:00Z"})
    end

    clock = fn -> at("2030-01-01T00:00:00Z") end

    results =
      1..6
      |> Enum.map(fn _ ->
        Task.async(fn -> GitHubApp.installation_token("octo/repo", config: config(pem), cache: name, plug: plug, clock: clock) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.all?(results, &match?({:ok, %{token: _}}, &1))
    assert Agent.get(counter, & &1) == 1
  end

  test "cache errors, crashes and invalid results reach every waiter", %{pem: pem} do
    name = :"github_app_cache_#{System.unique_integer([:positive])}"
    cache = start_supervised!({Cache, name: name})
    clock = fn -> at("2030-01-01T00:00:00Z") end

    assert {:error, :down} = Cache.fetch(name, :error, clock, fn -> {:error, :down} end)
    assert {:error, {:invalid_token_response, :weird}} = Cache.fetch(name, :weird, clock, fn -> :weird end)
    assert {:error, {:exception, %RuntimeError{message: "boom"}}} = Cache.fetch(name, :raises, clock, fn -> raise "boom" end)
    assert {:error, {:throw, :boom}} = Cache.fetch(name, :throws, clock, fn -> throw(:boom) end)

    assert {:error, {:fetch_failed, :killed}} = Cache.fetch(name, :dies, clock, fn -> Process.exit(self(), :kill) end)

    send(cache, {:DOWN, make_ref(), :process, self(), :normal})
    send(cache, {:fetched, :missing, self(), {:ok, %{token: "x", expires_at: at("2030-01-01T00:10:00Z")}}})
    send(cache, :unexpected)
    assert Process.alive?(cache)

    # A malformed expiry is still a successful fetch for the cache; it is never fresh.
    assert {:ok, %{token: "x"}} = Cache.fetch(name, :bad_expiry, clock, fn -> {:ok, %{token: "x", expires_at: :tomorrow}} end)
    assert {:error, :down} = Cache.fetch(name, :again, clock, fn -> {:error, :down} end)

    assert {:error, :down} = Cache.fetch(:default_server, clock, fn -> {:error, :down} end)

    config = config(pem)
    assert {:ok, %{token: _}} = GitHubApp.installation_token("octo/repo", config: config, cache: name, plug: token_response(), clock: clock)
  end

  test "HTTP errors map to stable atoms", %{pem: pem} do
    for {status, error} <- [{401, :unauthorized}, {403, :forbidden}, {404, :not_found}, {422, :unprocessable_entity}, {500, {:http_status, 500}}] do
      plug = fn conn -> Plug.Conn.send_resp(conn, status, "{}") end
      assert {:error, ^error} = GitHubApp.installation_token("octo/repo", config: config(pem), cache: false, plug: plug)
    end

    discovery = fn conn ->
      if conn.request_path == "/repos/octo/repo/installation" do
        Plug.Conn.send_resp(conn, 404, "{}")
      else
        token_response().(conn)
      end
    end

    assert {:error, :not_found} = GitHubApp.installation_token("octo/repo", config: config(pem, installation_id: nil), cache: false, plug: discovery)

    empty_discovery = fn conn ->
      if conn.request_path == "/repos/octo/repo/installation" do
        Req.Test.json(conn, %{})
      else
        token_response().(conn)
      end
    end

    assert {:error, {:http_status, 200}} = GitHubApp.installation_token("octo/repo", config: config(pem, installation_id: nil), cache: false, plug: empty_discovery)
    assert {:ok, _token} = GitHubApp.installation_token("octo/repo", config: config(pem), cache: false, req_options: [plug: token_response()])
    assert {:error, :invalid_token_expiry} = GitHubApp.installation_token("octo/repo", config: config(pem), cache: false, plug: token_response("tomorrow"))
    assert {:error, {:invalid_repository, %{kind: :local_path}}} = GitHubApp.installation_token(%{kind: :local_path}, config: config(pem), cache: false)

    refused = fn conn -> Req.Test.transport_error(conn, :econnrefused) end
    assert {:error, %Req.TransportError{reason: :econnrefused}} = GitHubApp.installation_token("octo/repo", config: config(pem), cache: false, plug: refused)

    discovery_refused = fn conn ->
      if conn.request_path == "/repos/octo/repo/installation" do
        Req.Test.transport_error(conn, :econnrefused)
      else
        token_response().(conn)
      end
    end

    assert {:error, %Req.TransportError{reason: :econnrefused}} =
             GitHubApp.installation_token("octo/repo", config: config(pem, installation_id: nil), cache: false, plug: discovery_refused)
  end

  test "git_env passes the token only in the environment" do
    token = "ghs_test_installation_token_1234567890"
    env = Map.new(GitHubApp.git_env(token))
    assert env["GH_TOKEN"] == token
    assert env["GIT_TERMINAL_PROMPT"] == "0"
    assert env["GIT_CONFIG_COUNT"] == "1"
    assert env["GIT_CONFIG_KEY_0"] == "http.https://github.com/.extraHeader"
    assert env["GIT_CONFIG_VALUE_0"] == "Authorization: Basic " <> Base.encode64("x-access-token:" <> token)

    assert %{"GIT_CONFIG_KEY_0" => "http.https://ghe.example.com/.extraHeader"} = Map.new(GitHubApp.git_env(token, host: "ghe.example.com"))
  end

  test "git_env appends to an existing GIT_CONFIG_COUNT instead of replacing it" do
    token = "ghs_test_installation_token_1234567890"

    env = Map.new(GitHubApp.git_env(token, base_env: %{"GIT_CONFIG_COUNT" => "2", "GIT_CONFIG_KEY_0" => "a.b", "GIT_CONFIG_KEY_1" => "c.d"}))
    assert env["GIT_CONFIG_COUNT"] == "3"
    assert env["GIT_CONFIG_KEY_2"] == "http.https://github.com/.extraHeader"
    assert env["GIT_CONFIG_VALUE_2"] =~ "Authorization: Basic "
    refute Map.has_key?(env, "GIT_CONFIG_KEY_0")

    for bad <- ["", "x", "-1", "2x"] do
      assert %{"GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => _} = Map.new(GitHubApp.git_env(token, base_env: %{"GIT_CONFIG_COUNT" => bad}))
    end

    assert %{"GIT_CONFIG_COUNT" => "5", "GIT_CONFIG_KEY_4" => _} = Map.new(GitHubApp.git_env(token, base_env: %{"GIT_CONFIG_COUNT" => " 4 "}))
  end

  test "git keeps existing GIT_CONFIG_* entries next to the token header" do
    token = "ghs_" <> String.duplicate("m", 36)
    repo = Path.join(System.tmp_dir!(), "symphony-github-app-git-merge-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(repo) end)
    {_output, 0} = System.cmd("git", ["init", "--quiet", repo])

    base_env = %{"GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "symphony.test", "GIT_CONFIG_VALUE_0" => "kept"}
    env = Map.to_list(base_env) ++ GitHubApp.git_env(token, base_env: base_env)

    assert {"kept\n", 0} = System.cmd("git", ["-C", repo, "config", "--get", "symphony.test"], env: env)
    assert {"Authorization: Basic " <> _, 0} = System.cmd("git", ["-C", repo, "config", "--get", "http.https://github.com/.extraheader"], env: env)
  end

  test "the git_env authorization header is redacted from logs" do
    token = "ghs_test_installation_token_1234567890"
    env = Map.new(GitHubApp.git_env(token))
    value = env["GIT_CONFIG_VALUE_0"]
    basic = Base.encode64("x-access-token:" <> token)

    assert Redaction.redact(value) == "Authorization: Basic [REDACTED]"
    refute Redaction.redact("git -c http.extraHeader='#{value}' fetch") =~ basic
  end

  test "git_env appends its header to an inherited GIT_CONFIG_COUNT" do
    token = "ghs_test_installation_token_1234567890"
    env = Map.new(GitHubApp.git_env(token, base_env: %{"GIT_CONFIG_COUNT" => "2"}))

    assert env["GIT_CONFIG_COUNT"] == "3"
    assert env["GIT_CONFIG_KEY_2"] == "http.https://github.com/.extraHeader"
    assert env["GIT_CONFIG_VALUE_2"] =~ Base.encode64("x-access-token:" <> token)

    fallback = Map.new(GitHubApp.git_env(token, base_env: %{"GIT_CONFIG_COUNT" => "nope"}))
    assert fallback["GIT_CONFIG_COUNT"] == "1"
  end

  test "git_host maps the API base URL to the git web host", %{pem: pem} do
    assert GitHubApp.git_host(config(pem)) == "github.com"
    assert GitHubApp.git_host(config(pem, base_url: nil)) == "github.com"
    assert GitHubApp.git_host(config(pem, base_url: "https://ghe.example.com/api/v3")) == "ghe.example.com"
    assert GitHubApp.git_host(config(pem, base_url: "not a url")) == "github.com"
  end

  test "git reads the token from the environment, not from .git/config" do
    token = "ghs_" <> String.duplicate("e", 36)
    repo = Path.join(System.tmp_dir!(), "symphony-github-app-git-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(repo) end)
    {_output, 0} = System.cmd("git", ["init", "--quiet", repo])

    {header, 0} = System.cmd("git", ["-C", repo, "config", "--get", "http.https://github.com/.extraheader"], env: GitHubApp.git_env(token))
    assert header == "Authorization: Basic " <> Base.encode64("x-access-token:" <> token) <> "\n"

    refute File.read!(Path.join([repo, ".git", "config"])) =~ "extraheader"
    assert {_output, 1} = System.cmd("git", ["-C", repo, "config", "--get", "http.https://github.com/.extraheader"])
  end

  test "env_pairs resolves the issue's repository", %{pem: pem} do
    settings =
      Schema.parse(%{
        "tracker" => %{"kind" => "memory", "projects" => [%{"slug" => "p", "repo" => "octo/repo"}]},
        "github_app" => %{"app_id" => 123_456, "private_key" => pem, "installation_id" => 987_654}
      })

    assert {:ok, settings} = settings
    issue = %{project_slug: "p"}

    env = Map.new(GitHubApp.env_pairs(issue, settings: settings, cache: false, plug: token_response()))
    assert env["GH_TOKEN"] == "ghs_test_installation_token_1234567890"

    env = Map.new(GitHubApp.env_pairs(issue, settings: settings, cache: false, plug: token_response(), base_env: %{"GIT_CONFIG_COUNT" => "1"}))
    assert env["GIT_CONFIG_COUNT"] == "2"
    assert env["GIT_CONFIG_KEY_1"] == "http.https://github.com/.extraHeader"

    {:ok, plain_settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    assert GitHubApp.env_pairs(issue) == []
    assert GitHubApp.env_pairs(%{project_slug: "none"}, settings: settings) == []

    assert GitHubApp.env_pairs(issue, settings: plain_settings) == []

    local_settings = Schema.parse(%{"tracker" => %{"kind" => "memory", "projects" => [%{"slug" => "p", "repo" => "/tmp/repo"}]}, "github_app" => %{"app_id" => 1, "private_key" => pem}})
    assert {:ok, local_settings} = local_settings
    assert GitHubApp.env_pairs(issue, settings: local_settings) == []

    rejected = fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end
    log = capture_log(fn -> assert GitHubApp.env_pairs(issue, settings: settings, cache: false, plug: rejected) == [] end)
    assert log =~ "GitHub App token unavailable repo=octo/repo"
  end

  test "env_pairs gives agents a token with at least 50 minutes left", %{pem: pem} do
    name = :"github_app_cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: name})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    plug = fn conn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      Req.Test.json(conn, %{"token" => "ghs_agent_token_#{n}_abcdefghijklmnopqrstuv", "expires_at" => "2030-01-01T01:00:00Z"})
    end

    {:ok, settings} =
      Schema.parse(%{
        "tracker" => %{"kind" => "memory", "projects" => [%{"slug" => "p", "repo" => "octo/repo"}]},
        "github_app" => %{"app_id" => 123_456, "private_key" => pem, "installation_id" => 987_654}
      })

    issue = %{project_slug: "p"}
    token_at = fn iso, opts -> GitHubApp.installation_token("octo/repo", [settings: settings, cache: name, plug: plug, clock: fn -> at(iso) end] ++ opts) end
    env_at = fn iso -> Map.new(GitHubApp.env_pairs(issue, settings: settings, cache: name, plug: plug, clock: fn -> at(iso) end))["GH_TOKEN"] end

    # A workspace sync at 00:15 caches token 1 (45 minutes left).
    assert {:ok, %{token: "ghs_agent_token_1" <> _}} = token_at.("2030-01-01T00:15:00Z", [])
    # An agent starting then needs more than that, so it gets a fresh token.
    assert "ghs_agent_token_2" <> _ = env_at.("2030-01-01T00:15:00Z")
    assert Agent.get(counter, & &1) == 2
  end

  test "token_for_run resolves the issue's repository", %{pem: pem} do
    {:ok, settings} =
      Schema.parse(%{
        "tracker" => %{"kind" => "memory", "projects" => [%{"slug" => "p", "repo" => "octo/repo"}]},
        "github_app" => %{"app_id" => 123_456, "private_key" => pem, "installation_id" => 987_654}
      })

    issue = %{project_slug: "p"}
    spec = %RunSpec{run_id: "r", epoch: 1, issue: issue}

    assert {:ok, %{token: "ghs_test_installation_token_1234567890"}} =
             GitHubApp.token_for_run(spec, settings: settings, cache: false, plug: token_response())

    {:ok, plain} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    assert {:ok, nil} = GitHubApp.token_for_run(spec, settings: plain)
    assert {:ok, nil} = GitHubApp.token_for_run(spec)

    assert {:error, :run_repo_is_not_a_github_repository} =
             GitHubApp.token_for_run(%RunSpec{run_id: "r", epoch: 1, issue: %{project_slug: "none"}}, settings: settings)
  end

  test "config validates github_app permissions", %{pem: pem} do
    assert {:ok, %Schema{github_app: %Schema.GitHubApp{permissions: permissions}}} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "github_app" => %{"permissions" => %{"contents" => "write"}}
             })

    assert permissions == %{"contents" => "write"}

    assert {:ok, %Schema{github_app: %Schema.GitHubApp{permissions: %{"issues" => "write", "checks" => "read"}}}} =
             Schema.parse(%{"tracker" => %{"kind" => "memory"}, "github_app" => %{"permissions" => %{"issues" => "write", "checks" => "read"}}})

    assert {:ok, %Schema{github_app: %Schema.GitHubApp{permissions: defaults}}} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    assert defaults == %{"contents" => "write", "pull_requests" => "write", "metadata" => "read"}

    for {permissions, expected} <- [
          {%{"workflows" => "write"}, "workflows"},
          {%{"administration" => "write"}, "administration"},
          {%{"organization_projects" => "write"}, "organization_projects"},
          {%{"secrets" => "read"}, "allowed: contents"},
          {%{"contents" => "admin"}, "contents"},
          {%{}, "must not be empty"}
        ] do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"tracker" => %{"kind" => "memory"}, "github_app" => %{"permissions" => permissions}})

      assert message =~ expected
    end

    assert {:ok, %Schema{github_app: %Schema.GitHubApp{app_id: 1}}} =
             Schema.parse(%{"tracker" => %{"kind" => "memory"}, "github_app" => %{"app_id" => 1, "private_key" => pem}})
  end
end
