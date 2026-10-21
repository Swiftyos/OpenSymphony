defmodule SymphonyElixirWeb.GitMirrorController do
  @moduledoc """
  Read-only git smart HTTP over the controller's repo caches.

  `SymphonyElixirWeb.RunnerAuth` has already checked the run token and epoch;
  this controller resolves the repo key, checks that the run's issue may read
  it, and shells out to `git upload-pack`. It never writes: receive-pack is
  refused, and pushes still go to GitHub from the workspace's own origin.

  Each git process takes a slot from `SymphonyElixir.GitMirror.Limiter`
  (`git_mirror.max_concurrent`); when none is free the request gets `503` with
  `Retry-After`. The request body is streamed to an owner-only temp file,
  gunzipped incrementally when the client sent `Content-Encoding: gzip`, and
  refused with `413` once either the raw or the inflated size passes
  `UploadPack.max_body_bytes/0`. The response is sent chunked as git writes
  it, with `git_mirror.idle_timeout_ms` as the longest silence; once the first
  chunk is out, a later git failure can only cut the response short, which
  the client sees as a broken pack.
  """

  use Phoenix.Controller, formats: []

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitMirror
  alias SymphonyElixir.GitMirror.{Limiter, UploadPack}

  @advertisement_type "application/x-git-upload-pack-advertisement"
  @result_type "application/x-git-upload-pack-result"
  @read_chunk_bytes 65_536
  @retry_after_seconds "5"

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

    with {:ok, repo} <- GitMirror.resolve(conn.path_params["repo"], settings),
         :ok <- GitMirror.authorize(conn.assigns.run.metadata, repo, settings),
         {:ok, slot} <- Limiter.acquire(settings.git_mirror.max_concurrent) do
      try do
        fun.(conn, repo, settings)
      after
        Limiter.release(slot)
      end
    else
      {:error, :unknown_repo} ->
        error(conn, 404, "repo_not_found")

      {:error, :forbidden} ->
        error(conn, 403, "repo_forbidden")

      :full ->
        conn
        |> put_resp_header("retry-after", @retry_after_seconds)
        |> error(503, "busy")
    end
  end

  defp serve_info_refs(conn, repo, settings) do
    :ok = GitMirror.maybe_refresh(repo, settings)
    stream_git(conn, repo, :advertise, @advertisement_type, UploadPack.service_header(), settings)
  end

  defp serve_upload_pack(conn, repo, settings) do
    case UploadPack.create_request_file() do
      {:ok, dir, path, io} ->
        try do
          case write_request(conn, io) do
            {:ok, conn} ->
              :ok = :file.close(io)
              stream_git(conn, repo, {:request, path}, @result_type, "", settings)

            {:error, :too_large, conn} ->
              error(conn, 413, "request_too_large")

            {:error, :invalid_gzip, conn} ->
              error(conn, 400, "invalid_gzip")

            {:error, :unsupported_encoding, conn} ->
              error(conn, 415, "unsupported_encoding")
          end
        after
          _ = :file.close(io)
          UploadPack.remove_request_dir(dir)
        end

      {:error, reason} ->
        Logger.warning("Git mirror request file failed reason=#{inspect(reason)}")
        error(conn, 500, "request_file_failed")
    end
  end

  defp write_request(conn, io) do
    case content_encoding(conn) do
      encoding when encoding in ["", "identity"] ->
        copy_body(conn, io, :identity, 0, 0)

      "gzip" ->
        z = :zlib.open()

        try do
          :ok = :zlib.inflateInit(z, 31)
          copy_body(conn, io, {:gzip, z}, 0, 0)
        after
          :zlib.close(z)
        end

      _encoding ->
        {:error, :unsupported_encoding, conn}
    end
  end

  # Reads the body in bounded chunks and writes it, decoded, to the request
  # file; `raw` and `written` count the bytes received and stored.
  defp copy_body(conn, io, decoder, raw, written) do
    {status, data, conn} = Conn.read_body(conn, length: @read_chunk_bytes, read_length: @read_chunk_bytes)
    raw = raw + byte_size(data)
    max = UploadPack.max_body_bytes()

    with true <- raw <= max || {:error, :too_large},
         {:ok, written} <- decode(decoder, data, io, written, max),
         :ok <- if(status == :ok, do: finish(decoder), else: {:more, written}) do
      {:ok, conn}
    else
      {:more, written} -> copy_body(conn, io, decoder, raw, written)
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp decode(:identity, data, io, written, max), do: write_bounded(io, data, written, max)

  defp decode({:gzip, z}, data, io, written, max) do
    inflate(z, :zlib.safeInflate(z, data), io, written, max)
  rescue
    ErlangError -> {:error, :invalid_gzip}
  end

  # `safeInflate` returns bounded output per call: `:continue` means it has
  # more for the same input, `:finished` that this input is used up.
  defp inflate(z, {state, output}, io, written, max) do
    with {:ok, written} <- write_bounded(io, output, written, max) do
      case state do
        :continue -> inflate(z, :zlib.safeInflate(z, []), io, written, max)
        :finished -> {:ok, written}
      end
    end
  end

  defp write_bounded(io, data, written, max) do
    written = written + IO.iodata_length(data)

    if written > max do
      {:error, :too_large}
    else
      :ok = :file.write(io, data)
      {:ok, written}
    end
  end

  defp finish(:identity), do: :ok

  # `inflateEnd` raises when the gzip stream did not end (a truncated body).
  defp finish({:gzip, z}) do
    :zlib.inflateEnd(z)
  rescue
    ErlangError -> {:error, :invalid_gzip}
  end

  defp stream_git(conn, repo, mode, content_type, prefix, settings) do
    protocol = get_req_header(conn, "git-protocol") |> List.first()
    state = %{conn: conn, started: false, content_type: content_type, prefix: prefix}
    opts = [idle_timeout_ms: settings.git_mirror.idle_timeout_ms]

    case UploadPack.stream(repo.cache_path, mode, protocol, opts, state, &send_chunk/2) do
      {:ok, state} ->
        state |> start_response() |> Map.fetch!(:conn)

      {:error, reason, %{started: false, conn: conn}} ->
        Logger.warning("Git mirror upload-pack failed repo=#{repo.repo_key} reason=#{inspect(reason)}")
        error(conn, 500, "git_failed")

      {:error, reason, %{conn: conn}} ->
        Logger.warning("Git mirror upload-pack stopped mid-response repo=#{repo.repo_key} reason=#{inspect(reason)}")
        Conn.halt(conn)
    end
  end

  defp send_chunk(data, state) do
    state = start_response(state)

    case Conn.chunk(state.conn, data) do
      {:ok, conn} -> {:cont, %{state | conn: conn}}
      {:error, _reason} -> {:halt, state}
    end
  end

  # Headers go out with git's first output, so a git that fails before
  # writing anything still gets a plain 500.
  defp start_response(%{started: true} = state), do: state

  defp start_response(%{conn: conn} = state) do
    conn =
      conn
      |> put_resp_header("content-type", state.content_type)
      |> put_resp_header("cache-control", "no-cache")
      |> Conn.send_chunked(200)

    conn =
      case state.prefix do
        "" ->
          conn

        prefix ->
          {:ok, conn} = Conn.chunk(conn, prefix)
          conn
      end

    %{state | conn: conn, started: true}
  end

  defp content_encoding(conn) do
    get_req_header(conn, "content-encoding") |> List.first() |> to_string() |> String.trim() |> String.downcase()
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_header("cache-control", "no-cache")
    |> Conn.send_resp(status, message)
    |> Conn.halt()
  end
end
