defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Compatibility facade that starts the Phoenix observability endpoint when enabled.
  """

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.Endpoint

  @secret_key_bytes 48

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Keyword.get(opts, :port, Config.server_port()) do
      port when is_integer(port) and port >= 0 ->
        host = Keyword.get(opts, :host, Config.settings!().server.host)
        orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
        snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

        with {:ok, ip} <- parse_host(host) do
          endpoint_opts = [
            server: true,
            http: [ip: ip, port: port],
            url: [host: normalize_host(host)],
            orchestrator: orchestrator,
            snapshot_timeout_ms: snapshot_timeout_ms,
            secret_key_base: secret_key_base(),
            # Refuse LiveView sockets opened from other sites: with sign-in, the page's
            # own host; without it, only localhost (DNS-rebinding protection).
            check_origin: if(SymphonyElixir.Auth.mode() == :accounts, do: :conn, else: SymphonyElixirWeb.RequestGuards.local_origins())
          ]

          endpoint_config =
            :symphony_elixir
            |> Application.get_env(Endpoint, [])
            |> Keyword.merge(endpoint_opts)

          Application.put_env(:symphony_elixir, Endpoint, endpoint_config)

          with {:ok, _pid} = started <- Endpoint.start_link() do
            # On a fresh install the first-account setup code goes to the log at boot.
            if SymphonyElixir.Auth.mode() == :accounts, do: SymphonyElixir.Users.setup_code()
            started
          end
        end

      _ ->
        :ignore
    end
  end

  @spec bound_port(term()) :: non_neg_integer() | nil
  def bound_port(_server \\ __MODULE__) do
    case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
      {:ok, {_ip, port}} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  defp normalize_host(host) when host in ["", nil], do: "127.0.0.1"
  defp normalize_host(host) when is_binary(host), do: host
  defp normalize_host(host), do: to_string(host)

  # Signs and encrypts session cookies; it must be stable across restarts or
  # everyone is signed out on deploy. Anyone holding it can forge sessions.
  defp secret_key_base do
    configured = Config.settings!().server.secret_key_base || System.get_env("SYMPHONY_SECRET_KEY_BASE")

    cond do
      is_binary(configured) and byte_size(configured) >= 64 -> configured
      path = secret_key_base_path() -> persisted_secret_key_base(path)
      true -> generate_secret_key_base()
    end
  end

  defp secret_key_base_path do
    case Application.get_env(:symphony_elixir, :secret_key_base_path, :default) do
      :default -> Path.expand("~/.symphony/secret_key_base")
      path -> path
    end
  end

  defp persisted_secret_key_base(path) do
    case File.read(path) do
      {:ok, secret} when byte_size(secret) >= 64 ->
        String.trim(secret)

      _ ->
        case SymphonyElixir.PrivateFile.create_once(path, generate_secret_key_base()) do
          {:ok, secret} when byte_size(secret) >= 64 -> String.trim(secret)
          _error -> generate_secret_key_base()
        end
    end
  end

  defp generate_secret_key_base do
    Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
  end
end
