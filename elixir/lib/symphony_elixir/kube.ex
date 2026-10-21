defmodule SymphonyElixir.Kube do
  @moduledoc """
  A small Kubernetes API client for the run launcher.

  It covers only what starting a runner pod needs: create, get and delete a
  pod, and create and delete a secret. Everything else stays outside this
  controller.

  A client is built either from explicit `:base_url`/`:token` options (tests
  pass `req_options: [plug: {Req.Test, Stub}]`) or from an in-cluster service
  account. In-cluster it reads the bearer token and CA certificate from the
  mounted service account directory and the API server address from
  `KUBERNETES_SERVICE_HOST`/`KUBERNETES_SERVICE_PORT`. See
  `docs/durable-runs.md`.

  `client/1` merges its options over `:kube_options` in the application
  environment, so `alive?/1` and `stop/1` can build a client without holding
  configuration themselves.
  """

  @service_account_dir "/var/run/secrets/kubernetes.io/serviceaccount"

  @enforce_keys [:req]
  defstruct [:req]

  @type t :: %__MODULE__{req: Req.Request.t()}
  @type resource :: map()

  @doc """
  Builds a client.

  Options:

    * `:base_url` and `:token` — explicit credentials. Without `:base_url` the
      in-cluster service account is used.
    * `:service_account_dir` — where `token` and `ca.crt` live (default: the
      standard mount path). Injectable so tests can use a temp dir.
    * `:env` — a map read instead of the process environment. Tests use it for
      the `KUBERNETES_SERVICE_*` variables.
    * `:req_options` — extra options for `Req.new/1`, such as `:plug` in tests.

  Returns `{:error, :not_in_cluster}` when there are no explicit credentials
  and no service account is mounted.
  """
  @spec client(keyword()) :: {:ok, t()} | {:error, term()}
  def client(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:symphony_elixir, :kube_options, []), opts)

    with {:ok, base_url, token, cacertfile} <- connection(opts) do
      req =
        opts
        |> Keyword.get(:req_options, [])
        |> Keyword.put(:base_url, base_url)
        |> put_authorization(token)
        |> put_cacertfile(cacertfile)
        |> Req.new()

      {:ok, %__MODULE__{req: req}}
    end
  end

  @doc "Creates a pod in a namespace."
  @spec create_pod(t(), String.t(), resource()) :: {:ok, resource()} | {:error, term()}
  def create_pod(%__MODULE__{} = client, namespace, pod) do
    request(client, :post, pods_path(namespace), json: pod)
  end

  @doc "Gets a pod; `{:error, :not_found}` when it does not exist."
  @spec get_pod(t(), String.t(), String.t()) :: {:ok, resource()} | {:error, term()}
  def get_pod(%__MODULE__{} = client, namespace, name) do
    request(client, :get, pod_path(namespace, name))
  end

  @doc "Deletes a pod; `{:error, :not_found}` when it is already gone."
  @spec delete_pod(t(), String.t(), String.t()) :: {:ok, resource()} | {:error, term()}
  def delete_pod(%__MODULE__{} = client, namespace, name) do
    request(client, :delete, pod_path(namespace, name))
  end

  @doc "Creates a secret in a namespace."
  @spec create_secret(t(), String.t(), resource()) :: {:ok, resource()} | {:error, term()}
  def create_secret(%__MODULE__{} = client, namespace, secret) do
    request(client, :post, secrets_path(namespace), json: secret)
  end

  @doc "Deletes a secret; `{:error, :not_found}` when it is already gone."
  @spec delete_secret(t(), String.t(), String.t()) :: {:ok, resource()} | {:error, term()}
  def delete_secret(%__MODULE__{} = client, namespace, name) do
    request(client, :delete, secret_path(namespace, name))
  end

  defp pods_path(namespace), do: "/api/v1/namespaces/#{namespace}/pods"
  defp pod_path(namespace, name), do: pods_path(namespace) <> "/" <> name
  defp secrets_path(namespace), do: "/api/v1/namespaces/#{namespace}/secrets"
  defp secret_path(namespace, name), do: secrets_path(namespace) <> "/" <> name

  defp request(%__MODULE__{req: req}, method, url, opts \\ []) do
    case Req.request(req, Keyword.merge([method: method, url: url], opts)) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, error_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_body(nil), do: %{}
  defp normalize_body(""), do: %{}

  defp normalize_body(body) when is_map(body), do: body

  # A successful Kubernetes response is always an object. Anything else (for
  # example an empty delete response or a proxy error page) is not useful to the
  # caller, so it becomes an empty map rather than a surprise value.
  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp normalize_body(_body), do: %{}

  defp error_body(nil), do: %{}
  defp error_body(""), do: %{}
  defp error_body(body), do: body

  defp connection(opts) do
    case Keyword.get(opts, :base_url) do
      base_url when is_binary(base_url) and base_url != "" ->
        {:ok, String.trim_trailing(base_url, "/"), Keyword.get(opts, :token), nil}

      _ ->
        in_cluster_connection(opts)
    end
  end

  defp in_cluster_connection(opts) do
    dir = Keyword.get(opts, :service_account_dir, @service_account_dir)

    with host when is_binary(host) and host != "" <- env(opts, "KUBERNETES_SERVICE_HOST"),
         port when is_binary(port) and port != "" <- env(opts, "KUBERNETES_SERVICE_PORT"),
         {:ok, token} <- File.read(Path.join(dir, "token")),
         {:ok, cacertfile} <- File.read(Path.join(dir, "ca.crt")) do
      {:ok, "https://#{url_host(host)}:#{port}", token, cacertfile}
    else
      nil -> {:error, :not_in_cluster}
      {:error, reason} -> {:error, {:in_cluster_config, reason}}
    end
  end

  # An IPv6 literal has to be bracketed in a URL authority.
  defp url_host(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  defp env(opts, name) do
    case Keyword.get(opts, :env) do
      env when is_map(env) -> Map.get(env, name)
      _ -> System.get_env(name)
    end
  end

  defp put_authorization(options, nil), do: options

  defp put_authorization(options, token) when is_binary(token) do
    headers = [{"authorization", "Bearer " <> token} | Enum.to_list(Keyword.get(options, :headers, []))]
    Keyword.put(options, :headers, headers)
  end

  defp put_cacertfile(options, nil), do: options

  defp put_cacertfile(options, cacertfile) when is_binary(cacertfile) do
    connect_options = Keyword.get(options, :connect_options, [])
    transport_opts = Keyword.get(connect_options, :transport_opts, [])

    connect_options =
      Keyword.put(connect_options, :transport_opts, Keyword.put(transport_opts, :cacertfile, cacertfile))

    Keyword.put(options, :connect_options, connect_options)
  end
end
