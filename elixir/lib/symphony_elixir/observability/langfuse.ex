defmodule SymphonyElixir.Observability.Langfuse do
  @moduledoc """
  Reads traces from Langfuse's public REST API (`/api/public/*`, basic auth
  with the project's public and secret key).

  OpenTelemetry traces reach Langfuse with their OTel trace id, so a trace found
  in ClickHouse can be opened here and in the Langfuse UI. Langfuse observations
  carry model usage and cost, which ClickHouse spans do not.

  Parsing is tolerant: unknown fields are ignored and missing ones become nil.
  Errors are returned, never raised. `config` is the map from
  `SymphonyElixir.Config.observability_langfuse/0`.
  """

  @type config :: %{
          required(:url) => String.t(),
          required(:public_key) => String.t(),
          required(:secret_key) => String.t(),
          optional(:public_url) => String.t() | nil,
          optional(:timeout_ms) => pos_integer()
        }

  @doc """
  One trace with its observations (`GET /api/public/traces/{id}`), as Langfuse
  returns it, or `{:error, :not_found}`.
  """
  @spec trace(config(), String.t()) :: {:ok, map()} | {:error, term()}
  def trace(config, trace_id) do
    case get(config, "/api/public/traces/" <> URI.encode_www_form(trace_id), []) do
      {:ok, %{"id" => _} = trace} -> {:ok, trace}
      {:ok, _other} -> {:error, :invalid_langfuse_response}
      error -> error
    end
  end

  @doc """
  A page of traces (`GET /api/public/traces`), newest first. `params` are passed
  through (`limit`, `page`, `fromTimestamp`, `sessionId`, `tags`, ...).
  """
  @spec traces(config(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def traces(config, params) do
    case get(config, "/api/public/traces", Keyword.put_new(params, :orderBy, "timestamp.desc")) do
      {:ok, %{"data" => traces}} when is_list(traces) -> {:ok, traces}
      {:ok, _other} -> {:error, :invalid_langfuse_response}
      error -> error
    end
  end

  @doc "The id of the project the configured keys belong to (`GET /api/public/projects`)."
  @spec project_id(config()) :: {:ok, String.t()} | {:error, term()}
  def project_id(config) do
    case get(config, "/api/public/projects", []) do
      {:ok, %{"data" => [%{"id" => id} | _]}} when is_binary(id) -> {:ok, id}
      {:ok, _other} -> {:error, :invalid_langfuse_response}
      error -> error
    end
  end

  @doc """
  A browser link to a trace under `public_url`, or nil without one. With a
  project id the link goes straight to the trace page; without, to Langfuse's
  `/trace/{id}` redirect.
  """
  @spec trace_url(config(), String.t(), String.t() | nil) :: String.t() | nil
  def trace_url(config, trace_id, project_id) do
    case Map.get(config, :public_url) do
      base when is_binary(base) and base != "" ->
        base = String.trim_trailing(base, "/")
        encoded = URI.encode_www_form(trace_id)
        if is_binary(project_id), do: "#{base}/project/#{project_id}/traces/#{encoded}", else: "#{base}/trace/#{encoded}"

      _ ->
        nil
    end
  end

  @doc "A browser link for a Langfuse `htmlPath` (e.g. `/project/p/traces/t`), or nil."
  @spec html_url(config(), String.t() | nil) :: String.t() | nil
  def html_url(config, "/" <> _ = path) do
    case Map.get(config, :public_url) do
      base when is_binary(base) and base != "" -> String.trim_trailing(base, "/") <> path
      _ -> nil
    end
  end

  def html_url(_config, _path), do: nil

  defp get(config, path, params) do
    timeout = Map.get(config, :timeout_ms) || 3_000

    request = [
      url: String.trim_trailing(config.url, "/") <> path,
      params: params,
      auth: {:basic, "#{config.public_key}:#{config.secret_key}"},
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      retry: false
    ]

    case Req.get(request ++ Application.get_env(:symphony_elixir, :observability_req_options, [])) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode(body)
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: status}} -> {:error, {:langfuse_http, status}}
      {:error, exception} -> {:error, {:langfuse_unreachable, Map.get(exception, :reason, exception)}}
    end
  end

  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_langfuse_response}
    end
  end

  defp decode(_body), do: {:error, :invalid_langfuse_response}
end
