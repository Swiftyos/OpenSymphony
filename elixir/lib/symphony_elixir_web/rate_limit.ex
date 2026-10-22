defmodule SymphonyElixirWeb.RateLimit do
  @moduledoc """
  Fixed-window, per-client-IP limits for endpoints outside the dashboard's
  sign-in. In-memory only; resets on restart.

  Behind a reverse proxy every request shares the proxy's IP, so these limits
  then apply to all clients together; see the README.
  """

  import Plug.Conn

  @table :symphony_rate_limit

  @limits %{
    # The MCP endpoint, per client IP; generous for busy agents.
    mcp: {600, 60_000},
    # GitHub App token refreshes, per run (`check/2`): a runner needs about one
    # an hour, plus retries with backoff.
    runner_github_token: {10, 10 * 60_000}
  }

  @spec init(atom()) :: atom()
  def init(action) when is_map_key(@limits, action), do: action

  @spec call(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def call(%{method: "POST"} = conn, action) do
    {limit, window_ms} = Map.fetch!(@limits, action)

    if hit(action, conn.remote_ip, window_ms) > limit do
      conn
      |> put_resp_header("retry-after", Integer.to_string(div(window_ms, 1000)))
      |> send_resp(429, "Too many attempts from this address. Try again later.")
      |> halt()
    else
      conn
    end
  end

  def call(conn, _action), do: conn

  @doc """
  Counts one request for `key` (e.g. a run id) against `action`'s limit.
  Returns `:ok`, or `{:error, retry_after_seconds}` once the window's limit is
  passed.
  """
  @spec check(atom(), term()) :: :ok | {:error, pos_integer()}
  def check(action, key) when is_map_key(@limits, action) do
    {limit, window_ms} = Map.fetch!(@limits, action)

    if hit(action, key, window_ms) > limit, do: {:error, div(window_ms, 1000)}, else: :ok
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Creates the counter table. Called by a long-lived owner (`SymphonyElixir.Auth`).
  """
  @spec create_table() :: :ok
  def create_table do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ok
  end

  defp hit(action, ip, window_ms) do
    if :ets.whereis(@table) == :undefined do
      # No owner process (e.g. some tests): don't limit rather than crash.
      0
    else
      window = div(System.monotonic_time(:millisecond), window_ms)
      if :rand.uniform(200) == 1, do: prune(action, window)
      :ets.update_counter(@table, {action, ip, window}, {2, 1}, {{action, ip, window}, 0})
    end
  end

  defp prune(action, current_window) do
    :ets.select_delete(@table, [{{{action, :_, :"$1"}, :_}, [{:<, :"$1", current_window}], [true]}])
  end
end
