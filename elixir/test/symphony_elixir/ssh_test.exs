# credo:disable-for-this-file Credo.Check.Readability.StringSigils
defmodule SymphonyElixir.SSHTest do
  use ExUnit.Case, async: false

  # Real git/process/HTTP integration; excluded by `make test-fast`.
  @moduletag :slow

  alias SymphonyElixir.SSH

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@[::1]:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@[::1] bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 leaves unbracketed IPv6-style targets unchanged" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-raw-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("::1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T ::1:2200 bash -lc"
    refute trace =~ "-p 2200"
  end

  test "run/3 passes host:port targets through ssh -p" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)
    System.put_env("SYMPHONY_SSH_CONFIG", "/tmp/symphony-test-ssh-config")

    assert {:ok, {"", 0}} =
             SSH.run("localhost:2222", "echo ready", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-F /tmp/symphony-test-ssh-config"
    assert trace =~ "-T -p 2222 localhost bash -lc"
    assert trace =~ "echo ready"
  end

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-user-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@127.0.0.1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@127.0.0.1 bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "run_with_env/4 sends the environment over stdin, not ssh argv" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-env-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    stdin_file = Path.join(test_root, "ssh.stdin")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    head -n 3 > "#{stdin_file}"
    printf 'remote output\\n'
    exit 7
    """)

    token = "ghs_" <> String.duplicate("a", 36)

    assert {:ok, {"remote output\n", 7}} =
             SSH.run_with_env("localhost", "printf '%s' \"$GH_TOKEN\"", [{"GH_TOKEN", token}], stderr_to_stdout: true)

    assert File.read!(trace_file) =~ "bash -lc"
    refute File.read!(trace_file) =~ token
    stdin = File.read!(stdin_file)
    assert stdin =~ "export GH_TOKEN='#{token}'"
    assert stdin =~ "printf '%s'"
  end

  test "run_with_env/4 times out" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-env-timeout-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    sleep 1
    exit 0
    """)

    assert {:error, :ssh_timeout} = SSH.run_with_env("localhost", "true", [], timeout: 10)
  end

  test "run_with_env/4 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-env-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run_with_env("localhost", "true", [])
  end

  test "start_port/3 sends env values escaped on stdin, ahead of anything else" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-env-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    stdin_file = Path.join(test_root, "ssh.stdin")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    head -n 2 > "#{stdin_file}.tmp" && mv "#{stdin_file}.tmp" "#{stdin_file}"
    exit 0
    """)

    assert {:ok, port} = SSH.start_port("localhost", "printf ok", env: [{"GREETING", "line1\nline2\r\\end"}, {:TOKEN, "plain"}])
    assert is_port(port)
    wait_for_trace!(stdin_file)
    assert File.read!(stdin_file) == "line1\\nline2\\r\\\\end\nplain\n"

    trace = File.read!(trace_file)
    assert trace =~ "IFS= read -r GREETING"
    assert trace =~ "IFS= read -r TOKEN"
    refute trace =~ "plain"
    refute trace =~ "line1"
  end

  test "start_port/3 env reaches the remote command, and protocol bytes after it reach the agent" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-env-exec-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    out_dir = Path.join(test_root, "out")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(out_dir)

    # Runs the remote command the way sshd would, minus the login shell.
    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    for arg in "$@"; do last_arg="$arg"; done
    eval "$(printf '%s' "$last_arg" | sed 's/^bash -lc /bash -c /')"
    """)

    token = "ghs_" <> String.duplicate("t", 36)
    tricky = "multi\nline 'quoted' \\n \\\\ $HOME `x` \r\\c \\0101 end"
    header = "Authorization: Basic " <> Base.encode64("x-access-token:" <> token)

    agent =
      "printf '%s' \"$GH_TOKEN\" > #{out_dir}/token && printf '%s' \"$TRICKY\" > #{out_dir}/tricky && " <>
        "printf '%s' \"$GIT_CONFIG_VALUE_0\" > #{out_dir}/header && IFS= read -r line && printf '%s' \"$line\" > #{out_dir}/protocol"

    assert {:ok, port} =
             SSH.start_port("localhost", agent, env: [{"GH_TOKEN", token}, {"TRICKY", tricky}, {"GIT_CONFIG_VALUE_0", header}])

    true = Port.command(port, ~s({"jsonrpc":"2.0","id":1}\n))
    assert_receive {^port, {:exit_status, 0}}, 10_000

    assert File.read!(Path.join(out_dir, "token")) == token
    assert File.read!(Path.join(out_dir, "tricky")) == tricky
    assert File.read!(Path.join(out_dir, "header")) == header
    assert File.read!(Path.join(out_dir, "protocol")) == ~s({"jsonrpc":"2.0","id":1})

    argv = File.read!(trace_file)
    refute argv =~ token
    refute argv =~ Base.encode64("x-access-token:" <> token)
    refute argv =~ "multi"
  end

  test "start_port/3 rejects invalid remote environment names and values" do
    assert {:error, {:invalid_remote_env, ["bad-name", "NUL"]}} =
             SSH.start_port("localhost", "printf ok", env: [{"bad-name", "x"}, {"NUL", <<0>>}, {"OK", "fine"}])
  end

  test "start_port/3 supports binary output without line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    System.delete_env("SYMPHONY_SSH_CONFIG")

    assert {:ok, port} = SSH.start_port("localhost", "printf ok")
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T localhost bash -lc"
    refute trace =~ " -F "
  end

  test "start_port/3 supports line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-line-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    assert {:ok, port} = SSH.start_port("localhost:2222", "printf ok", line: 256)
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2222 localhost bash -lc"
  end

  test "remote_shell_command/1 escapes embedded single quotes" do
    assert SSH.remote_shell_command("printf 'hello'") ==
             "bash -lc 'printf '\"'\"'hello'\"'\"''"
  end

  defp install_fake_ssh!(test_root, trace_file, script \\ nil) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      script ||
        """
        #!/bin/sh
        printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
        exit 0
        """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp wait_for_trace!(trace_file, attempts \\ 200)
  defp wait_for_trace!(trace_file, 0), do: flunk("timed out waiting for fake ssh trace at #{trace_file}")

  defp wait_for_trace!(trace_file, attempts) do
    if File.exists?(trace_file) and File.read!(trace_file) != "" do
      :ok
    else
      Process.sleep(25)
      wait_for_trace!(trace_file, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
