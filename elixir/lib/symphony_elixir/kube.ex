defmodule SymphonyElixir.Kube do
  @moduledoc """
  A small Kubernetes API client for the run launcher.

  It covers only what starting a runner pod needs: create, get and delete a
  pod, and create, patch and delete a secret or config map. Everything else
  stays outside this controller.

  A client is built either from explicit `:base_url`/`:token` options (tests
  pass `req_options: [plug: {Req.Test, Stub}]`) or from an in-cluster service
  account. In-cluster it reads the bearer token and CA certificate from the
  mounted service account directory (the token on every request) and the API
  server address from
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

  In-cluster, the token file is re-read on every request, so a rotated
  projected service account token is picked up without rebuilding the client.
  The CA bundle is decoded once into DER certificates and passed as `:cacerts`
  with `verify: :verify_peer` and HTTPS hostname checking against the API
  server host.

  Returns `{:error, :not_in_cluster}` when there are no explicit credentials
  and no service account is mounted.
  """
  @spec client(keyword()) :: {:ok, t()} | {:error, term()}
  def client(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:symphony_elixir, :kube_options, []), opts)

    with {:ok, base_url, auth, cacerts} <- connection(opts) do
      req =
        opts
        |> Keyword.get(:req_options, [])
        |> Keyword.put(:base_url, base_url)
        |> put_static_authorization(auth)
        |> put_tls(cacerts)
        |> Req.new()
        |> put_token_step(auth)

      {:ok, %__MODULE__{req: req}}
    end
  end

  @doc "Creates a pod in a namespace."
  @spec create_pod(t(), String.t(), resource()) :: {:ok, resource()} | {:error, term()}
  def create_pod(%__MODULE__{} = client, namespace, pod) do
    request(client, :post, collection_path(namespace, :pods), json: pod)
  end

  @doc "Gets a pod; `{:error, :not_found}` when it does not exist."
  @spec get_pod(t(), String.t(), String.t()) :: {:ok, resource()} | {:error, term()}
  def get_pod(%__MODULE__{} = client, namespace, name) do
    request(client, :get, object_path(namespace, :pods, name))
  end

  @doc "Deletes a pod; `{:error, :not_found}` when it is already gone."
  @spec delete_pod(t(), String.t(), String.t()) :: {:ok, resource()} | {:error, term()}
  def delete_pod(%__MODULE__{} = client, namespace, name) do
    request(client, :delete, object_path(namespace, :pods, name))
  end

  @doc "Creates a secret in a namespace."
  @spec create_secret(t(), String.t(), resource()) :: {:ok, resource()} | {:error, term()}
  def create_secret(%__MODULE__{} = client, namespace, secret) do
    request(client, :post, collection_path(namespace, :secrets), json: secret)
  end

  @doc "Merge-patches a secret; `{:error, :not_found}` when it does not exist."
  @spec patch_secret(t(), String.t(), String.t(), map()) :: {:ok, resource()} | {:error, term()}
  def patch_secret(%__MODULE__{} = client, namespace, name, patch) do
    merge_patch(client, object_path(namespace, :secrets, name), patch)
  end

  @doc "Deletes a secret; `{:error, :not_found}` when it is already gone."
  @spec delete_secret(t(), String.t(), String.t()) :: {:ok, resource()} | {:error, term()}
  def delete_secret(%__MODULE__{} = client, namespace, name) do
    request(client, :delete, object_path(namespace, :secrets, name))
  end

  @doc "Creates a config map in a namespace."
  @spec create_config_map(t(), String.t(), resource()) :: {:ok, resource()} | {:error, term()}
  def create_config_map(%__MODULE__{} = client, namespace, config_map) do
    request(client, :post, collection_path(namespace, :configmaps), json: config_map)
  end

  @doc "Merge-patches a config map; `{:error, :not_found}` when it does not exist."
  @spec patch_config_map(t(), String.t(), String.t(), map()) :: {:ok, resource()} | {:error, term()}
  def patch_config_map(%__MODULE__{} = client, namespace, name, patch) do
    merge_patch(client, object_path(namespace, :configmaps, name), patch)
  end

  @doc "Deletes a config map; `{:error, :not_found}` when it is already gone."
  @spec delete_config_map(t(), String.t(), String.t()) :: {:ok, resource()} | {:error, term()}
  def delete_config_map(%__MODULE__{} = client, namespace, name) do
    request(client, :delete, object_path(namespace, :configmaps, name))
  end

  defp merge_patch(client, path, patch) do
    request(client, :patch, path,
      body: Jason.encode!(patch),
      headers: [{"content-type", "application/merge-patch+json"}]
    )
  end

  defp collection_path(namespace, resource), do: "/api/v1/namespaces/#{namespace}/#{resource}"
  defp object_path(namespace, resource, name), do: collection_path(namespace, resource) <> "/" <> name

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
        {:ok, String.trim_trailing(base_url, "/"), {:static, Keyword.get(opts, :token)}, nil}

      _ ->
        in_cluster_connection(opts)
    end
  end

  defp in_cluster_connection(opts) do
    dir = Keyword.get(opts, :service_account_dir, @service_account_dir)
    token_path = Path.join(dir, "token")

    with host when is_binary(host) and host != "" <- env(opts, "KUBERNETES_SERVICE_HOST"),
         port when is_binary(port) and port != "" <- env(opts, "KUBERNETES_SERVICE_PORT"),
         {:ok, _token} <- File.read(token_path),
         {:ok, ca_pem} <- File.read(Path.join(dir, "ca.crt")),
         {:ok, cacerts} <- decode_cacerts(ca_pem) do
      {:ok, "https://#{url_host(host)}:#{port}", {:file, token_path}, cacerts}
    else
      nil -> {:error, :not_in_cluster}
      {:error, reason} -> {:error, {:in_cluster_config, reason}}
    end
  end

  # The CA file is PEM; :ssl wants DER certificates in :cacerts.
  defp decode_cacerts(pem) do
    case for({:Certificate, der, _} <- :public_key.pem_decode(pem), do: der) do
      [] -> {:error, :invalid_ca_certificate}
      cacerts -> {:ok, cacerts}
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

  defp put_static_authorization(options, {:static, token}) when is_binary(token) do
    headers = [{"authorization", "Bearer " <> token} | Enum.to_list(Keyword.get(options, :headers, []))]
    Keyword.put(options, :headers, headers)
  end

  defp put_static_authorization(options, _auth), do: options

  # A projected service account token is rotated by the kubelet, so it is read
  # again for every request instead of once when the client is built.
  defp put_token_step(req, {:file, path}) do
    Req.Request.append_request_steps(req, kube_token: &file_token_step(&1, path))
  end

  defp put_token_step(req, _auth), do: req

  defp file_token_step(request, path) do
    case File.read(path) do
      {:ok, token} ->
        Req.Request.put_header(request, "authorization", "Bearer " <> String.trim(token))

      {:error, reason} ->
        {request, File.Error.exception(reason: reason, action: "read service account token from", path: path)}
    end
  end

  defp put_tls(options, nil), do: options

  defp put_tls(options, cacerts) when is_list(cacerts) do
    connect_options = Keyword.get(options, :connect_options, [])

    transport_opts =
      connect_options
      |> Keyword.get(:transport_opts, [])
      |> Keyword.merge(
        cacerts: cacerts,
        verify: :verify_peer,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      )

    Keyword.put(options, :connect_options, Keyword.put(connect_options, :transport_opts, transport_opts))
  end
end
