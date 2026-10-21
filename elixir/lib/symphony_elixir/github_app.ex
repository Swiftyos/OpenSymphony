defmodule SymphonyElixir.GitHubApp do
  @moduledoc """
  Short-lived GitHub App installation tokens for one repository at a time.

  A classic `GH_TOKEN` or a host `gh auth login` is shared by every run on the
  host. When `github_app` is configured, Symphony instead signs an app JWT,
  exchanges it for an installation token limited to the issue's repository
  (`contents: write`, `pull_requests: write`, `metadata: read` by default), and
  passes that token to git and `gh` through the process environment.

  Tokens are cached per repository. Workspace syncs reuse a cached token until
  five minutes before its expiry; agents, which may run for a long time with the
  token in their environment, get one with at least 50 minutes left. No token is
  ever written to `.git/config` or passed in a process's arguments.

  Configure it in `symphony.yml`/`WORKFLOW.md`:

      github_app:
        app_id: 123456
        private_key: $GITHUB_APP_PRIVATE_KEY
        # installation_id: 987654   # optional; discovered per repository
        # base_url: https://github.example.com/api/v3   # GitHub Enterprise
  """

  require Logger

  alias SymphonyElixir.{Config, RunSpec}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubApp.Cache
  alias SymphonyElixir.GitHubApp.RunnerToken

  @default_base_url "https://api.github.com"
  # Only repository permissions an issue-scoped run needs. Anything else
  # (workflows, administration, secrets, organization permissions, ...) is refused.
  @allowed_permissions ~w(contents pull_requests metadata issues checks statuses)
  @repo_pattern ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/
  @agent_min_ttl_ms 50 * 60 * 1000
  @type token :: %{token: String.t(), expires_at: DateTime.t()}

  @doc "Whether `github_app` has enough configuration to mint tokens."
  @spec configured?(Schema.t() | Schema.GitHubApp.t() | nil) :: boolean()
  def configured?(settings \\ nil) do
    config = config(settings)

    is_integer(config.app_id) and is_binary(config.private_key) and String.trim(config.private_key) != ""
  end

  @doc "The default repository permissions requested for an installation token."
  @spec default_permissions() :: %{String.t() => String.t()}
  def default_permissions, do: %Schema.GitHubApp{}.permissions

  @doc """
  Returns an RS256 app JWT.

  Options: `:now`/`:clock` for tests, and config as `:settings` or `:config`.
  """
  @spec app_jwt(Schema.t() | Schema.GitHubApp.t() | nil, keyword()) :: {:ok, String.t()} | {:error, term()}
  def app_jwt(settings \\ nil, opts \\ []) do
    config = if settings, do: config(settings), else: config_from_opts(opts)
    now = now_seconds(opts)

    with :ok <- ensure_configured(config),
         {:ok, private_key} <- decode_private_key(config.private_key) do
      header = %{"alg" => "RS256", "typ" => "JWT"}
      claims = %{"iat" => now - 60, "exp" => now + 9 * 60, "iss" => config.app_id}

      signing_input =
        [encode_segment(header), encode_segment(claims)]
        |> Enum.join(".")

      with {:ok, signature} <- sign(signing_input, private_key) do
        {:ok, signing_input <> "." <> Base.url_encode64(signature, padding: false)}
      end
    end
  end

  @doc """
  Mints (or returns from cache) an installation token for `owner/name`.

  The response is `{:ok, %{token: token, expires_at: DateTime.t()}}`. The token
  is limited to that repository and to `github_app.permissions`.

  Option `:min_ttl_ms` is how long a cached token must still be valid to be
  reused (default five minutes); a token closer to expiry is replaced by a
  freshly minted one.

  Option `:access` is `:configured` (default, `github_app.permissions`) or
  `:read`, which requests only `read_permissions/1`, for a clone or fetch that
  never pushes.
  """
  @spec installation_token(String.t() | map(), keyword()) :: {:ok, token()} | {:error, term()}
  def installation_token(repo, opts \\ []) do
    config = config_from_opts(opts)
    clock = Keyword.get(opts, :clock, fn -> DateTime.utc_now() end)

    requested =
      case Keyword.get(opts, :access, :configured) do
        :read -> read_permissions(config.permissions)
        :configured -> config.permissions
      end

    with :ok <- ensure_configured(config),
         {:ok, slug} <- repo_slug(repo),
         {:ok, permissions} <- validate_permissions(requested) do
      cached_or_mint(config, slug, permissions, opts, clock)
    end
  end

  @doc """
  The token a run needs, resolved from its issue's project route.

  Returns `{:ok, nil}` when `github_app` is not configured, so callers can keep
  the old shared-credential behaviour unchanged. The controller uses it at
  launch and behind `POST /runner/v1/runs/:run_id/github-token`; see
  `SymphonyElixir.GitHubApp.RunCredentials` and `docs/durable-runs.md`.
  """
  @spec token_for_run(RunSpec.t(), keyword()) :: {:ok, token() | nil} | {:error, term()}
  def token_for_run(%RunSpec{issue: issue} = _spec, opts \\ []) do
    settings = Keyword.get(opts, :settings) || Config.settings!()

    if configured?(settings) do
      case Config.project_repo_source_for_issue(issue, settings) do
        %{kind: :github_slug, raw: repo} ->
          # A run hands the token to an agent, so it needs the agent lifetime too.
          installation_token(repo, opts |> Keyword.put(:settings, settings) |> Keyword.put_new(:min_ttl_ms, @agent_min_ttl_ms))

        _ ->
          {:error, :run_repo_is_not_a_github_repository}
      end
    else
      {:ok, nil}
    end
  end

  @doc """
  Environment entries for an agent working on `issue`'s repository.

  Without `github_app` this is `[]`. A token failure is logged and also yields
  `[]` so a run starts with whatever host credentials it had before.

  The token has at least 50 minutes left. Option `:base_env` is the
  environment the agent inherits (see `git_env/2`).

  In a runner with per-run tokens (`SymphonyElixir.GitHubApp.RunnerToken`)
  this is `[]` too: the agent inherits the runner's credential-helper
  environment, whose token is refreshed in place, and a static header here
  would take precedence over it and expire.
  """
  @spec env_pairs(map() | nil, keyword()) :: [{String.t(), String.t()}]
  def env_pairs(issue, opts \\ []) do
    settings = Keyword.get(opts, :settings) || Config.settings!()

    if configured?(settings) and not RunnerToken.active?() do
      case Config.project_repo_source_for_issue(issue, settings) do
        %{kind: :github_slug, raw: repo} -> token_env(repo, settings, opts)
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Environment entries that make git and `gh` use `token` without putting it in
  a URL, the process arguments, or `.git/config`.

  git gets an `http.<host>.extraHeader` through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_*`
  (git 2.31+), so it authenticates with the token before any credential helper
  or keychain the host has configured is consulted. Option `:host` is the git
  web host (default `github.com`).

  Option `:base_env` is the environment the process would otherwise inherit
  (a map). When it already sets `GIT_CONFIG_COUNT=n`, the header is appended as
  entry `n` and the count becomes `n + 1`, so existing entries keep working.
  """
  @spec git_env(String.t(), keyword()) :: [{String.t(), String.t()}]
  def git_env(token, opts \\ []) when is_binary(token) do
    host = Keyword.get(opts, :host, "github.com")
    index = existing_git_config_count(Keyword.get(opts, :base_env, %{}))
    basic = Base.encode64("x-access-token:" <> token)

    [
      {"GH_TOKEN", token},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_COUNT", Integer.to_string(index + 1)},
      {"GIT_CONFIG_KEY_#{index}", "http.https://#{host}/.extraHeader"},
      {"GIT_CONFIG_VALUE_#{index}", "Authorization: Basic " <> basic}
    ]
  end

  defp existing_git_config_count(base_env) do
    with value when is_binary(value) <- Map.get(base_env, "GIT_CONFIG_COUNT"),
         {count, ""} when count >= 0 <- Integer.parse(String.trim(value)) do
      count
    else
      _ -> 0
    end
  end

  @doc "The git web host for a configured API base URL (`api.github.com` -> `github.com`)."
  @spec git_host(Schema.GitHubApp.t()) :: String.t()
  def git_host(%Schema.GitHubApp{base_url: base_url}) do
    case URI.parse(base_url || @default_base_url) do
      %URI{host: "api.github.com"} -> "github.com"
      %URI{host: host} when is_binary(host) and host != "" -> host
      _uri -> "github.com"
    end
  end

  @doc """
  Validates requested permissions.

  Only #{Enum.map_join(@allowed_permissions, ", ", &"`#{&1}`")} are allowed, each
  `read` or `write`: an issue-scoped run must not be able to change CI
  definitions, secrets, or the app's installation. An empty map is refused
  because GitHub treats it as "every permission the installation has".
  """
  @spec validate_permissions(map()) :: {:ok, map()} | {:error, term()}
  def validate_permissions(permissions) when permissions == %{}, do: {:error, {:invalid_permissions, :empty}}

  def validate_permissions(permissions) when is_map(permissions) do
    normalized = Map.new(permissions, fn {key, value} -> {to_string(key), to_string(value)} end)

    forbidden = Enum.reject(Map.keys(normalized), &(&1 in @allowed_permissions))
    invalid = Enum.reject(normalized, fn {_key, value} -> value in ["read", "write"] end)

    cond do
      forbidden != [] -> {:error, {:forbidden_permissions, Enum.sort(forbidden)}}
      invalid != [] -> {:error, {:invalid_permissions, Enum.map(invalid, &elem(&1, 0)) |> Enum.sort()}}
      true -> {:ok, normalized}
    end
  end

  def validate_permissions(_permissions), do: {:error, {:invalid_permissions, :not_a_map}}

  @doc """
  Read-only permissions for a clone or fetch: the configured `contents` and
  `metadata` permissions, downgraded to `read`. Asking for a permission the app
  was not granted fails at GitHub, so nothing is added that is not configured;
  `metadata: read` (which every installation has) is the floor.
  """
  @spec read_permissions(map()) :: %{String.t() => String.t()}
  def read_permissions(permissions) when is_map(permissions) do
    permissions
    |> Map.new(fn {key, _value} -> {to_string(key), "read"} end)
    |> Map.take(["contents", "metadata"])
    |> Map.put("metadata", "read")
  end

  @doc "The repository permissions `validate_permissions/1` accepts."
  @spec allowed_permissions() :: [String.t()]
  def allowed_permissions, do: @allowed_permissions

  @doc false
  @spec mint(Schema.GitHubApp.t(), String.t(), map(), keyword()) :: {:ok, token()} | {:error, term()}
  def mint(config, repo, permissions, opts) do
    with {:ok, jwt} <- app_jwt(config, opts),
         {:ok, installation_id} <- installation_id(config, repo, jwt, opts),
         {:ok, token, expires_at} <-
           request_installation_token(config, installation_id, repo, permissions, jwt, opts) do
      {:ok, %{token: token, expires_at: expires_at}}
    end
  end

  defp cached_or_mint(config, slug, permissions, opts, clock) do
    key = {config.base_url, config.app_id, config.installation_id, slug, :erlang.phash2(permissions)}

    case Keyword.get(opts, :cache, Cache) do
      false ->
        mint(config, slug, permissions, opts)

      cache ->
        min_ttl_ms = Keyword.get(opts, :min_ttl_ms, Cache.default_min_ttl_ms())
        Cache.fetch(cache, key, clock, fn -> mint(config, slug, permissions, opts) end, min_ttl_ms)
    end
  end

  defp token_env(repo, settings, opts) do
    token_opts = opts |> Keyword.put(:settings, settings) |> Keyword.put_new(:min_ttl_ms, @agent_min_ttl_ms)

    case installation_token(repo, token_opts) do
      {:ok, %{token: token}} ->
        git_env(token, host: git_host(settings.github_app), base_env: Keyword.get(opts, :base_env, %{}))

      {:error, reason} ->
        Logger.warning("GitHub App token unavailable repo=#{repo} reason=#{inspect(reason, limit: 5)}")
        []
    end
  end

  defp installation_id(%{installation_id: installation_id}, _repo, _jwt, _opts)
       when is_integer(installation_id) do
    {:ok, installation_id}
  end

  defp installation_id(config, repo, jwt, opts) do
    request = request(config, jwt, opts)

    case Req.get(request, url: "/repos/#{repo}/installation") do
      {:ok, %{status: status, body: %{"id" => id}}} when status in 200..299 and is_integer(id) ->
        {:ok, id}

      {:ok, %{status: status}} ->
        {:error, status_error(status)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_installation_token(config, installation_id, repo, permissions, jwt, opts) do
    [_owner, name] = String.split(repo, "/", parts: 2)

    body = %{
      "repositories" => [name],
      "permissions" => permissions
    }

    request = request(config, jwt, opts)

    case Req.post(request, url: "/app/installations/#{installation_id}/access_tokens", json: body) do
      {:ok, %{status: status, body: %{"token" => token, "expires_at" => expires_at}}}
      when status in 200..299 and is_binary(token) ->
        case DateTime.from_iso8601(expires_at) do
          {:ok, datetime, _offset} -> {:ok, token, datetime}
          {:error, _reason} -> {:error, :invalid_token_expiry}
        end

      {:ok, %{status: status}} ->
        {:error, status_error(status)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(config, jwt, opts) do
    req_options = Keyword.get(opts, :req_options, Application.get_env(:symphony_elixir, :github_app_req_options, []))

    req_options =
      case Keyword.fetch(opts, :plug) do
        {:ok, plug} -> Keyword.put(req_options, :plug, plug)
        :error -> req_options
      end

    Req.new(
      [
        base_url: config.base_url || @default_base_url,
        retry: false,
        receive_timeout: 15_000,
        headers: %{
          "authorization" => "Bearer #{jwt}",
          "accept" => "application/vnd.github+json",
          "x-github-api-version" => "2022-11-28",
          "user-agent" => "symphony"
        }
      ] ++ req_options
    )
  end

  defp status_error(401), do: :unauthorized
  defp status_error(403), do: :forbidden
  defp status_error(404), do: :not_found
  defp status_error(422), do: :unprocessable_entity
  defp status_error(status), do: {:http_status, status}

  defp repo_slug(%{kind: :github_slug, raw: repo}), do: repo_slug(repo)

  defp repo_slug(repo) when is_binary(repo) do
    valid? = String.match?(repo, @repo_pattern) and not Enum.any?(String.split(repo, "/"), &(&1 in [".", ".."]))
    if valid?, do: {:ok, repo}, else: {:error, {:invalid_repository, repo}}
  end

  defp repo_slug(repo), do: {:error, {:invalid_repository, repo}}

  defp config(%Schema.GitHubApp{} = config), do: config
  defp config(%Schema{} = settings), do: settings.github_app
  defp config(nil), do: Config.settings!().github_app

  defp config_from_opts(opts) do
    case Keyword.get(opts, :config) || Keyword.get(opts, :settings) do
      %Schema.GitHubApp{} = config -> config
      %Schema{} = settings -> settings.github_app
      nil -> config(nil)
    end
  end

  defp ensure_configured(config) do
    if configured?(config), do: :ok, else: {:error, :github_app_not_configured}
  end

  defp now_seconds(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> DateTime.to_unix(now)
      now when is_integer(now) -> now
      nil -> DateTime.to_unix(Keyword.get(opts, :clock, fn -> DateTime.utc_now() end).())
    end
  end

  # Error terms here are opaque atoms: an exception from :public_key could quote
  # key material, and these errors end up in logs.
  defp decode_private_key(pem) do
    # A key from an env var or .env file often has literal "\n" sequences for
    # its line breaks. PEM base64 never contains a backslash, so this is safe.
    pem = String.replace(pem, "\\n", "\n")

    case :public_key.pem_decode(pem) do
      [entry | _rest] -> decode_pem_entry(entry)
      [] -> {:error, :invalid_private_key}
    end
  end

  defp decode_pem_entry(entry) do
    case :public_key.pem_entry_decode(entry) do
      key when is_tuple(key) and elem(key, 0) == :RSAPrivateKey -> {:ok, key}
      _other -> {:error, :invalid_private_key}
    end
  rescue
    _error -> {:error, :invalid_private_key}
  end

  defp sign(signing_input, private_key) do
    {:ok, :public_key.sign(signing_input, :sha256, private_key)}
  rescue
    _error -> {:error, :jwt_signing_failed}
  end

  defp encode_segment(value) do
    value |> Jason.encode!() |> Base.url_encode64(padding: false)
  end
end
