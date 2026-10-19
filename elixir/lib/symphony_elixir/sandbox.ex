defmodule SymphonyElixir.Sandbox do
  @moduledoc """
  Optional per-issue container isolation for agent processes and workspace hooks.

  With `sandbox.kind: docker`, each workspace gets one long-lived container that
  bind-mounts the workspace at the same absolute path. Hooks and the agent CLI run
  inside it through `docker exec`, so builds, installed tools, background services
  and ports from one issue cannot interfere with another. Git bootstrap still runs
  on the host (it needs host credentials), and because each workspace is a
  standalone clone its `.git` directory is fully contained in the mount.

  The container lives until the workspace is removed, so dependencies installed
  by `after_create` persist across agent runs for the same issue.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

  @sleep_command ["sleep", "infinity"]

  @spec enabled?(Schema.t() | nil) :: boolean()
  def enabled?(settings \\ nil) do
    settings = settings || Config.settings!()
    settings.sandbox.kind == "docker"
  end

  @doc """
  Rejects combinations the sandbox cannot serve, before any work starts.
  """
  @spec validate_run(String.t() | nil, String.t() | nil, Schema.t() | nil) :: :ok | {:error, term()}
  def validate_run(backend, worker_host, settings \\ nil) do
    settings = settings || Config.settings!()

    cond do
      not enabled?(settings) -> :ok
      is_binary(worker_host) -> {:error, {:sandbox_unsupported, :ssh_worker_host, worker_host}}
      # OpenCode is driven over a localhost HTTP port that is not reachable
      # through `docker exec` stdio.
      backend == "opencode" -> {:error, {:sandbox_unsupported, :backend, backend}}
      true -> :ok
    end
  end

  @spec container_name(Path.t()) :: String.t()
  def container_name(workspace) when is_binary(workspace) do
    expanded = Path.expand(workspace)
    hash = :crypto.hash(:sha256, expanded) |> Base.encode16(case: :lower) |> binary_part(0, 10)
    base = expanded |> Path.basename() |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")
    "symphony-#{base}-#{hash}"
  end

  @doc """
  Starts (or restarts) the workspace container. Idempotent.
  """
  @spec ensure_container(Path.t(), Schema.t() | nil) :: :ok | {:error, term()}
  def ensure_container(workspace, settings \\ nil) when is_binary(workspace) do
    settings = settings || Config.settings!()
    name = container_name(workspace)

    case docker(settings, ["inspect", "--format", "{{.State.Running}}", name]) do
      {"true" <> _, 0} ->
        :ok

      {"false" <> _, 0} ->
        docker_ok(settings, ["start", name], :sandbox_start_failed)

      {_output, _status} ->
        Logger.info("Starting sandbox container name=#{name} image=#{settings.sandbox.image} workspace=#{workspace}")
        docker_ok(settings, run_args(workspace, name, settings), :sandbox_create_failed)
    end
  end

  @spec remove_container(Path.t(), Schema.t() | nil) :: :ok
  def remove_container(workspace, settings \\ nil) when is_binary(workspace) do
    settings = settings || Config.settings!()

    if enabled?(settings) do
      docker(settings, ["rm", "--force", container_name(workspace)])
    end

    :ok
  end

  @doc """
  Returns the executable and arguments that run `command` in the workspace,
  inside the sandbox when enabled. Environment variables are passed by name so
  secret values never appear in the process list; the caller sets them on the
  spawned `docker` client process.
  """
  @spec command_spec(Path.t(), String.t(), [String.t()], keyword()) ::
          {:ok, %{executable: String.t(), args: [String.t()], cd: Path.t() | nil}} | {:error, term()}
  def command_spec(workspace, command, env_names, opts \\ []) when is_binary(workspace) and is_binary(command) do
    settings = Keyword.get(opts, :settings) || Config.settings!()
    shell = Keyword.get(opts, :shell, "bash")

    if enabled?(settings) do
      with :ok <- ensure_container(workspace, settings),
           {:ok, executable} <- docker_executable(settings) do
        env_args = Enum.flat_map(Enum.uniq(env_names ++ passthrough_env_names(settings)), &["--env", &1])

        {:ok,
         %{
           executable: executable,
           args: ["exec", "--interactive", "--workdir", workspace] ++ env_args ++ [container_name(workspace), shell, "-lc", command],
           cd: nil
         }}
      end
    else
      case System.find_executable(shell) do
        nil -> {:error, if(shell == "bash", do: :bash_not_found, else: :sh_not_found)}
        executable -> {:ok, %{executable: executable, args: ["-lc", command], cd: workspace}}
      end
    end
  end

  defp run_args(workspace, name, settings) do
    sandbox = settings.sandbox

    mounts =
      [workspace, settings.accounts.store_root]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(&["--volume", "#{&1}:#{&1}"])

    extra_mounts = Enum.flat_map(sandbox.mounts, &["--volume", expand_mount(&1)])
    network = if is_binary(sandbox.network), do: ["--network", sandbox.network], else: []

    ["run", "--detach", "--init", "--name", name, "--label", "symphony.workspace=#{workspace}", "--workdir", workspace] ++
      mounts ++ extra_mounts ++ network ++ sandbox.run_args ++ ["--entrypoint", hd(@sleep_command), sandbox.image] ++ tl(@sleep_command)
  end

  defp expand_mount(mount) when is_binary(mount) do
    case String.split(mount, ":", parts: 2) do
      [host, rest] -> Path.expand(host) <> ":" <> rest
      [host] -> Path.expand(host) <> ":" <> Path.expand(host)
    end
  end

  defp passthrough_env_names(settings) do
    Enum.filter(settings.sandbox.env, &is_binary(System.get_env(&1)))
  end

  defp docker_ok(settings, args, error_tag) do
    case docker(settings, args) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {error_tag, status, String.slice(output, 0, 2_048)}}
    end
  end

  defp docker(settings, args) do
    case docker_executable(settings) do
      {:ok, executable} -> System.cmd(executable, args, stderr_to_stdout: true)
      {:error, reason} -> {inspect(reason), 127}
    end
  end

  defp docker_executable(settings) do
    command = settings.sandbox.command

    case System.find_executable(command) do
      nil -> {:error, {:sandbox_command_not_found, command}}
      executable -> {:ok, executable}
    end
  end
end
