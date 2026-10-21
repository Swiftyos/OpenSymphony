defmodule SymphonyElixir.SSH do
  @moduledoc false

  @spec run(String.t(), String.t(), keyword()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      {:ok, System.cmd(executable, ssh_args(host, command), opts)}
    end
  end

  @doc """
  Runs `script` remotely with `env` set in the remote process.

  The environment and script travel on ssh's stdin (`bash -s`), not in the ssh
  command line, so a token does not appear in `ps` output on either host. The
  script is wrapped in a `{ ...; }` group so bash parses it completely before
  running it, and a command that reads stdin cannot consume the rest of it.
  """
  @spec run_with_env(String.t(), String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run_with_env(host, script, env, opts \\ [])
      when is_binary(host) and is_binary(script) and is_list(env) do
    with {:ok, executable} <- ssh_executable() do
      port_opts = [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(ssh_args(host, "bash -s"), &String.to_charlist/1)
      ]

      port = Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)
      payload = "{\n" <> env_exports(env) <> script <> "\n}\nexit\n"
      true = Port.command(port, payload)
      collect_port_output(port, [], Keyword.get(opts, :timeout, 60_000))
    end
  end

  @doc """
  Starts `command` on `host` over ssh and returns the port.

  Option `:env` is a list of `{name, value}` pairs set in the remote process.
  Their values never appear in the ssh command line (and so never in `ps` on
  either host): the remote shell first reads one line per variable from stdin
  (`IFS= read -r NAME`), decodes it, and exports it, and only then runs
  `command`. The encoded values are written to the port before anything else,
  so the agent's protocol traffic follows them on the same stdin. bash reads a
  pipe one byte at a time for `read`, so it leaves the protocol bytes unread
  for the agent.

  Values are sent with backslash, newline, and carriage return escaped, and
  decoded with `printf -v NAME '%b'`.
  """
  @spec start_port(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start_port(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable(),
         {:ok, env} <- validate_env(Keyword.get(opts, :env, [])) do
      line_bytes = Keyword.get(opts, :line)

      port_opts =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(ssh_args(host, stdin_env_prefix(env) <> command), &String.to_charlist/1)
        ]
        |> maybe_put_line_option(line_bytes)

      port = Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)
      if env != [], do: true = Port.command(port, stdin_env_payload(env))
      {:ok, port}
    end
  end

  defp validate_env(env) when is_list(env) do
    env = Enum.map(env, fn {key, value} -> {to_string(key), to_string(value)} end)

    case Enum.reject(env, fn {key, value} -> valid_env_name?(key) and not String.contains?(value, <<0>>) end) do
      [] -> {:ok, env}
      invalid -> {:error, {:invalid_remote_env, Enum.map(invalid, &elem(&1, 0))}}
    end
  end

  defp valid_env_name?(key), do: String.match?(key, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp stdin_env_prefix(env) do
    Enum.map_join(env, "", fn {key, _value} ->
      "IFS= read -r #{key} && printf -v #{key} '%b' \"$#{key}\" && export #{key} && "
    end)
  end

  defp stdin_env_payload(env) do
    Enum.map_join(env, "", fn {_key, value} -> encode_env_value(value) <> "\n" end)
  end

  defp encode_env_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
  end

  @spec remote_shell_command(String.t()) :: String.t()
  def remote_shell_command(command) when is_binary(command) do
    "bash -lc " <> shell_escape(command)
  end

  defp collect_port_output(port, chunks, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, [data | chunks], timeout)

      {^port, {:exit_status, status}} ->
        {:ok, {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}}
    after
      timeout ->
        Port.close(port)
        {:error, :ssh_timeout}
    end
  end

  defp env_exports(env) do
    Enum.map_join(env, "", fn {key, value} -> "export #{key}=#{shell_escape(to_string(value))}\n" end)
  end

  defp ssh_executable do
    case System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp ssh_args(host, command) do
    %{destination: destination, port: port} = parse_target(host)

    []
    |> maybe_put_config()
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> Kernel.++([destination, remote_shell_command(command)])
  end

  defp maybe_put_line_option(port_opts, nil), do: port_opts
  defp maybe_put_line_option(port_opts, line_bytes), do: Keyword.put(port_opts, :line, line_bytes)

  defp maybe_put_config(args) do
    case System.get_env("SYMPHONY_SSH_CONFIG") do
      config_path when is_binary(config_path) and config_path != "" ->
        args ++ ["-F", config_path]

      _ ->
        args
    end
  end

  defp maybe_put_port(args, nil), do: args
  defp maybe_put_port(args, port), do: args ++ ["-p", port]

  defp parse_target(target) when is_binary(target) do
    trimmed_target = String.trim(target)

    # OpenSSH does not interpret bare "host:port" as "host + port"; it treats the
    # whole value as a hostname and leaves the port at 22. We split that shorthand
    # here so worker config can use "localhost:2222" without requiring ssh:// URIs.
    case Regex.run(~r/^(.*):(\d+)$/, trimmed_target, capture: :all_but_first) do
      [destination, port] ->
        if valid_port_destination?(destination) do
          %{destination: destination, port: port}
        else
          %{destination: trimmed_target, port: nil}
        end

      _ ->
        %{destination: trimmed_target, port: nil}
    end
  end

  defp valid_port_destination?(destination) when is_binary(destination) do
    destination != "" and
      (not String.contains?(destination, ":") or bracketed_host?(destination))
  end

  defp bracketed_host?(destination) when is_binary(destination) do
    # IPv6 literals contain ":" already, so we only accept additional ":port"
    # parsing when the host is explicitly bracketed, e.g. "[::1]:2222".
    String.contains?(destination, "[") and String.contains?(destination, "]")
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
