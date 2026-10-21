defmodule SymphonyElixir.RepoCacheRefresher do
  @moduledoc """
  Keeps each project's repo cache warm in the background.

  Every `workspace.repo_cache.refresh_interval_ms` it syncs the configured
  project repos on the local host, one at a time, using the same cache lock as
  the workspace flow. Agent starts then find the cache inside its
  `workspace.repo_cache.max_age_ms` window and skip their own remote fetch, so
  GitHub traffic stays around one fetch per repo per interval no matter how
  many agents start. `refresh_interval_ms: 0` turns the refresher off.

  Disabled in tests (`:repo_cache_refresher_enabled`), like the other
  background boot tasks.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, Workspace}
  alias SymphonyElixir.Config.Schema

  @startup_delay_ms 5_000
  @settings_retry_ms 60_000

  @type option ::
          {:name, GenServer.name()}
          | {:settings_fun, (-> {:ok, Schema.t()} | {:error, term()})}
          | {:sync_fun, (map(), Schema.t() -> :ok | {:error, term()})}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Runs a refresh pass now instead of waiting for the next interval."
  @spec refresh_now(GenServer.name()) :: :ok
  def refresh_now(server) do
    GenServer.cast(server, :refresh_now)
  end

  @impl true
  def init(opts) do
    state = %{
      settings_fun: Keyword.get(opts, :settings_fun, &Config.settings/0),
      sync_fun: Keyword.get(opts, :sync_fun, &Workspace.refresh_repo_cache/2),
      timer_ref: nil
    }

    if refresher_enabled?() do
      {:ok, schedule_next(state, @startup_delay_ms)}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    {:noreply, run_refresh(state)}
  end

  @impl true
  def handle_cast(:refresh_now, state) do
    {:noreply, run_refresh(state)}
  end

  defp refresher_enabled? do
    Application.get_env(:symphony_elixir, :repo_cache_refresher_enabled, true)
  end

  defp run_refresh(state) do
    case state.settings_fun.() do
      {:ok, %Schema{} = settings} ->
        refresh_repos(settings, state.sync_fun)
        schedule_after_refresh(state, settings)

      {:error, reason} ->
        Logger.warning("Repo cache refresh skipped: could not load settings reason=#{inspect(reason)}")
        schedule_next(state, @settings_retry_ms)
    end
  rescue
    error ->
      Logger.warning("Repo cache refresh skipped: #{Exception.message(error)}")
      schedule_next(state, @settings_retry_ms)
  end

  defp refresh_repos(%Schema{workspace: %{repo_cache: %{refresh_interval_ms: 0}}}, _sync_fun), do: :ok

  defp refresh_repos(%Schema{} = settings, sync_fun) do
    settings
    |> Config.linear_project_routes()
    |> Enum.each(fn route ->
      if is_binary(Map.get(route, :repo)) and Map.get(route, :repo) != "" do
        refresh_route(route, settings, sync_fun)
      end
    end)
  end

  defp refresh_route(route, settings, sync_fun) do
    case sync_fun.(route, settings) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Repo cache refresh failed repo=#{repo_label(route)} reason=#{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning("Repo cache refresh crashed repo=#{repo_label(route)} error=#{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.warning("Repo cache refresh crashed repo=#{repo_label(route)} kind=#{kind} reason=#{inspect(reason)}")
  end

  defp repo_label(route), do: Map.get(route, :repo) || "unknown"

  defp schedule_after_refresh(state, %Schema{workspace: %{repo_cache: %{refresh_interval_ms: interval_ms}}})
       when is_integer(interval_ms) and interval_ms > 0 do
    schedule_next(state, interval_ms)
  end

  defp schedule_after_refresh(state, _settings) do
    cancel_timer(state.timer_ref)
    %{state | timer_ref: nil}
  end

  defp schedule_next(state, delay_ms) do
    cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :refresh, max(delay_ms, 1_000))
    %{state | timer_ref: timer_ref}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
end
