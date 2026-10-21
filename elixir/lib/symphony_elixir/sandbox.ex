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
  # Tags every process started through the sandbox so `reap/2` can find leftovers.
  @exec_marker "SYMPHONY_SANDBOX_EXEC=1"

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
  The per-issue network used when the resolved environment declares services.
  """
  @spec network_name(Path.t()) :: String.t()
  def network_name(workspace) when is_binary(workspace), do: container_name(workspace) <> "-net"

  @doc """
  The sibling container name for a service: `<container>-<service>`.
  """
  @spec service_container_name(Path.t() | String.t(), String.t()) :: String.t()
  def service_container_name(workspace, service) when is_binary(workspace) and is_binary(service),
    do: container_name(workspace) <> "-" <> service

  @doc """
  Starts (or restarts) the workspace container and its environment services.
  Idempotent.
  """
  @spec ensure_container(Path.t(), Schema.t() | nil, keyword()) :: :ok | {:error, term()}
  def ensure_container(workspace, settings \\ nil, opts \\ []) when is_binary(workspace) do
    settings = settings || Config.settings!()
    environment = environment(settings, opts)
    name = container_name(workspace)

    with :ok <- ensure_network(settings, workspace, name, environment),
         {:ok, created?} <- ensure_main_container(settings, workspace, name, environment),
         :ok <- ensure_services(settings, workspace, name, environment) do
      if created?, do: run_setup(settings, workspace, environment), else: :ok
    end
  end

  @spec remove_container(Path.t(), Schema.t() | nil, keyword()) :: :ok
  def remove_container(workspace, settings \\ nil, opts \\ []) when is_binary(workspace) do
    settings = settings || Config.settings!()
    environment = environment(settings, opts)

    if enabled?(settings) do
      name = container_name(workspace)

      if environment_configured?(settings, environment) do
        remove_service_containers(settings, name)
      end

      docker(settings, ["rm", "--force", name])

      if environment_configured?(settings, environment) do
        docker(settings, ["network", "rm", network_name(workspace)])
      end
    end

    :ok
  end

  defp ensure_main_container(settings, workspace, name, environment) do
    case docker(settings, ["inspect", "--format", "{{.State.Running}}", name]) do
      {"true" <> _, 0} ->
        {:ok, false}

      {"false" <> _, 0} ->
        with :ok <- docker_ok(settings, ["start", name], :sandbox_start_failed), do: {:ok, false}

      {_output, _status} ->
        image = environment_attr(environment, :image) || settings.sandbox.image
        Logger.info("Starting sandbox container name=#{name} image=#{image} workspace=#{workspace}")

        with :ok <- docker_ok(settings, run_args(workspace, name, settings, environment), :sandbox_create_failed) do
          {:ok, true}
        end
    end
  end

  defp run_setup(_settings, _workspace, environment) when environment in [nil, %{}], do: :ok

  defp run_setup(settings, workspace, environment) do
    Enum.reduce_while(setup_commands(environment), :ok, fn command, :ok ->
      args = ["exec", "--workdir", workspace, container_name(workspace), "sh", "-lc", command]

      case docker_ok(settings, args, :sandbox_setup_failed) do
        :ok ->
          {:cont, :ok}

        {:error, _reason} = error ->
          # Do not leave a half-prepared container behind: the next dispatch
          # must create it again and retry the setup commands.
          remove_container(workspace, settings, environment: environment)
          {:halt, error}
      end
    end)
  end

  defp ensure_network(_settings, _workspace, _name, environment) when environment in [nil, %{}],
    do: :ok

  defp ensure_network(settings, workspace, _name, environment) do
    if services(environment) == [] do
      :ok
    else
      network = network_name(workspace)

      case docker(settings, ["network", "inspect", network]) do
        {_output, 0} ->
          :ok

        {_output, _status} ->
          docker_ok(
            settings,
            ["network", "create", "--label", "symphony.workspace=#{workspace}", network],
            :sandbox_network_create_failed
          )
      end
    end
  end

  defp ensure_services(_settings, _workspace, _name, environment) when environment in [nil, %{}],
    do: :ok

  defp ensure_services(settings, workspace, name, environment) do
    Enum.reduce_while(services(environment), :ok, fn service, :ok ->
      case ensure_service(settings, workspace, name, service) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_service(settings, workspace, name, service) do
    service_name = service_attr(service, :name)
    service_container = service_container_name(workspace, service_name)

    case docker(settings, ["inspect", "--format", "{{.State.Running}}", service_container]) do
      {"true" <> _, 0} ->
        :ok

      {"false" <> _, 0} ->
        docker_ok(settings, ["start", service_container], :sandbox_service_start_failed)

      {_output, _status} ->
        Logger.info("Starting sandbox service container name=#{service_container} image=#{service_attr(service, :image)} workspace=#{workspace}")

        docker_ok(settings, service_run_args(workspace, name, service), :sandbox_service_create_failed)
    end
  end

  defp remove_service_containers(settings, name) do
    case docker(settings, ["ps", "-aq", "--filter", "label=symphony.service-of=#{name}"]) do
      {output, 0} ->
        case output |> String.split() |> Enum.reject(&(&1 == "")) do
          [] -> :ok
          ids -> docker(settings, ["rm", "--force" | ids])
        end

      {_output, _status} ->
        :ok
    end
  end

  @doc """
  Returns the executable and arguments that run `command` in the workspace,
  inside the sandbox when enabled. Environment variables are passed by name so
  secret values never appear in the process list; the caller sets them on the
  spawned `docker` client process.
  """
  @spec command_spec(Path.t(), String.t(), [String.t()]) ::
          {:ok, %{executable: String.t(), args: [String.t()], cd: Path.t() | nil}} | {:error, term()}
  def command_spec(workspace, command, env_names), do: command_spec(workspace, command, env_names, [])

  @spec command_spec(Path.t(), String.t(), [String.t()], keyword()) ::
          {:ok, %{executable: String.t(), args: [String.t()], cd: Path.t() | nil}} | {:error, term()}
  def command_spec(workspace, command, env_names, opts) when is_binary(workspace) and is_binary(command) do
    settings = Keyword.get(opts, :settings) || Config.settings!()
    shell = Keyword.get(opts, :shell, "bash")

    if enabled?(settings) do
      with :ok <- ensure_container(workspace, settings, environment: Keyword.get(opts, :environment)),
           {:ok, executable} <- docker_executable(settings) do
        env_args = ["--env", @exec_marker | Enum.flat_map(Enum.uniq(env_names ++ passthrough_env_names(settings)), &["--env", &1])]

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

  @doc """
  Kills processes that `command_spec/4` started in the workspace container and
  that outlived their `docker exec` client. Podman ends them with the client,
  but Docker can leave them running inside the long-lived container.
  """
  @spec reap(Path.t(), Schema.t() | nil, keyword()) :: :ok
  def reap(workspace, settings \\ nil, opts \\ []) when is_binary(workspace) do
    settings = settings || Config.settings!()
    environment = environment(settings, opts)

    if enabled?(settings) do
      # Busybox-friendly: only /proc, tr, and grep. The reaper itself is not tagged.
      script =
        "for p in /proc/[0-9]*; do " <>
          ~s[tr '\\0' '\\n' < "$p/environ" 2>/dev/null | grep -qx '#{@exec_marker}' && kill -TERM "${p#/proc/}" 2>/dev/null; ] <>
          "done; true"

      docker(settings, ["exec", container_name(workspace), "sh", "-c", script])
      stop_services(settings, workspace, environment)
    end

    :ok
  end

  defp stop_services(_settings, _workspace, environment) when environment in [nil, %{}], do: :ok

  defp stop_services(settings, workspace, environment) do
    Enum.each(services(environment), fn service ->
      docker(settings, ["stop", service_container_name(workspace, service_attr(service, :name))])
    end)
  end

  defp run_args(workspace, name, settings, environment) do
    sandbox = settings.sandbox

    mounts =
      [workspace, settings.accounts.store_root]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(&["--volume", "#{&1}:#{&1}"])

    extra_mounts = Enum.flat_map(sandbox.mounts, &["--volume", expand_mount(&1)])
    network = network_args(workspace, settings, environment)
    image = environment_attr(environment, :image) || sandbox.image

    ["run", "--detach", "--init", "--name", name, "--label", "symphony.workspace=#{workspace}", "--workdir", workspace] ++
      mounts ++
      extra_mounts ++
      network ++
      sandbox.run_args ++
      resource_args(environment) ++ ["--entrypoint", hd(@sleep_command), image] ++ tl(@sleep_command)
  end

  defp network_args(workspace, settings, environment) do
    if services(environment) == [] do
      if is_binary(settings.sandbox.network), do: ["--network", settings.sandbox.network], else: []
    else
      ["--network", network_name(workspace)]
    end
  end

  defp resource_args(environment) do
    resources = environment_attr(environment, :resources) || %{}

    cpu =
      case environment_attr(resources, :cpu) do
        nil -> []
        value -> ["--cpus", to_string(value)]
      end

    memory =
      case environment_attr(resources, :memory) do
        nil -> []
        value -> ["--memory", to_string(value)]
      end

    cpu ++ memory
  end

  defp service_run_args(workspace, name, service) do
    service_name = service_attr(service, :name)

    ["run", "--detach", "--name", service_container_name(workspace, service_name)] ++
      ["--label", "symphony.workspace=#{workspace}", "--label", "symphony.service-of=#{name}"] ++
      ["--network", network_name(workspace), "--network-alias", service_name] ++
      service_env_args(service) ++
      service_port_args(service) ++
      [service_attr(service, :image)] ++
      service_command(service)
  end

  defp service_env_args(service) do
    service
    |> service_attr(:env)
    |> case do
      %{} = env ->
        env
        |> Enum.sort()
        |> Enum.flat_map(fn {key, value} -> ["--env", "#{key}=#{value}"] end)

      _env ->
        []
    end
  end

  defp service_port_args(service) do
    service
    |> service_attr(:ports)
    |> List.wrap()
    |> Enum.flat_map(fn port -> ["--expose", to_string(port)] end)
  end

  defp service_command(service) do
    service
    |> service_attr(:command)
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp expand_mount(mount) when is_binary(mount) do
    case String.split(mount, ":", parts: 2) do
      [host, rest] -> Path.expand(host) <> ":" <> rest
      [host] -> Path.expand(host) <> ":" <> Path.expand(host)
    end
  end

  defp environment(settings, opts) do
    Keyword.get(opts, :environment) || settings.sandbox.environment
  end

  defp environment_configured?(settings, environment) do
    not is_nil(environment) or (is_map(settings.environments) and map_size(settings.environments) > 0)
  end

  defp services(environment) do
    case environment_attr(environment, :services) do
      services when is_list(services) -> services
      _services -> []
    end
  end

  defp setup_commands(environment) do
    case environment_attr(environment, :setup) do
      setup when is_list(setup) -> Enum.filter(setup, &is_binary/1)
      _setup -> []
    end
  end

  defp environment_attr(nil, _key), do: nil

  defp environment_attr(%{} = environment, key) do
    Map.get(environment, key) || Map.get(environment, to_string(key))
  end

  defp environment_attr(_environment, _key), do: nil

  defp service_attr(%{} = service, key) do
    Map.get(service, key) || Map.get(service, to_string(key))
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
