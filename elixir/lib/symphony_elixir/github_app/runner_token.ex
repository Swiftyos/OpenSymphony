defmodule SymphonyElixir.GitHubApp.RunnerToken do
  @moduledoc """
  The runner side of per-run GitHub App tokens: keeps the run's installation
  token fresh without the App private key.

  A runner whose spec has `github_host` starts this process before the agent.
  It takes the token the controller handed over at launch (a pod's `GH_TOKEN`
  and `SYMPHONY_GITHUB_TOKEN_EXPIRES_AT` from its run Secret, or a process
  runner's `github-token.json`, which it deletes) and, from then on, asks
  `POST /runner/v1/runs/:run_id/github-token` for a new one whenever less than
  15 minutes are left (at once when it started without a token).

  ## How the token reaches git and `gh`

  Agent CLIs can stay up for many turns, and an environment variable cannot
  change under a running process. So the token lives in files, and the
  environment only points at them:

  - `<run dir>/github/token` (0600) holds the raw token.
  - `<run dir>/github/git-credential` (0700) is a git credential helper that
    prints `username=x-access-token` and the current contents of `token`. git
    runs it for every authenticated request, so a refresh is picked up by the
    next `git push`, even inside a long agent turn. The script holds no secret.
  - `<run dir>/github/gh/hosts.yml` (0600) is a `gh` config whose
    `oauth_token` is rewritten on refresh; `gh` reads it on every invocation.

  At start, the runner's own OS environment (which every hook, agent CLI and
  git process it starts inherits) is changed once:

  - `GIT_CONFIG_*` drops any `http.<host>.extraHeader` entry (the launch
    token's static header, which would win over a helper and then expire) and
    adds `credential.https://<host>.helper` (reset, then this helper), only
    for the GitHub host, so no other host ever sees the token.
  - `GH_CONFIG_DIR` points at `github/gh`; `GH_TOKEN`, `GITHUB_TOKEN` and the
    enterprise variants are removed, since `gh` prefers them over its config.
  - `GIT_TERMINAL_PROMPT=0`.

  Files are written atomically (temp file, then rename), so a helper that runs
  during a refresh reads the old or the new token, never half of one. They are
  under the state root's run dir, outside the workspace, so an agent's
  `git add -A` never commits them, and nothing is written to `.git/config` or
  argv.

  A `409` (the run was fenced or has finished) or `404` (no `github_app`)
  stops refreshing; other failures are retried with backoff from 30 seconds
  up to five minutes. Tokens are never logged.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.GitHubApp.RunCredentials
  alias SymphonyElixir.PrivateFile
  alias SymphonyElixir.RunSpec

  @refresh_before_ms 15 * 60 * 1000
  @retry_base_ms 30_000
  @retry_max_ms 5 * 60 * 1000
  @request_timeout_ms 15_000
  @helper_name "git-credential"
  @token_env_names ~w(GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN)

  @type credentials :: %{token: String.t(), expires_at: DateTime.t()}

  @doc """
  Starts the keeper under its registered name.

  Options: `:run_id`, `:controller_url`, `:run_token`, `:host` (required);
  `:dir` (default `<run dir>/github`); `:initial` (credentials or nil);
  `:clock` (a zero-arity function returning a `DateTime`); `:refresh_before_ms`;
  `:retry_base_ms`; `:req_options` (extra `Req` options, e.g. a test plug);
  `:base_env` (the environment to rewrite, default `System.get_env/0`);
  `:apply_env` (a function given `[{name, value | nil}]`, default puts or deletes
  each in the OS environment); `:name` (default `#{inspect(__MODULE__)}`, or
  nil for none).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: do_start(:start_link, opts)

  @doc "`start_link/1` without a link: the runner keeps going if the keeper fails."
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: do_start(:start, opts)

  defp do_start(fun, opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> apply(GenServer, fun, [__MODULE__, opts])
      name -> apply(GenServer, fun, [__MODULE__, opts, [name: name]])
    end
  end

  @doc "Whether a keeper is running in this node (i.e. this is a runner with per-run tokens)."
  @spec active?() :: boolean()
  def active?, do: is_pid(Process.whereis(__MODULE__))

  @doc "The keeper's state without the token: `%{expires_at, next_refresh_ms, dir, helper}`."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Refreshes now (tests and diagnostics); returns `:ok` or the error."
  @spec refresh_now(GenServer.server()) :: :ok | {:error, term()}
  def refresh_now(server \\ __MODULE__), do: GenServer.call(server, :refresh_now, @request_timeout_ms + 5_000)

  @doc "Stops a running keeper, if any."
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__) do
    GenServer.stop(server, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  The token the controller handed over at launch, if any: `github-token.json`
  next to `spec_path` (deleted once read), else `GH_TOKEN` with
  `SYMPHONY_GITHUB_TOKEN_EXPIRES_AT` from `env`.
  """
  @spec initial_credentials(Path.t(), %{String.t() => String.t()}) :: credentials() | nil
  def initial_credentials(spec_path, env \\ System.get_env()) do
    file = RunSpec.github_token_path(spec_path)

    from_file =
      with {:ok, body} <- File.read(file),
           {:ok, %{"token" => token, "expires_at" => expires_at}} <- Jason.decode(body) do
        credentials(token, expires_at)
      else
        _ -> nil
      end

    _ = File.rm(file)
    from_file || credentials(Map.get(env, "GH_TOKEN"), Map.get(env, RunCredentials.expires_env()))
  end

  @doc """
  How long to wait before refreshing a token that expires at `expires_at`:
  zero once less than `refresh_before_ms` is left (or without a token).
  """
  @spec refresh_delay_ms(DateTime.t() | nil, DateTime.t(), non_neg_integer()) :: non_neg_integer()
  def refresh_delay_ms(nil, _now, _refresh_before_ms), do: 0

  def refresh_delay_ms(%DateTime{} = expires_at, %DateTime{} = now, refresh_before_ms) do
    max(DateTime.diff(expires_at, now, :millisecond) - refresh_before_ms, 0)
  end

  @doc """
  The environment changes that point git and `gh` at the files in `dir`, given
  the environment `base_env` the runner has: `{name, value}` to set and
  `{name, nil}` to remove.
  """
  @spec env_changes(%{String.t() => String.t()}, String.t(), Path.t()) :: [{String.t(), String.t() | nil}]
  def env_changes(base_env, host, dir) when is_map(base_env) and is_binary(host) do
    extra_header = String.downcase("http.https://#{host}/.extraHeader")
    helper_key = "credential.https://#{host}.helper"

    {kept, old_count} = git_config_entries(base_env)

    kept = Enum.reject(kept, fn {key, _value} -> String.downcase(key) == extra_header end)
    # An empty helper resets the list, so a host keychain or `gh auth git-credential`
    # configured for this host is not consulted before (or instead of) the run's token.
    entries = kept ++ [{helper_key, ""}, {helper_key, "!" <> shell_escape(Path.join(dir, @helper_name))}]
    count = length(entries)

    set =
      entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {{key, value}, index} -> [{"GIT_CONFIG_KEY_#{index}", key}, {"GIT_CONFIG_VALUE_#{index}", value}] end)

    # Leftover entries past the new count (the old header among them) are removed.
    stale =
      if old_count > count,
        do: Enum.flat_map(count..(old_count - 1)//1, &[{"GIT_CONFIG_KEY_#{&1}", nil}, {"GIT_CONFIG_VALUE_#{&1}", nil}]),
        else: []

    [{"GIT_CONFIG_COUNT", Integer.to_string(count)} | set] ++
      stale ++
      [{"GH_CONFIG_DIR", Path.join(dir, "gh")}, {"GIT_TERMINAL_PROMPT", "0"}, {RunCredentials.expires_env(), nil}] ++
      Enum.map(@token_env_names, &{&1, nil})
  end

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    host = Keyword.fetch!(opts, :host)
    dir = Keyword.get_lazy(opts, :dir, fn -> Path.join(RunSpec.dir(run_id), "github") end)

    state = %{
      run_id: run_id,
      host: host,
      dir: dir,
      controller_url: Keyword.fetch!(opts, :controller_url),
      run_token: Keyword.fetch!(opts, :run_token),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      refresh_before_ms: Keyword.get(opts, :refresh_before_ms, @refresh_before_ms),
      retry_base_ms: Keyword.get(opts, :retry_base_ms, @retry_base_ms),
      req_options: Keyword.get(opts, :req_options, []),
      token: nil,
      expires_at: nil,
      failures: 0,
      timer: nil,
      next_refresh_ms: nil,
      stopped: false
    }

    with :ok <- write_helper(dir),
         {:ok, state} <- store(state, Keyword.get(opts, :initial)) do
      base_env = Keyword.get_lazy(opts, :base_env, &System.get_env/0)
      apply_env = Keyword.get(opts, :apply_env, &apply_os_env/1)
      apply_env.(env_changes(base_env, host, dir))
      {:ok, schedule(state)}
    else
      {:error, reason} -> {:stop, {:github_token_files, reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       expires_at: state.expires_at,
       next_refresh_ms: state.next_refresh_ms,
       dir: state.dir,
       helper: Path.join(state.dir, @helper_name),
       stopped: state.stopped
     }, state}
  end

  def handle_call(:refresh_now, _from, state) do
    {result, state} = refresh(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    {_result, state} = refresh(%{state | timer: nil})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp refresh(state) do
    state = cancel_timer(state)

    case request_token(state) do
      {:ok, credentials} ->
        case store(state, credentials) do
          {:ok, state} ->
            Logger.info("GitHub App token refreshed run_id=#{state.run_id} expires_at=#{DateTime.to_iso8601(state.expires_at)}")
            {:ok, schedule(%{state | failures: 0})}

          {:error, reason} ->
            {{:error, reason}, retry(state, reason)}
        end

      {:error, reason} when reason in [:stale_epoch, :finished, :run_not_found, :github_app_not_configured] ->
        Logger.warning("GitHub App token refresh stopped run_id=#{state.run_id} reason=#{inspect(reason)}")
        {{:error, reason}, %{state | stopped: true, next_refresh_ms: nil}}

      {:error, reason} ->
        {{:error, reason}, retry(state, reason)}
    end
  end

  defp retry(state, reason) do
    delay = min(state.retry_base_ms * Integer.pow(2, min(state.failures, 10)), @retry_max_ms)
    Logger.warning("GitHub App token refresh failed run_id=#{state.run_id} retry_in_ms=#{delay} reason=#{inspect(reason, limit: 5)}")
    arm(%{state | failures: state.failures + 1}, delay)
  end

  defp schedule(state), do: arm(state, refresh_delay_ms(state.expires_at, state.clock.(), state.refresh_before_ms))

  defp arm(state, delay) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :refresh, delay), next_refresh_ms: delay}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp request_token(state) do
    url = String.trim_trailing(state.controller_url || "", "/") <> "/runner/v1/runs/#{URI.encode_www_form(state.run_id)}/github-token"

    request =
      [
        method: :post,
        url: url,
        headers: [{"authorization", "Bearer #{state.run_token}"}],
        json: %{},
        receive_timeout: @request_timeout_ms,
        retry: false
      ] ++ state.req_options

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: %{"token" => token, "expires_at" => expires_at}}} ->
        case credentials(token, expires_at) do
          nil -> {:error, :invalid_token_response}
          credentials -> {:ok, credentials}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, response_error(status, body)}

      {:error, %{__exception__: true} = exception} ->
        {:error, Exception.message(exception)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp response_error(409, %{"error" => "finished"}), do: :finished
  defp response_error(409, _body), do: :stale_epoch
  defp response_error(404, %{"error" => "github_app_not_configured"}), do: :github_app_not_configured
  defp response_error(404, _body), do: :run_not_found
  defp response_error(status, _body), do: {:http_status, status}

  defp store(state, nil), do: {:ok, state}

  defp store(state, %{token: token, expires_at: expires_at}) do
    with :ok <- PrivateFile.write(Path.join(state.dir, "token"), token),
         :ok <- PrivateFile.write(Path.join([state.dir, "gh", "hosts.yml"]), hosts_yml(state.host, token)) do
      {:ok, %{state | token: token, expires_at: expires_at}}
    end
  end

  # `gh` uses a host's `oauth_token` from its config when no GH_TOKEN-style
  # variable is set; the token is a quoted YAML scalar.
  defp hosts_yml(host, token) do
    """
    #{host}:
        oauth_token: #{Jason.encode!(token)}
        user: x-access-token
        git_protocol: https
    """
  end

  defp write_helper(dir) do
    helper = Path.join(dir, @helper_name)
    token_path = Path.join(dir, "token")

    script = """
    #!/bin/sh
    # Symphony run credential helper: answers git's `get` with the run's current
    # GitHub App installation token, which the runner refreshes in place.
    [ "$1" = get ] || exit 0
    token=$(cat #{shell_escape(token_path)} 2>/dev/null) || exit 0
    [ -n "$token" ] || exit 0
    printf 'username=x-access-token\\npassword=%s\\n' "$token"
    """

    with :ok <- PrivateFile.write(helper, script) do
      File.chmod(helper, 0o700)
    end
  end

  defp credentials(token, expires_at) when is_binary(token) and token != "" and is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _offset} -> %{token: token, expires_at: datetime}
      {:error, _reason} -> nil
    end
  end

  defp credentials(_token, _expires_at), do: nil

  defp git_config_entries(env) do
    count =
      with value when is_binary(value) <- Map.get(env, "GIT_CONFIG_COUNT"),
           {count, ""} when count >= 0 <- Integer.parse(String.trim(value)) do
        count
      else
        _ -> 0
      end

    entries =
      for index <- 0..(count - 1)//1,
          key = Map.get(env, "GIT_CONFIG_KEY_#{index}"),
          is_binary(key),
          do: {key, Map.get(env, "GIT_CONFIG_VALUE_#{index}", "")}

    {entries, count}
  end

  defp apply_os_env(changes) do
    Enum.each(changes, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
