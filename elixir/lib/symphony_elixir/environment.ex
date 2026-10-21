defmodule SymphonyElixir.Environment do
  @moduledoc """
  The per-issue agent environment: the container image, resource limits, and
  sibling services a run gets.

  Names are resolved in this order, first non-blank wins: a factory stage's
  `environment`, the Linear project route's `environment`, the team default
  (`teams:` keyed by the issue identifier prefix), then `default`. Each name
  refers to an entry in the platform catalog (`environments:` in `symphony.yml`).

  The platform catalog owns every security bound. A repository's
  `.symphony/environment.yaml` (read from the repo cache at its default branch)
  may choose an image only from the catalog's `allowed_images` prefixes, and may
  lower but never raise `resources` past the catalog entry's values. Service
  images must also be in `allowed_images`; the catalog caps the number of
  services (`max_services`, default 4) and each service's `cpu`/`memory`
  (`service_resources`, default 1 CPU and 1g), which a service may lower.
  A repo service with the same name as a catalog service replaces it.

  An invalid or disallowed file fails closed: `resolve/3` returns an error, no
  container is created, and the controller reports the error. There is no
  silent fallback to a wider environment.

  The resolved struct carries a content `digest`, stable for the same image,
  resources, services, setup commands, and egress extras, for caching and pod
  reuse.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.IssueStage
  alias SymphonyElixir.Workspace

  @service_name_pattern ~r/^[a-z][a-z0-9-]{0,62}$/
  @env_name_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @repo_keys MapSet.new(["image", "services", "resources", "setup"])
  @service_keys MapSet.new(["name", "image", "env", "ports", "command", "resources"])
  @resource_keys ["cpu", "memory"]
  @default_max_services 4
  @default_service_resources %{"cpu" => 1, "memory" => "1g"}
  # The smallest limit Docker and Podman accept for `--memory`.
  @min_memory_bytes 6 * 1024 * 1024
  @rejection_report_interval_ms 60 * 60 * 1_000
  @port_pattern ~r/^(\d{1,5})(?:\/(?:tcp|udp))?$/
  @repo_file Path.join(".symphony", "environment.yaml")

  defstruct [
    :name,
    :image,
    :resources,
    :services,
    :setup,
    :egress_extra,
    :digest,
    :repo_file
  ]

  @type service :: %{
          name: String.t(),
          image: String.t(),
          env: %{optional(String.t()) => String.t()},
          ports: [String.t()],
          command: [String.t()],
          resources: %{optional(String.t()) => number() | String.t()}
        }

  @type t :: %__MODULE__{
          name: String.t(),
          image: String.t(),
          resources: %{optional(String.t()) => number() | String.t()},
          services: [service()],
          setup: [String.t()],
          egress_extra: [String.t()],
          digest: String.t(),
          repo_file: boolean()
        }

  @doc """
  Resolves the issue's environment against the platform catalog and its repo
  file. Options: `:route` (a project route already resolved at dispatch) and
  `:repo_root` (the cache clone, for tests; otherwise fetched through
  `Workspace.ensure_local_repo_cache/2`).
  """
  @spec resolve(map(), Schema.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(issue, settings, opts \\ [])

  def resolve(issue, %Schema{} = settings, opts) do
    catalog = normalize_catalog(settings.environments)

    with true <- map_size(catalog) > 0,
         {:ok, name} <- resolve_name(issue, settings, catalog, opts),
         {:ok, entry} <- catalog_entry(catalog, name),
         {:ok, repo_doc, repo_path} <- read_repo_file(issue, settings, opts),
         {:ok, resolved} <- build(name, entry, repo_doc, repo_path) do
      {:ok, struct(__MODULE__, Map.put(resolved, :digest, digest(resolved)))}
    else
      false -> {:error, {:environments_not_configured, Map.keys(normalize_catalog(settings.environments))}}
      {:error, _reason} = error -> error
    end
  end

  def resolve(_issue, _settings, _opts), do: {:error, :invalid_environment_settings}

  @doc """
  Like `resolve/3`, but returns `{:ok, nil}` when the platform has no catalog,
  so a deployment without environments keeps today's sandbox behaviour.
  """
  @spec resolve_optional(map(), Schema.t(), keyword()) :: {:ok, t() | nil} | {:error, term()}
  def resolve_optional(issue, settings, opts \\ []) do
    if configured?(settings), do: resolve(issue, settings, opts), else: {:ok, nil}
  end

  @spec configured?(Schema.t() | nil) :: boolean()
  def configured?(%Schema{environments: environments}) when is_map(environments),
    do: map_size(environments) > 0

  def configured?(_settings), do: false

  @doc """
  The resolved environment as a plain string-keyed map, suitable for a
  `RunSpec` and for a Kubernetes launcher rendering init containers/sidecars.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = environment) do
    %{
      "name" => environment.name,
      "image" => environment.image,
      "resources" => environment.resources,
      "services" => environment.services,
      "setup" => environment.setup,
      "egress_extra" => environment.egress_extra,
      "digest" => environment.digest,
      "repo_file" => environment.repo_file
    }
  end

  @doc """
  A human-readable reason for a failed resolution, for logs and transcripts.
  """
  @spec format_error(term()) :: String.t()
  def format_error({:invalid_repo_environment, path, message}), do: "repository environment #{path}: #{message}"
  def format_error({:repo_environment_unreadable, path, reason}), do: "repository environment #{path} is unreadable: #{inspect(reason)}"

  def format_error({:unknown_environment, name, available}) do
    "environment #{inspect(name)} is not in the platform catalog (available: #{Enum.join(available, ", ")})"
  end

  def format_error({:environments_not_configured, _available}), do: "the platform catalog has no environments"

  def format_error({:invalid_environment_catalog, name, message}), do: "catalog environment #{inspect(name)}: #{message}"
  def format_error(:invalid_environment_settings), do: "invalid environment settings"
  def format_error(other), do: inspect(other, limit: 10)

  @doc """
  Decides whether a rejected environment is reported (logged and noted on the
  transcript) or suppressed. An invalid environment is resolved again on every
  poll; each distinct `{issue_id, message}` is reported once, then at most once
  per `interval_ms` (an hour by default). `seen` maps those keys to the last
  report time and is pruned of entries older than the interval.
  """
  @spec note_rejection(map(), String.t() | nil, String.t(), integer(), pos_integer()) :: {:report | :suppress, map()}
  def note_rejection(seen, issue_id, message, now_ms, interval_ms \\ @rejection_report_interval_ms)
      when is_map(seen) and is_integer(now_ms) do
    seen = Map.filter(seen, fn {_key, reported_at} -> now_ms - reported_at < interval_ms end)
    key = {issue_id, message}

    if Map.has_key?(seen, key), do: {:suppress, seen}, else: {:report, Map.put(seen, key, now_ms)}
  end

  # ---------------------------------------------------------------- name resolution

  defp resolve_name(issue, settings, catalog, opts) do
    route = route_for(issue, settings, opts)

    candidates = [
      {"stage", stage_environment(issue, settings)},
      {"project route", route_environment(route)},
      {"team", Config.team_environment(IssueStage.team(issue), settings)},
      {"default", default_environment(catalog)}
    ]

    case Enum.find(candidates, fn {_source, name} -> present?(name) end) do
      {_source, name} -> {:ok, name |> String.trim() |> String.downcase()}
      nil -> {:error, {:unknown_environment, nil, Map.keys(catalog) |> Enum.sort()}}
    end
  end

  defp stage_environment(issue, settings) do
    case IssueStage.stage_definition(issue, settings) do
      %{"environment" => environment} -> environment
      _stage -> nil
    end
  end

  defp route_for(issue, settings, opts) do
    case Keyword.get(opts, :route) do
      %{} = route -> route
      _route -> Config.linear_project_route(issue, settings)
    end
  end

  defp route_environment(nil), do: nil
  defp route_environment(route) when is_map(route), do: map_get(route, :environment)

  defp default_environment(catalog) do
    if Map.has_key?(catalog, "default"), do: "default", else: nil
  end

  defp catalog_entry(catalog, name) do
    case Map.fetch(catalog, name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_environment, name, Map.keys(catalog) |> Enum.sort()}}
    end
  end

  # ---------------------------------------------------------------- catalog normalization

  defp normalize_catalog(environments) when is_map(environments) do
    Map.new(environments, fn {name, entry} -> {name |> to_string() |> String.trim() |> String.downcase(), entry} end)
  end

  defp normalize_catalog(_environments), do: %{}

  defp normalize_catalog_entry(name, entry) when is_map(entry) do
    image = map_get(entry, :image)
    resources = map_get(entry, :resources) || %{}
    allowed_images = list_of_strings(map_get(entry, :allowed_images) || [])
    egress_extra = list_of_strings(map_get(entry, :egress_extra) || [])
    setup = list_of_strings(map_get(entry, :setup) || [])
    error_context = {:invalid_environment_catalog, name}

    with {:ok, image} <- required_image(image, {:invalid_environment_catalog, name, "needs an image"}),
         :ok <- ensure_map(resources, {:invalid_environment_catalog, name, "resources must be a map"}),
         :ok <- validate_catalog_resources(resources, name),
         :ok <- validate_allowed_images(allowed_images, name),
         {:ok, max_services} <- max_services(map_get(entry, :max_services), name),
         {:ok, service_bounds} <- service_bounds(map_get(entry, :service_resources), name),
         {:ok, services} <- normalize_services(map_get(entry, :services) || [], :any, service_bounds, error_context),
         :ok <- enforce_service_count(services, max_services, error_context) do
      {:ok,
       %{
         name: name,
         image: image,
         resources: resources_map(resources),
         allowed_images: allowed_images,
         max_services: max_services,
         service_resources: service_bounds,
         services: services,
         setup: setup,
         egress_extra: egress_extra
       }}
    end
  end

  defp normalize_catalog_entry(name, _entry),
    do: {:error, {:invalid_environment_catalog, name, "must be a map"}}

  defp validate_catalog_resources(resources, name) do
    resources = resources_map(resources)

    Enum.reduce_while(resources, :ok, fn {key, value}, :ok ->
      if valid_catalog_resource?(key, value) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_environment_catalog, name, "resources must set a positive cpu and a memory size of at least 6m, such as 4g"}}}
      end
    end)
  end

  defp valid_catalog_resource?("cpu", value), do: is_number(parse_cpu(value))
  defp valid_catalog_resource?("memory", value), do: match?({:ok, _bytes}, parse_memory(value))
  defp valid_catalog_resource?(_key, _value), do: false

  # A prefix that does not end at a path, tag, or digest boundary would let
  # `registry.example.com/agents` also allow `registry.example.com/agents-evil/...`.
  defp validate_allowed_images(allowed_images, name) do
    case Enum.reject(allowed_images, &String.ends_with?(&1, ["/", ":", "@"])) do
      [] ->
        :ok

      invalid ->
        {:error, {:invalid_environment_catalog, name, "allowed_images entries must end in /, : or @ (got #{Enum.join(invalid, ", ")})"}}
    end
  end

  defp max_services(nil, _name), do: {:ok, @default_max_services}
  defp max_services(value, _name) when is_integer(value) and value >= 0, do: {:ok, value}

  defp max_services(_value, name),
    do: {:error, {:invalid_environment_catalog, name, "max_services must be a non-negative integer"}}

  defp service_bounds(nil, _name), do: {:ok, @default_service_resources}

  defp service_bounds(%{} = raw, name) do
    resources = resources_map(raw)

    if Enum.all?(resources, fn {key, value} -> valid_catalog_resource?(key, value) end) do
      {:ok, Map.merge(@default_service_resources, resources)}
    else
      {:error, {:invalid_environment_catalog, name, "service_resources must set a positive cpu and a memory size such as 1g"}}
    end
  end

  defp service_bounds(_raw, name),
    do: {:error, {:invalid_environment_catalog, name, "service_resources must be a map"}}

  defp enforce_service_count(services, max_services, error_context) do
    if length(services) <= max_services do
      :ok
    else
      {:error, error(error_context, "declares #{length(services)} services; the catalog allows at most #{max_services}")}
    end
  end

  # ---------------------------------------------------------------- repo file

  defp read_repo_file(issue, settings, opts) do
    route = route_for(issue, settings, opts)

    with {:ok, repo_root} <- repo_root(route, settings, opts) do
      read_repo_yaml(if(repo_root, do: Path.join(repo_root, @repo_file), else: nil))
    end
  end

  defp repo_root(nil, _settings, _opts), do: {:ok, nil}

  defp repo_root(route, settings, opts) do
    case Keyword.get(opts, :repo_root) do
      repo_root when is_binary(repo_root) ->
        {:ok, repo_root}

      nil ->
        case map_get(route, :repo) do
          repo when is_binary(repo) and repo != "" -> Workspace.ensure_local_repo_cache(route, settings)
          _repo -> {:ok, nil}
        end
    end
  end

  defp read_repo_yaml(nil), do: {:ok, nil, nil}

  defp read_repo_yaml(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, nil, path}

      {:error, reason} ->
        {:error, {:repo_environment_unreadable, path, reason}}

      {:ok, body} ->
        case YamlElixir.read_from_string(body) do
          {:ok, document} when is_nil(document) or is_map(document) ->
            {:ok, document, path}

          {:ok, _other} ->
            {:error, {:invalid_repo_environment, path, "must be a map"}}

          {:error, reason} ->
            {:error, {:invalid_repo_environment, path, "is not valid YAML: #{inspect(reason, limit: 3)}"}}
        end
    end
  end

  # ---------------------------------------------------------------- resolution

  defp build(name, entry, repo_doc, repo_path) do
    with {:ok, catalog} <- normalize_catalog_entry(name, entry),
         :ok <- validate_repo_keys(repo_doc, repo_path),
         {:ok, image} <- resolve_image(catalog, repo_doc, repo_path),
         {:ok, resources} <- resolve_resources(catalog, repo_doc, repo_path),
         {:ok, services} <- resolve_services(catalog, repo_doc, repo_path),
         {:ok, setup} <- resolve_setup(catalog, repo_doc, repo_path) do
      {:ok,
       %{
         name: name,
         image: image,
         resources: resources,
         services: services,
         setup: setup,
         egress_extra: catalog.egress_extra,
         repo_file: not is_nil(repo_doc)
       }}
    end
  end

  defp validate_repo_keys(nil, _path), do: :ok

  defp validate_repo_keys(document, path) do
    unknown =
      document
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&MapSet.member?(@repo_keys, &1))
      |> Enum.sort()

    if unknown == [] do
      :ok
    else
      {:error, {:invalid_repo_environment, path, "unknown keys: #{Enum.join(unknown, ", ")}"}}
    end
  end

  defp resolve_image(catalog, nil, _path), do: {:ok, catalog.image}

  defp resolve_image(catalog, document, path) do
    case map_get(document, :image) do
      nil ->
        {:ok, catalog.image}

      image when is_binary(image) ->
        image = String.trim(image)

        cond do
          image == "" ->
            {:ok, catalog.image}

          allowed_image?(image, catalog.allowed_images) ->
            {:ok, image}

          true ->
            {:error, {:invalid_repo_environment, path, "image #{inspect(image)} is not allowed by the catalog's allowed_images (#{format_allowed(catalog.allowed_images)})"}}
        end

      other ->
        {:error, {:invalid_repo_environment, path, "image must be a string, got #{inspect(other)}"}}
    end
  end

  defp resolve_resources(catalog, nil, _path), do: {:ok, catalog.resources}

  defp resolve_resources(catalog, document, path) do
    case map_get(document, :resources) do
      nil ->
        {:ok, catalog.resources}

      %{} = raw ->
        resources = resources_map(raw)

        with :ok <- validate_resource_keys(resources, path),
             :ok <- validate_resource_values(resources, path),
             :ok <- enforce_resource_bounds(resources, catalog.resources, path) do
          {:ok, Map.merge(catalog.resources, resources)}
        end

      other ->
        {:error, {:invalid_repo_environment, path, "resources must be a map, got #{inspect(other)}"}}
    end
  end

  defp validate_resource_keys(resources, path) do
    unknown = resources |> Map.keys() |> Enum.reject(&(&1 in @resource_keys)) |> Enum.sort()

    if unknown == [] do
      :ok
    else
      {:error, {:invalid_repo_environment, path, "unknown resources: #{Enum.join(unknown, ", ")} (allowed: cpu, memory)"}}
    end
  end

  defp validate_resource_values(resources, path) do
    Enum.reduce_while(resources, :ok, fn
      {"cpu", value}, :ok ->
        if parse_cpu(value), do: {:cont, :ok}, else: {:halt, {:error, {:invalid_repo_environment, path, "cpu must be a positive number"}}}

      {"memory", value}, :ok ->
        case parse_memory(value) do
          {:ok, _bytes} -> {:cont, :ok}
          :error -> {:halt, {:error, {:invalid_repo_environment, path, "memory must be a size of at least 6m, such as 4g or 512m"}}}
        end
    end)
  end

  defp enforce_resource_bounds(resources, catalog_resources, path) do
    Enum.reduce_while(resources, :ok, fn {key, value}, :ok ->
      max = Map.get(catalog_resources, key)

      cond do
        is_nil(max) ->
          {:halt, {:error, {:invalid_repo_environment, path, "#{key} is not bounded by the catalog and may not be set"}}}

        over_bound?(key, value, max) ->
          {:halt, {:error, {:invalid_repo_environment, path, "#{key} #{inspect(value)} exceeds the catalog maximum #{inspect(max)}"}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp over_bound?("cpu", value, max), do: parse_cpu(value) > parse_cpu(max)

  defp over_bound?("memory", value, max) do
    {:ok, value_bytes} = parse_memory(value)
    {:ok, max_bytes} = parse_memory(max)
    value_bytes > max_bytes
  end

  defp resolve_services(catalog, nil, _path), do: {:ok, catalog.services}

  defp resolve_services(catalog, document, path) do
    case map_get(document, :services) do
      nil ->
        {:ok, catalog.services}

      services when is_list(services) ->
        error_context = {:invalid_repo_environment, path}

        with {:ok, repo_services} <-
               normalize_services(services, catalog.allowed_images, catalog.service_resources, error_context),
             merged = merge_services(catalog.services, repo_services),
             :ok <- enforce_service_count(merged, catalog.max_services, error_context) do
          {:ok, merged}
        end

      other ->
        {:error, {:invalid_repo_environment, path, "services must be a list, got #{inspect(other)}"}}
    end
  end

  # A repo service replaces the catalog service of the same name.
  defp merge_services(catalog_services, repo_services) do
    repo_services
    |> Enum.reduce(catalog_services, fn service, acc -> [service | Enum.reject(acc, &(&1.name == service.name))] end)
    |> Enum.sort_by(& &1.name)
  end

  defp resolve_setup(catalog, nil, _path), do: {:ok, catalog.setup}

  defp resolve_setup(catalog, document, path) do
    case map_get(document, :setup) do
      nil ->
        {:ok, catalog.setup}

      setup when is_list(setup) ->
        if Enum.all?(setup, &is_binary/1) do
          {:ok, setup |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}
        else
          {:error, {:invalid_repo_environment, path, "setup must be a list of commands"}}
        end

      other ->
        {:error, {:invalid_repo_environment, path, "setup must be a list of commands, got #{inspect(other)}"}}
    end
  end

  # ---------------------------------------------------------------- services

  defp normalize_services(services, allowed_images, bounds, error_context) when is_list(services) do
    services
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case normalize_service(raw, allowed_images, bounds, error_context) do
        {:ok, service} -> {:cont, {:ok, [service | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, services} ->
        names = Enum.map(services, & &1.name)
        duplicates = names |> Enum.frequencies() |> Enum.filter(fn {_name, count} -> count > 1 end) |> Enum.map(&elem(&1, 0))

        if duplicates == [] do
          {:ok, Enum.sort_by(services, & &1.name)}
        else
          {:error, error(error_context, "duplicate service names: #{Enum.join(Enum.sort(duplicates), ", ")}")}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_services(_services, _allowed_images, _bounds, error_context),
    do: {:error, error(error_context, "services must be a list")}

  defp normalize_service(%{} = raw, allowed_images, bounds, error_context) do
    unknown =
      raw
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&MapSet.member?(@service_keys, &1))
      |> Enum.sort()

    name = map_get(raw, :name)
    image = map_get(raw, :image)

    with :ok <- no_unknown_service_keys(unknown, error_context),
         {:ok, name} <- service_name(name, error_context),
         {:ok, image} <- service_image(image, allowed_images, error_context),
         {:ok, env} <- service_env(map_get(raw, :env), error_context),
         {:ok, ports} <- service_ports(map_get(raw, :ports), error_context),
         {:ok, command} <- service_command(map_get(raw, :command), error_context),
         {:ok, resources} <- service_resources(map_get(raw, :resources), bounds, name, error_context) do
      {:ok, %{name: name, image: image, env: env, ports: ports, command: command, resources: resources}}
    end
  end

  defp normalize_service(_raw, _allowed_images, _bounds, error_context),
    do: {:error, error(error_context, "each service must be a map")}

  # Every service gets the catalog's `service_resources`; a service may lower them.
  defp service_resources(nil, bounds, _name, _error_context), do: {:ok, bounds}

  defp service_resources(%{} = raw, bounds, name, error_context) do
    resources = resources_map(raw)

    case Enum.find(resources, fn {key, value} -> not valid_service_resource?(key, value, bounds) end) do
      nil ->
        {:ok, Map.merge(bounds, resources)}

      {key, value} ->
        {:error,
         error(
           error_context,
           "service #{name} #{key} #{inspect(value)} must be a positive cpu or a memory size of at least 6m, " <>
             "within the catalog's service_resources (#{inspect(bounds)})"
         )}
    end
  end

  defp service_resources(_raw, _bounds, name, error_context),
    do: {:error, error(error_context, "service #{name} resources must be a map")}

  defp valid_service_resource?(key, value, bounds) when key in @resource_keys,
    do: valid_catalog_resource?(key, value) and not over_bound?(key, value, Map.fetch!(bounds, key))

  defp valid_service_resource?(_key, _value, _bounds), do: false

  defp no_unknown_service_keys([], _error_context), do: :ok

  defp no_unknown_service_keys(unknown, error_context),
    do: {:error, error(error_context, "unknown service keys: #{Enum.join(unknown, ", ")}")}

  defp service_name(name, error_context) when is_binary(name) do
    name = String.trim(name)

    if Regex.match?(@service_name_pattern, name) do
      {:ok, name}
    else
      {:error, error(error_context, "service name #{inspect(name)} must be lowercase letters, digits, or dashes")}
    end
  end

  defp service_name(_name, error_context),
    do: {:error, error(error_context, "each service needs a name")}

  defp service_image(image, allowed_images, error_context) when is_binary(image) do
    image = String.trim(image)

    cond do
      image == "" ->
        {:error, error(error_context, "service image must not be blank")}

      allowed_images == :any or allowed_image?(image, allowed_images) ->
        {:ok, image}

      true ->
        {:error,
         error(
           error_context,
           "service image #{inspect(image)} is not allowed by the catalog's allowed_images (#{format_allowed(allowed_images)})"
         )}
    end
  end

  defp service_image(_image, _allowed_images, error_context),
    do: {:error, error(error_context, "each service needs an image")}

  defp service_env(nil, _error_context), do: {:ok, %{}}

  defp service_env(%{} = env, error_context) do
    Enum.reduce_while(env, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = to_string(key)

      cond do
        not Regex.match?(@env_name_pattern, key) ->
          {:halt, {:error, error(error_context, "service env names must be shell identifiers, got #{inspect(key)}")}}

        not is_binary(value) ->
          {:halt, {:error, error(error_context, "service env #{key} must be a string")}}

        true ->
          {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp service_env(_env, error_context),
    do: {:error, error(error_context, "service env must be a map of name to value")}

  defp service_ports(nil, _error_context), do: {:ok, []}

  defp service_ports(ports, error_context) when is_list(ports) do
    Enum.reduce_while(ports, {:ok, []}, fn
      port, {:ok, acc} when is_integer(port) and port > 0 and port <= 65_535 ->
        {:cont, {:ok, [Integer.to_string(port) | acc]}}

      port, {:ok, acc} when is_binary(port) ->
        port = String.trim(port)

        if valid_port_string?(port),
          do: {:cont, {:ok, [port | acc]}},
          else: {:halt, {:error, error(error_context, "service ports must be numbers 1-65535, optionally with /tcp or /udp")}}

      _port, _acc ->
        {:halt, {:error, error(error_context, "service ports must be numbers 1-65535, optionally with /tcp or /udp")}}
    end)
    |> case do
      {:ok, ports} -> {:ok, Enum.reverse(ports)}
      {:error, _reason} = error -> error
    end
  end

  defp service_ports(_ports, error_context),
    do: {:error, error(error_context, "service ports must be a list")}

  defp valid_port_string?(port) do
    case Regex.run(@port_pattern, port) do
      [_, number] -> String.to_integer(number) in 1..65_535
      nil -> false
    end
  end

  defp service_command(nil, _error_context), do: {:ok, []}

  defp service_command(command, _error_context) when is_binary(command) do
    case String.trim(command) do
      "" -> {:ok, []}
      command -> {:ok, ["sh", "-lc", command]}
    end
  end

  defp service_command(command, error_context) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      {:ok, Enum.map(command, &to_string/1)}
    else
      {:error, error(error_context, "service command must be a string or a list of strings")}
    end
  end

  defp service_command(_command, error_context),
    do: {:error, error(error_context, "service command must be a string or a list of strings")}

  # ---------------------------------------------------------------- digest and helpers

  defp digest(resolved) do
    payload = %{
      "name" => resolved.name,
      "image" => resolved.image,
      "resources" => resolved.resources,
      "services" => resolved.services,
      "setup" => resolved.setup,
      "egress_extra" => resolved.egress_extra
    }

    payload
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp allowed_image?(image, allowed_images) when is_list(allowed_images) do
    Enum.any?(allowed_images, fn prefix ->
      is_binary(prefix) and prefix != "" and String.starts_with?(image, prefix)
    end)
  end

  defp format_allowed([]), do: "none"

  defp format_allowed(allowed_images), do: Enum.join(allowed_images, ", ")

  defp required_image(image, error) when is_binary(image) do
    case String.trim(image) do
      "" -> {:error, error}
      image -> {:ok, image}
    end
  end

  defp required_image(_image, error), do: {:error, error}

  defp ensure_map(%{} = _map, _error), do: :ok
  defp ensure_map(_map, error), do: {:error, error}

  defp resources_map(resources) when is_map(resources),
    do: Map.new(resources, fn {key, value} -> {to_string(key), value} end)

  defp list_of_strings(values) when is_list(values),
    do: values |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp list_of_strings(_values), do: []

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp map_get(%{} = map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp parse_cpu(value) when is_number(value) and value > 0, do: value / 1
  defp parse_cpu(value) when is_binary(value), do: parse_float(value)
  defp parse_cpu(_value), do: nil

  defp parse_float(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  # `--memory 0` means "no limit" to Docker and Podman, and anything under 6m
  # is rejected by them, so a limit must be at least 6m.
  defp parse_memory(value) when is_integer(value) and value >= @min_memory_bytes, do: {:ok, value}

  defp parse_memory(value) when is_binary(value) do
    with [_, amount, unit] <- Regex.run(~r/^\s*(\d+(?:\.\d+)?)\s*([kmgt]?)i?b?\s*$/i, value),
         amount = if(String.contains?(amount, "."), do: amount, else: amount <> ".0"),
         bytes when bytes >= @min_memory_bytes <- round(String.to_float(amount) * multiplier(unit)) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp parse_memory(_value), do: :error

  defp multiplier(unit) do
    case String.downcase(unit) do
      "k" -> 1024
      "m" -> 1024 * 1024
      "g" -> 1024 * 1024 * 1024
      "t" -> 1024 * 1024 * 1024 * 1024
      _ -> 1
    end
  end

  defp error({:invalid_environment_catalog, name}, message),
    do: {:invalid_environment_catalog, name, message}

  defp error({:invalid_repo_environment, path}, message),
    do: {:invalid_repo_environment, path, message}
end
