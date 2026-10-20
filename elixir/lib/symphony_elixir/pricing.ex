defmodule SymphonyElixir.Pricing do
  @moduledoc """
  What tokens cost, so usage can be priced when it is spent.

  `pricing` in the config sets rates per harness (`codex`) or harness and model
  (`codex/gpt-5.4`), in USD per million tokens:

      pricing:
        claude: {input_per_mtok: 3, output_per_mtok: 15, cached_input_per_mtok: 0.3}
        codex: {openrouter_model: deepseek/deepseek-v4.1-flash-1017}

  `openrouter_model` takes OpenRouter's live prices for that model, including
  its cheaper cache-read rate and its time-of-day price windows. The catalog is
  fetched in the background and refreshed hourly, so pricing never waits on
  the network. Cached input is part of input (as Codex reports it) and is
  billed at the cached rate; without one it costs the same as input.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config

  @catalog_key {__MODULE__, :openrouter}
  @refresh_ms 3_600_000
  @catalog_url "https://openrouter.ai/api/v1/models"

  @type rates :: %{input: number(), cached_input: number(), output: number()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    send(self(), :refresh)
    {:ok, %{fetch: Keyword.get(opts, :fetch, &fetch_catalog/0)}}
  end

  @impl true
  def handle_info(:refresh, state) do
    if openrouter_models() != [] do
      case state.fetch.() do
        {:ok, catalog} -> put_catalog(catalog)
        {:error, reason} -> Logger.warning("OpenRouter price refresh failed: #{inspect(reason)}")
      end
    end

    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  @doc """
  The cost of a usage delta in micro-dollars (millionths of a USD), or nil when
  no price is configured for the harness.
  """
  @spec cost_micros(String.t() | nil, String.t() | nil, map(), DateTime.t(), map() | nil) :: non_neg_integer() | nil
  def cost_micros(backend, model, delta, at \\ DateTime.utc_now(), pricing \\ nil) do
    with %{} = rates <- rates(backend, model, at, pricing) do
      input = Map.get(delta, :input_tokens, 0)
      cached = min(Map.get(delta, :cached_input_tokens, 0), input)
      output = Map.get(delta, :output_tokens, 0)
      round((input - cached) * rates.input + cached * rates.cached_input + output * rates.output)
    end
  end

  @doc """
  The rates (USD per million tokens) for a harness and model at a moment, or
  nil when none are configured (or OpenRouter's prices aren't loaded yet).
  """
  @spec rates(String.t() | nil, String.t() | nil, DateTime.t(), map() | nil) :: rates() | nil
  def rates(backend, model, at \\ DateTime.utc_now(), pricing \\ nil) do
    pricing = pricing || pricing()

    case Map.get(pricing, "#{backend}/#{model}") || Map.get(pricing, to_string(backend)) do
      %{"openrouter_model" => id} -> openrouter_rates(id, at)
      %{} = static -> static_rates(static)
      _ -> nil
    end
  end

  defp static_rates(static) do
    input = number(static["input_per_mtok"], 0)
    %{input: input, cached_input: number(static["cached_input_per_mtok"], input), output: number(static["output_per_mtok"], 0)}
  end

  defp number(value, _default) when is_number(value), do: value
  defp number(_value, default), do: default

  defp pricing do
    case Config.settings() do
      {:ok, settings} -> Map.get(settings, :pricing) || %{}
      _ -> %{}
    end
  end

  defp openrouter_models do
    for {_key, %{"openrouter_model" => id}} <- pricing(), is_binary(id), do: id
  end

  # ------------------------------------------------------------------ OpenRouter

  @doc false
  @spec openrouter_rates(String.t(), DateTime.t()) :: rates() | nil
  def openrouter_rates(id, at) do
    case :persistent_term.get(@catalog_key, %{}) do
      %{^id => pricing} -> pricing |> window(at) |> per_mtok()
      _ -> nil
    end
  end

  # OpenRouter lists time-of-day prices as overrides: UTC weekdays and an HHMM
  # window [utc_start, utc_end), where an end of 0 means midnight.
  defp window(pricing, at) do
    day = at |> DateTime.to_date() |> Date.day_of_week() |> day_name()
    hhmm = at.hour * 100 + at.minute

    Enum.find(pricing["overrides"] || [], pricing, fn override ->
      day in (override["utc_days"] || []) and in_window?(hhmm, override["utc_start"] || 0, override["utc_end"] || 0)
    end)
  end

  defp in_window?(hhmm, start, 0), do: hhmm >= start
  defp in_window?(hhmm, start, finish) when finish > start, do: hhmm >= start and hhmm < finish
  defp in_window?(hhmm, start, finish), do: hhmm >= start or hhmm < finish

  defp day_name(n), do: Enum.at(~w(monday tuesday wednesday thursday friday saturday sunday), n - 1)

  # OpenRouter prices are USD per token, as strings.
  defp per_mtok(pricing) do
    input = per_token(pricing["prompt"], 0.0)
    %{input: input, cached_input: per_token(pricing["input_cache_read"], input), output: per_token(pricing["completion"], 0.0)}
  end

  defp per_token(value, default) when is_binary(value) do
    case Float.parse(value) do
      {price, _rest} -> price * 1_000_000
      :error -> default
    end
  end

  defp per_token(value, _default) when is_number(value), do: value * 1_000_000
  defp per_token(_value, default), do: default

  @doc false
  @spec fetch_catalog() :: {:ok, map()} | {:error, term()}
  def fetch_catalog do
    req_options = Application.get_env(:symphony_elixir, :pricing_req_options, [])

    case Req.get(@catalog_url, [receive_timeout: 20_000, retry: false] ++ req_options) do
      {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) ->
        {:ok, Map.new(models, &{&1["id"], &1["pricing"] || %{}})}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec put_catalog(map()) :: :ok
  def put_catalog(catalog), do: :persistent_term.put(@catalog_key, catalog)
end
