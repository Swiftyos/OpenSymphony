defmodule SymphonyElixir.RunTokenTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HttpServer
  alias SymphonyElixir.RunToken
  alias SymphonyElixirWeb.Endpoint

  @secret String.duplicate("t", 64)

  setup do
    previous = Application.get_env(:symphony_elixir, Endpoint)
    Application.put_env(:symphony_elixir, Endpoint, secret_key_base: @secret)
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, previous) end)
    :ok
  end

  test "a token is url-safe base64 of the HMAC for run id and epoch" do
    token = RunToken.sign("run-1", 3)

    assert token ==
             Base.url_encode64(:crypto.mac(:hmac, :sha256, @secret, "run-1:3"), padding: false)

    refute token =~ "/"
    refute token =~ "+"
    refute token =~ "="
    assert RunToken.verify("run-1", 3, token)
  end

  test "verification refuses another run, another epoch, a bad token and nil" do
    token = RunToken.sign("run-1", 3)

    refute RunToken.verify("run-2", 3, token)
    refute RunToken.verify("run-1", 4, token)
    refute RunToken.verify("run-1", 3, RunToken.sign("run-1", 3) <> "x")
    refute RunToken.verify("run-1", 3, nil)
    refute RunToken.verify("run-1", 0, token)
    refute RunToken.verify(nil, 3, token)
  end

  test "verify_any_epoch tells a stale token from a forged one" do
    stale = RunToken.sign("run-1", 2)

    assert RunToken.verify_any_epoch("run-1", stale, 4)
    refute RunToken.verify_any_epoch("run-1", "forged", 4)
    refute RunToken.verify_any_epoch("run-1", nil, 4)
    refute RunToken.verify_any_epoch("run-1", stale, 0)
  end

  test "the secret falls back to the endpoint's persisted secret when the endpoint isn't running" do
    tmp = Path.join(System.tmp_dir!(), "symphony-run-token-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "secret_key_base")
    File.write!(path, String.duplicate("p", 64))
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint)
    previous_path = Application.get_env(:symphony_elixir, :secret_key_base_path)

    try do
      Application.delete_env(:symphony_elixir, Endpoint)
      Application.put_env(:symphony_elixir, :secret_key_base_path, path)

      assert RunToken.secret() == String.duplicate("p", 64)
      assert RunToken.secret() == HttpServer.secret_key_base()
      assert RunToken.verify("run-2", 1, RunToken.sign("run-2", 1))
    after
      File.rm_rf(tmp)

      case previous_endpoint do
        nil -> Application.delete_env(:symphony_elixir, Endpoint)
        value -> Application.put_env(:symphony_elixir, Endpoint, value)
      end

      case previous_path do
        nil -> Application.delete_env(:symphony_elixir, :secret_key_base_path)
        value -> Application.put_env(:symphony_elixir, :secret_key_base_path, value)
      end
    end
  end
end
