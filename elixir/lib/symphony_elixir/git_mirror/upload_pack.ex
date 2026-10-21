defmodule SymphonyElixir.GitMirror.UploadPack do
  @moduledoc """
  Runs `git upload-pack` for the read-only mirror.

  The smart HTTP protocol is only a thin wrapper around the git binary:
  `--advertise-refs` answers `info/refs`, and `--stateless-rpc` consumes one
  request and writes one response. `GIT_PROTOCOL` selects protocol v2 when the
  client sent the header.

  The request body is written to an owner-only file in an owner-only,
  per-request directory (`create_request_file/1`), and git reads it as stdin
  (`sh -c 'exec git ... < file'`), so the port only ever reads. The response is
  handed to a callback chunk by chunk as the port delivers it; nothing is
  buffered here, so a large pack streams through in bounded memory.

  There is no total deadline, only an idle timeout: a clone of a large repo
  may take long, but git must keep producing output. On an idle timeout, when
  the callback halts (the client went away), when the callback raises, or when
  the calling process dies, the git process is killed by its OS pid.
  `upload-pack`'s own children (`pack-objects`) then die on SIGPIPE.
  """

  @max_body_bytes 8_388_608
  @default_idle_timeout_ms 60_000

  # `$1` is the stdin file; the rest is git and its arguments. `exec` keeps the
  # port's OS pid pointing at git, so killing that pid kills git.
  @script ~S(input="$1"; shift; exec "$@" < "$input")

  @type mode :: :advertise | {:request, Path.t()}
  @type step(acc) :: (binary(), acc -> {:cont, acc} | {:halt, acc})

  @doc "The largest request body the endpoint accepts, before and after decompression."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "The smart HTTP preamble that precedes the refs in an `info/refs` response."
  @spec service_header() :: binary()
  def service_header, do: pkt_line("# service=git-upload-pack\n") <> "0000"

  @doc """
  Runs upload-pack against `cache_path` and feeds each output chunk to `fun`.

  `mode` is `:advertise` for `info/refs`, or `{:request, path}` to answer the
  request body stored at `path`. Options: `:idle_timeout_ms` (default
  #{@default_idle_timeout_ms}), the longest wait for the next output chunk.
  Returns the final accumulator; on an error the accumulator holds whatever
  the callback built before it. `{:error, :halted, acc}` means the callback
  asked to stop.
  """
  @spec stream(Path.t(), mode(), String.t() | nil, keyword(), acc, step(acc)) ::
          {:ok, acc} | {:error, term(), acc}
        when acc: term()
  def stream(cache_path, mode, protocol, opts, acc, fun)
      when is_binary(cache_path) and is_list(opts) and is_function(fun, 2) do
    idle_timeout_ms = Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms)

    with {:ok, git} <- find_executable("git", :git_not_found),
         {:ok, shell} <- find_executable("sh", :shell_not_found) do
      {args, input} =
        case mode do
          :advertise -> {["--stateless-rpc", "--advertise-refs"], "/dev/null"}
          {:request, path} when is_binary(path) -> {["--stateless-rpc"], path}
        end

      run(shell, [input, git, "upload-pack" | args] ++ [cache_path], protocol, idle_timeout_ms, acc, fun)
    else
      {:error, reason} -> {:error, reason, acc}
    end
  end

  @doc """
  Creates an empty, owner-only request file in a fresh owner-only directory
  under `base` and returns the directory, the file path and an open raw file.

  The directory name is random and made with a plain `mkdir`, which fails on
  any existing entry (a planted directory or symlink included) rather than
  reusing it, so the directory is always one this process created; `chmod`
  then makes it `0700`. The file is opened with `O_EXCL` and made `0600`
  before anything is written. Remove it with `remove_request_dir/1`.
  """
  @spec create_request_file(Path.t()) :: {:ok, Path.t(), Path.t(), :file.io_device()} | {:error, term()}
  def create_request_file(base \\ System.tmp_dir!()) when is_binary(base) do
    dir = Path.join(base, "symphony-git-mirror-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))
    path = Path.join(dir, "request")

    with :ok <- :file.make_dir(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, io} <- :file.open(path, [:write, :exclusive, :binary, :raw]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, dir, path, io}
    end
  end

  @doc "Removes a directory made by `create_request_file/1`."
  @spec remove_request_dir(Path.t()) :: :ok
  def remove_request_dir(dir) when is_binary(dir) do
    _ = File.rm_rf(dir)
    :ok
  end

  defp find_executable(name, error) do
    case System.find_executable(name) do
      nil -> {:error, error}
      path -> {:ok, path}
    end
  end

  defp run(shell, args, protocol, idle_timeout_ms, acc, fun) do
    port =
      Port.open(
        {:spawn_executable, shell},
        [:binary, :exit_status, :use_stdio, :hide, args: ["-c", @script, "sh" | args], env: protocol_env(protocol)]
      )

    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
    guard = start_guard(self(), shell, os_pid)

    # Every path waits for the exit status, so the port is closed (and its OS
    # pid reaped) before this returns; the guard covers the caller dying.
    try do
      read_port(port, shell, os_pid, idle_timeout_ms, acc, fun)
    catch
      kind, reason ->
        kill_and_wait(port, shell, os_pid)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      send(guard, :done)
    end
  end

  defp read_port(port, shell, os_pid, idle_timeout_ms, acc, fun) do
    receive do
      {^port, {:data, data}} ->
        case fun.(data, acc) do
          {:cont, acc} ->
            read_port(port, shell, os_pid, idle_timeout_ms, acc, fun)

          {:halt, acc} ->
            kill_and_wait(port, shell, os_pid)
            {:error, :halted, acc}
        end

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, status}} ->
        {:error, {:git_upload_pack_failed, status}, acc}
    after
      idle_timeout_ms ->
        kill_and_wait(port, shell, os_pid)
        {:error, :timeout, acc}
    end
  end

  # Kills git if the request process dies (for example when the connection
  # handler is shut down because the client disconnected) before git exits.
  defp start_guard(owner, shell, os_pid) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :done -> :ok
        {:DOWN, ^ref, :process, _pid, _reason} -> kill(shell, os_pid)
      end
    end)
  end

  # No exit status was read yet, so the pid is not reaped and still git's.
  # Drain the port until git's exit status arrives.
  defp kill_and_wait(port, shell, os_pid) do
    kill(shell, os_pid)
    await_exit(port)
  end

  defp await_exit(port) do
    receive do
      {^port, message} -> if match?({:exit_status, _status}, message), do: :ok, else: await_exit(port)
    end
  end

  defp kill(shell, os_pid) do
    _ = System.cmd(shell, ["-c", "kill -KILL \"$1\" 2>/dev/null || true", "sh", Integer.to_string(os_pid)])
    :ok
  end

  defp protocol_env(protocol) when is_binary(protocol) do
    if String.match?(protocol, ~r/\A[A-Za-z0-9=:._-]+\z/),
      do: [{~c"GIT_PROTOCOL", String.to_charlist(protocol)}],
      else: []
  end

  defp protocol_env(_protocol), do: []

  defp pkt_line(payload) do
    length = byte_size(payload) + 4
    (length |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase()) <> payload
  end
end
