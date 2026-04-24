defmodule SymphonyElixir.ClaudeCode.RateLimitPoller do
  @moduledoc """
  Periodically probes Anthropic with each stored Claude OAuth account, so the
  `symphony_account_rate_limit_*` metrics (and the `Account Usage` dashboard)
  populate without waiting for a real workflow run to surface rate-limit
  payloads. Runs automatically whenever `accounts.enabled` is `true`.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.ClaudeCode.RateLimitProbe
  alias SymphonyElixir.{Accounts, Config}

  @startup_delay_ms 5_000
  @idle_reschedule_ms 300_000

  @type option :: {:name, GenServer.name()} | {:probe_fun, (map() -> {:ok, map()} | {:error, term()})}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Force an immediate poll cycle. Returns `:ok`; results show up via telemetry
  and account state files.
  """
  @spec poll_now(GenServer.name()) :: :ok
  def poll_now(server \\ __MODULE__) do
    GenServer.cast(server, :poll_now)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      probe_fun: Keyword.get(opts, :probe_fun, &RateLimitProbe.probe/1),
      timer_ref: nil
    }

    {:ok, schedule_next(state, @startup_delay_ms)}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {:noreply, run_poll_cycle(state)}
  end

  @impl GenServer
  def handle_cast(:poll_now, state) do
    {:noreply, run_poll_cycle(state)}
  end

  defp run_poll_cycle(state) do
    case accounts_settings() do
      %{enabled: true} = accounts_settings ->
        probe_all(state, accounts_settings)
        schedule_next(state, accounts_settings.claude_rate_limit_probe_interval_ms)

      _ ->
        schedule_next(state, @idle_reschedule_ms)
    end
  end

  defp probe_all(state, accounts_settings) do
    {:ok, accounts} = Accounts.list("claude")

    accounts
    |> Enum.filter(&probeable?/1)
    |> Enum.each(&probe_account(&1, state, accounts_settings))
  end

  defp probe_account(account, state, accounts_settings) do
    try do
      case state.probe_fun.(account) do
        {:ok, rate_limits} ->
          Accounts.record_rate_limits(account, rate_limits, settings_struct(accounts_settings))

        {:error, _reason} ->
          :ok
      end
    rescue
      error ->
        Logger.warning(
          "RateLimitPoller probe crashed for #{account_label(account)}: #{Exception.message(error)}"
        )
    end
  end

  defp probeable?(%{enabled: false}), do: false
  defp probeable?(%{state: state}) when state in ["disabled", "paused", "exhausted"], do: false
  defp probeable?(_account), do: true

  defp schedule_next(state, delay_ms) do
    cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :poll, max(delay_ms, 1_000))
    %{state | timer_ref: timer_ref}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  defp accounts_settings do
    Config.accounts_settings()
  rescue
    error ->
      Logger.debug("RateLimitPoller could not read accounts settings: #{Exception.message(error)}")
      %{enabled: false, claude_rate_limit_probe_interval_ms: @idle_reschedule_ms}
  end

  defp settings_struct(_accounts_settings) do
    Config.settings!()
  rescue
    _ -> nil
  end

  defp account_label(%{backend: backend, id: id}) when is_binary(backend) and is_binary(id) do
    "#{backend}:#{id}"
  end

  defp account_label(_account), do: "claude:unknown"
end
