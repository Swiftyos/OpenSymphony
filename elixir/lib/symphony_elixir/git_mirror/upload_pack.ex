defmodule SymphonyElixir.GitMirror.UploadPack do
  @moduledoc """
  Runs `git upload-pack` for the read-only mirror.

  The smart HTTP protocol is only a thin wrapper around the git binary:
  `--advertise-refs` answers `info/refs`, and `--stateless-rpc` consumes one
  request and writes one response. The request body is fed through stdin and
  the response is streamed back out of the child; both are bounded and the
  child has a deadline, so a stuck git process cannot pin a request forever.
  `GIT_PROTOCOL` selects protocol v2 when the client sent the header.

  A port cannot half-close stdin, so the child reads through a FIFO: a writer
  task fills it while the port's stdout is read, which avoids a deadlock when
  a large request and a large response are both in flight.
  """

  @max_body_bytes 8_388_608
  @timeout_ms 60_000

  @doc "The largest request body the endpoint accepts."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "The advertised refs for `info/refs`, with the smart HTTP service prefix."
  @spec advertise(Path.t(), String.t() | nil) :: {:ok, binary()} | {:error, term()}
  @spec advertise(Path.t(), String.t() | nil, non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def advertise(cache_path, protocol, timeout_ms \\ @timeout_ms) when is_binary(cache_path) do
    case run(cache_path, ["--stateless-rpc", "--advertise-refs"], "", protocol, timeout_ms) do
      {:ok, refs} -> {:ok, pkt_line("# service=git-upload-pack\n") <> "0000" <> refs}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The `git-upload-pack` response for one request body."
  @spec result(Path.t(), binary(), String.t() | nil) :: {:ok, binary()} | {:error, term()}
  @spec result(Path.t(), binary(), String.t() | nil, non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def result(cache_path, body, protocol, timeout_ms \\ @timeout_ms)
      when is_binary(cache_path) and is_binary(body) do
    run(cache_path, ["--stateless-rpc"], body, protocol, timeout_ms)
  end

  defp run(cache_path, args, input, protocol, timeout_ms) do
    with {:ok, git} <- find_git(),
         {:ok, fifo_dir, fifo} <- make_fifo() do
      try do
        stream(git, ["upload-pack" | args] ++ [cache_path], fifo, input, protocol, timeout_ms)
      after
        File.rm_rf(fifo_dir)
      end
    end
  end

  defp find_git do
    case System.find_executable("git") do
      nil -> {:error, :git_not_found}
      git -> {:ok, git}
    end
  end

  defp make_fifo do
    dir = Path.join(System.tmp_dir!(), "symphony-git-mirror-#{System.unique_integer([:positive])}")
    fifo = Path.join(dir, "stdin")
    File.mkdir_p!(dir)

    case System.cmd("mkfifo", [fifo], stderr_to_stdout: true) do
      {_output, 0} -> {:ok, dir, fifo}
      {_output, status} -> {:error, {:fifo_failed, status}}
    end
  end

  defp stream(git, args, fifo, input, protocol, timeout_ms) do
    case System.find_executable("sh") do
      nil ->
        {:error, :shell_not_found}

      shell ->
        port = open_port(shell, [git | args], fifo, protocol)
        writer = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> write_fifo(fifo, input) end)

        try do
          read_port(port, [], System.monotonic_time(:millisecond) + timeout_ms)
        after
          if Port.info(port) != nil, do: Port.close(port)
          Task.shutdown(writer, :brutal_kill)
        end
    end
  end

  defp open_port(shell, args, fifo, protocol) do
    # `sh` opens the FIFO for reading before exec, so the writer can open its
    # end without racing the child; `$@` then becomes git and its arguments.
    script = "fifo=\"$1\"; shift; exec \"$@\" < \"$fifo\""

    Port.open(
      {:spawn_executable, shell},
      [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: ["-c", script, "sh", fifo] ++ args,
        env: protocol_env(protocol)
      ]
    )
  end

  defp write_fifo(fifo, body) do
    {:ok, io} = File.open(fifo, [:write, :binary])

    try do
      IO.binwrite(io, body)
    after
      File.close(io)
    end
  end

  defp read_port(port, acc, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        read_port(port, [data | acc], deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        {:error, {:git_upload_pack_failed, status}}
    after
      timeout ->
        {:error, :timeout}
    end
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
