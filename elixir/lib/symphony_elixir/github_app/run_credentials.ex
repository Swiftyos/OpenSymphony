defmodule SymphonyElixir.GitHubApp.RunCredentials do
  @moduledoc """
  The controller side of per-run GitHub App tokens for runners that are not
  in-process (`agent.launcher: process` and `kubernetes`).

  The App private key stays in the controller. At launch the controller mints
  an installation token limited to the run's home repository and to
  `github_app.permissions` (the allowlist in `SymphonyElixir.GitHubApp`; never
  `workflows` or `administration`), and hands it to the runner:

  - a pod gets it in its run Secret (`run-<id>`), as `GH_TOKEN` and a
    `GIT_CONFIG_*` `http.<host>.extraHeader`, referenced by `secretKeyRef`
    (never in argv, the pod spec, or `.git/config`);
  - a process runner gets it in `github-token.json` next to its spec
    (owner-only), because a `systemd-run` unit does not inherit the
    controller's environment.

  Either way the spec only carries `github_host`, the sign that the runner
  should keep the token fresh through `POST /runner/v1/runs/:run_id/github-token`
  (`SymphonyElixir.GitHubApp.RunnerToken`). A mint that fails at launch is
  logged and the run still starts with `github_host` set: the runner then asks
  the endpoint for its first token.

  Reference repos get no token here: a runner reads them through the
  controller's read-only git mirror.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubApp
  alias SymphonyElixir.PrivateFile
  alias SymphonyElixir.RunSpec

  @expires_env "SYMPHONY_GITHUB_TOKEN_EXPIRES_AT"

  @type t :: %{token: String.t(), expires_at: DateTime.t(), host: String.t()}

  @doc "The environment variable that carries a pod's token expiry."
  @spec expires_env() :: String.t()
  def expires_env, do: @expires_env

  @doc """
  Sets the spec's `github_host` and mints the run's token when `github_app`
  is configured. Returns the spec and the credentials (nil without
  `github_app`, or when the mint failed).

  `opts` go to `SymphonyElixir.GitHubApp.token_for_run/2` (`:plug`, `:cache`,
  `:clock`, ...).
  """
  @spec attach(RunSpec.t(), Schema.t(), keyword()) :: {RunSpec.t(), t() | nil}
  def attach(%RunSpec{} = spec, %Schema{} = settings, opts \\ []) do
    if GitHubApp.configured?(settings) do
      host = GitHubApp.git_host(settings.github_app)
      spec = %{spec | github_host: host}

      case GitHubApp.token_for_run(spec, Keyword.put(opts, :settings, settings)) do
        {:ok, %{token: token, expires_at: expires_at}} ->
          {spec, %{token: token, expires_at: expires_at, host: host}}

        {:error, reason} ->
          Logger.warning("GitHub App token unavailable at launch; the runner will request one run_id=#{spec.run_id} reason=#{inspect(reason, limit: 5)}")

          {spec, nil}
      end
    else
      {spec, nil}
    end
  end

  @doc """
  The runner's environment for these credentials: `GH_TOKEN`, git's
  `http.<host>.extraHeader` through `GIT_CONFIG_*`, `GIT_TERMINAL_PROMPT=0`,
  and `#{@expires_env}` (ISO 8601), in a fixed order.
  """
  @spec env(t() | nil) :: [{String.t(), String.t()}]
  def env(nil), do: []

  def env(%{token: token, expires_at: expires_at, host: host}) do
    GitHubApp.git_env(token, host: host) ++ [{@expires_env, DateTime.to_iso8601(expires_at)}]
  end

  @doc "Writes a process runner's `github-token.json` next to `spec_path` (owner-only)."
  @spec write_file(Path.t(), t() | nil) :: :ok | {:error, term()}
  def write_file(_spec_path, nil), do: :ok

  def write_file(spec_path, %{token: token, expires_at: expires_at, host: host}) do
    document = %{"token" => token, "expires_at" => DateTime.to_iso8601(expires_at), "host" => host}
    PrivateFile.write(RunSpec.github_token_path(spec_path), Jason.encode!(document))
  end

  @doc """
  The token a runner gets back from the refresh endpoint, as JSON: the run's
  home repository only, with the configured permissions.
  """
  @spec refresh(RunSpec.t(), Schema.t(), keyword()) ::
          {:ok, %{String.t() => String.t()}} | {:error, :github_app_not_configured | term()}
  def refresh(%RunSpec{} = spec, %Schema{} = settings, opts \\ []) do
    if GitHubApp.configured?(settings) do
      case GitHubApp.token_for_run(spec, Keyword.put(opts, :settings, settings)) do
        {:ok, %{token: token, expires_at: expires_at}} ->
          {:ok,
           %{
             "token" => token,
             "expires_at" => DateTime.to_iso8601(expires_at),
             "host" => GitHubApp.git_host(settings.github_app)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :github_app_not_configured}
    end
  end
end
