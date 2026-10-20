defmodule SymphonyElixir.DelayedRestartSignal do
  @moduledoc """
  SIGHUP asks for a delayed restart (`Orchestrator.request_delayed_restart/2`),
  so `systemctl reload symphony` (with `ExecReload=/bin/kill -HUP $MAINPID`)
  restarts Symphony without cutting off running agents.

  Added beside OTP's own signal handler, never in place of it, so SIGTERM
  still stops Symphony as before.
  """

  @behaviour :gen_event

  require Logger

  @spec install() :: :ok
  def install do
    if Application.get_env(:symphony_elixir, :handle_sighup, true) do
      :os.set_signal(:sighup, :handle)

      case :gen_event.add_handler(:erl_signal_server, __MODULE__, []) do
        :ok -> :ok
        {:error, _already_installed} -> :ok
        {:EXIT, _reason} -> :ok
      end
    end

    :ok
  end

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(:sighup, state) do
    Logger.warning("SIGHUP received: delayed restart")
    _ = Task.start(fn -> SymphonyElixir.Orchestrator.request_delayed_restart("SIGHUP") end)
    {:ok, state}
  end

  def handle_event(_signal, state), do: {:ok, state}

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl true
  def handle_info(_message, state), do: {:ok, state}
end
