defmodule SymphonyElixir.Repo do
  @moduledoc """
  Symphony's Postgres database, used when `SYMPHONY_DATABASE_URL` is set.

  The URL and pool size are read when the repo starts (`SYMPHONY_DATABASE_URL`,
  `SYMPHONY_DATABASE_POOL_SIZE`), so the escript needs no compile-time config.
  """

  use Ecto.Repo, otp_app: :symphony_elixir, adapter: Ecto.Adapters.Postgres

  @default_pool_size 10

  @impl true
  def init(_context, config) do
    url = Keyword.get(config, :url) || database_url()
    pool_size = Keyword.get(config, :pool_size) || pool_size()

    {:ok, config |> Keyword.put(:url, url) |> Keyword.put(:pool_size, pool_size)}
  end

  @doc "The configured database URL, or nil when Symphony runs without Postgres."
  @spec database_url() :: String.t() | nil
  def database_url do
    case Application.get_env(:symphony_elixir, :database_url, :env) do
      :env -> blank_to_nil(System.get_env("SYMPHONY_DATABASE_URL"))
      url -> blank_to_nil(url)
    end
  end

  defp pool_size do
    case Integer.parse(System.get_env("SYMPHONY_DATABASE_POOL_SIZE", "")) do
      {size, ""} when size > 0 -> size
      _ -> @default_pool_size
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
