defmodule SymphonyElixirWeb.GitMirrorController do
  @moduledoc """
  Read-only git smart HTTP over the controller's repo caches.

  `SymphonyElixirWeb.RunnerAuth` has already checked the run token and epoch;
  this controller resolves the repo key, checks that the run's issue may read
  it, and shells out to `git upload-pack`. It never writes: receive-pack is
  refused, and pushes still go to GitHub from the workspace's own origin.
  """

  use Phoenix.Controller, formats: []

  alias Plug.Conn
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitMirror
  alias SymphonyElixir.GitMirror.UploadPack

  @advertisement_type "application/x-git-upload-pack-advertisement"
  @result_type "application/x-git-upload-pack-result"

  @doc "GET /git/:run_id/:repo/info/refs?service=git-upload-pack"
  @spec info_refs(Conn.t(), map()) :: Conn.t()
  def info_refs(conn, params) do
    case params["service"] do
      "git-upload-pack" -> with_repo(conn, &serve_info_refs/3)
      "git-receive-pack" -> read_only(conn, params)
      _ -> error(conn, 400, "unsupported_service")
    end
  end

  @doc "POST /git/:run_id/:repo/git-upload-pack"
  @spec upload_pack(Conn.t(), map()) :: Conn.t()
  def upload_pack(conn, _params), do: with_repo(conn, &serve_upload_pack/3)

  @doc "The mirror is read-only; receive-pack is always refused."
  @spec read_only(Conn.t(), map()) :: Conn.t()
  def read_only(conn, _params), do: error(conn, 403, "read_only")

  defp with_repo(conn, fun) do
    settings = Config.settings!()

    case GitMirror.resolve(conn.path_params["repo"], settings) do
      {:ok, repo} ->
        case GitMirror.authorize(conn.assigns.run.metadata, repo, settings) do
          :ok -> fun.(conn, repo, settings)
          {:error, :forbidden} -> error(conn, 403, "repo_forbidden")
        end

      {:error, :unknown_repo} ->
        error(conn, 404, "repo_not_found")
    end
  end

  defp serve_info_refs(conn, repo, settings) do
    :ok = GitMirror.maybe_refresh(repo, settings)

    conn
    |> protocol_header()
    |> then(fn {conn, protocol} -> {conn, UploadPack.advertise(repo.cache_path, protocol)} end)
    |> case do
      {conn, {:ok, body}} ->
        conn
        |> put_resp_header("content-type", @advertisement_type)
        |> put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, body)

      {conn, {:error, _reason}} ->
        error(conn, 500, "git_failed")
    end
  end

  defp serve_upload_pack(conn, repo, _settings) do
    case read_request_body(conn) do
      {:ok, body, conn} ->
        case gunzip(conn, body) do
          {:ok, decoded} ->
            {conn, protocol} = protocol_header(conn)
            serve_upload_result(conn, repo, decoded, protocol)

          {:error, :invalid_gzip} ->
            error(conn, 400, "invalid_gzip")

          {:error, :unsupported_encoding} ->
            error(conn, 415, "unsupported_encoding")
        end

      {:error, :too_large, conn} ->
        error(conn, 413, "request_too_large")
    end
  end

  defp serve_upload_result(conn, repo, body, protocol) do
    case UploadPack.result(repo.cache_path, body, protocol) do
      {:ok, output} ->
        conn
        |> put_resp_header("content-type", @result_type)
        |> put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, output)

      {:error, _reason} ->
        error(conn, 500, "git_failed")
    end
  end

  defp read_request_body(conn) do
    max_bytes = UploadPack.max_body_bytes()

    case Conn.read_body(conn, length: max_bytes + 1, read_length: min(max_bytes + 1, 1_000_000)) do
      {:ok, body, conn} when byte_size(body) <= max_bytes -> {:ok, body, conn}
      {:ok, _body, conn} -> {:error, :too_large, conn}
      {:more, _body, conn} -> {:error, :too_large, conn}
    end
  end

  defp gunzip(conn, body) do
    case get_req_header(conn, "content-encoding") |> List.first() |> to_string() |> String.trim() |> String.downcase() do
      encoding when encoding in ["", "identity"] ->
        {:ok, body}

      "gzip" ->
        try do
          {:ok, :zlib.gunzip(body)}
        rescue
          _error -> {:error, :invalid_gzip}
        end

      _encoding ->
        {:error, :unsupported_encoding}
    end
  end

  defp protocol_header(conn) do
    {conn, get_req_header(conn, "git-protocol") |> List.first()}
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_header("cache-control", "no-cache")
    |> Conn.send_resp(status, message)
    |> Conn.halt()
  end
end
