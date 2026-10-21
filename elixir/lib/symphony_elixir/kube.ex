defmodule SymphonyElixir.Kube do
  @moduledoc """
  A small Kubernetes API client for the run launcher.

  It covers only what running runner pods needs: create, get, list, watch and
  delete a pod, create, patch, list and delete a secret, and create, patch and
  delete a config map. Everything else stays outside this controller.

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

  @doc """
  Lists the pods in a namespace matching a label selector (such as
  `app.kubernetes.io/name=symphony-runner`); returns the items.
  """
  @spec list_pods(t(), String.t(), String.t()) :: {:ok, [resource()]} | {:error, term()}
  def list_pods(%__MODULE__{} = client, namespace, label_selector) do
    list(client, collection_path(namespace, :pods), label_selector)
  end

  @doc """
  Lists the pods matching a label selector, page by page (`:limit` per page,
  500 by default), and returns the items with the list's `resourceVersion`,
  the point a watch started from it continues at. An expired continue token
  (`410`) is `{:error, :gone}`; list again from the start.
  """
  @spec list_pods_with_version(t(), String.t(), String.t(), keyword()) ::
          {:ok, [resource()], String.t() | nil} | {:error, term()}
  def list_pods_with_version(%__MODULE__{} = client, namespace, label_selector, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)
    list_pages(client, collection_path(namespace, :pods), [labelSelector: label_selector, limit: limit], nil, [])
  end

  @doc """
  Watches the pods matching a label selector from `resource_version`
  (`?watch=1`, with bookmarks), streaming the response.

  `on_events` is called with each batch of decoded events (`%{"type" =>
  "ADDED" | "MODIFIED" | "DELETED" | "BOOKMARK", "object" => pod}`) as their
  lines arrive. The call returns when the stream ends:

    * `{:ok, :closed}` — the API server ended the watch (`timeoutSeconds`,
      300 by default, or a restart); watch again from the last
      `resourceVersion` seen.
    * `{:error, :gone}` — the version is too old (`410`, as a status or an
      `ERROR` event); list again.
    * `{:error, {:watch_error, status}}` — any other `ERROR` event.
    * `{:error, {:http_error, status, body}}`, `{:error, :not_found}` or a
      transport error.

  The watch is never retried by `Req` (a replay would repeat events) and asks
  for an uncompressed response, since chunks are parsed as they arrive.
  """
  @spec watch_pods(t(), String.t(), String.t(), String.t() | nil, ([map()] -> any()), keyword()) ::
          {:ok, :closed} | {:error, term()}
  def watch_pods(%__MODULE__{req: req}, namespace, label_selector, resource_version, on_events, opts \\ [])
      when is_function(on_events, 1) do
    timeout_seconds = Keyword.get(opts, :timeout_seconds, 300)

    params =
      [labelSelector: label_selector, watch: 1, allowWatchBookmarks: true, timeoutSeconds: timeout_seconds] ++
        if(is_binary(resource_version) and resource_version != "", do: [resourceVersion: resource_version], else: [])

    request = [
      method: :get,
      url: collection_path(namespace, :pods),
      params: params,
      retry: false,
      compressed: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, (timeout_seconds + 30) * 1_000),
      into: &watch_chunk(&1, &2, on_events)
    ]

    case Req.request(req, request) do
      {:ok, %{status: status} = response} when status in 200..299 -> watch_result(response, on_events)
      {:ok, %{status: 410}} -> {:error, :gone}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, error_body(normalize_body(body))}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Splits a chunk (after what was left of the last one) into complete lines
  # and the unfinished rest.
  @spec split_lines(binary()) :: {[binary()], binary()}
  def split_lines(buffer) when is_binary(buffer) do
    parts = String.split(buffer, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(String.trim(&1) == "")), rest}
  end

  @doc false
  # The events in a batch of watch lines, or why the watch must stop.
  @spec decode_watch_lines([binary()]) :: {:ok, [map()]} | {:error, term()}
  def decode_watch_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, events} ->
      case Jason.decode(line) do
        {:ok, %{"type" => "ERROR", "object" => object}} ->
          {:halt, watch_error(object)}

        {:ok, %{"type" => type, "object" => object} = event} when is_binary(type) and is_map(object) ->
          {:cont, {:ok, [event | events]}}

        _other ->
          {:halt, {:error, {:invalid_watch_event, String.slice(line, 0, 200)}}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp watch_error(%{"code" => 410}), do: {:error, :gone}
  defp watch_error(object), do: {:error, {:watch_error, object}}

  # A non-2xx answer keeps its body for the error; a 2xx one is parsed line
  # by line as it streams.
  defp watch_chunk({:data, data}, {request, %{status: status} = response}, on_events) when status in 200..299 do
    {lines, rest} = split_lines(Req.Response.get_private(response, :kube_watch_buffer, "") <> data)
    response = Req.Response.put_private(response, :kube_watch_buffer, rest)

    case dispatch_watch_lines(lines, on_events) do
      :ok -> {:cont, {request, response}}
      {:error, _reason} = error -> {:halt, {request, Req.Response.put_private(response, :kube_watch_result, error)}}
    end
  end

  defp watch_chunk({:data, data}, {request, response}, _on_events) do
    body = if is_binary(response.body), do: response.body, else: ""
    {:cont, {request, %{response | body: body <> data}}}
  end

  # The stream ended: a last line without its newline still counts.
  defp watch_result(response, on_events) do
    case Req.Response.get_private(response, :kube_watch_result) do
      nil ->
        case dispatch_watch_lines([Req.Response.get_private(response, :kube_watch_buffer, "")] |> Enum.reject(&(String.trim(&1) == "")), on_events) do
          :ok -> {:ok, :closed}
          error -> error
        end

      error ->
        error
    end
  end

  defp dispatch_watch_lines([], _on_events), do: :ok

  defp dispatch_watch_lines(lines, on_events) do
    case decode_watch_lines(lines) do
      {:ok, []} ->
        :ok

      {:ok, events} ->
        on_events.(events)
        :ok

      error ->
        error
    end
  end

  defp list_pages(client, path, params, continue, acc) do
    params = if continue, do: Keyword.put(params, :continue, continue), else: params

    case request(client, :get, path, params: params) do
      {:ok, body} ->
        items = body |> Map.get("items") |> List.wrap() |> Enum.filter(&is_map/1)
        metadata = if is_map(body["metadata"]), do: body["metadata"], else: %{}

        case metadata["continue"] do
          next when is_binary(next) and next != "" -> list_pages(client, path, params, next, [items | acc])
          _done -> {:ok, [items | acc] |> Enum.reverse() |> Enum.concat(), metadata["resourceVersion"]}
        end

      {:error, {:http_error, 410, _body}} ->
        {:error, :gone}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Lists the secrets in a namespace matching a label selector; returns the items."
  @spec list_secrets(t(), String.t(), String.t()) :: {:ok, [resource()]} | {:error, term()}
  def list_secrets(%__MODULE__{} = client, namespace, label_selector) do
    list(client, collection_path(namespace, :secrets), label_selector)
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

  defp list(client, path, label_selector) do
    with {:ok, body} <- request(client, :get, path, params: [labelSelector: label_selector]) do
      case Map.get(body, "items") do
        items when is_list(items) -> {:ok, Enum.filter(items, &is_map/1)}
        _other -> {:ok, []}
      end
    end
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
