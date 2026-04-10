defmodule SymphonyElixir.SymphonyConfig do
  @moduledoc """
  Loads global runtime configuration from `symphony.yml`.
  """

  alias SymphonyElixir.SymphonyConfigStore

  @config_file_name "symphony.yml"

  @type loaded_config :: %{
          config: map(),
          path: Path.t()
        }

  @spec config_file_path() :: Path.t()
  def config_file_path do
    Application.get_env(:symphony_elixir, :symphony_config_path) ||
      Path.join(File.cwd!(), @config_file_name)
  end

  @spec set_config_file_path(Path.t()) :: :ok
  def set_config_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :symphony_config_path, path)
    Application.put_env(:symphony_elixir, :startup_mode, :global)
    maybe_reload_store()
    :ok
  end

  @spec clear_config_file_path() :: :ok
  def clear_config_file_path do
    Application.delete_env(:symphony_elixir, :symphony_config_path)
    Application.put_env(:symphony_elixir, :startup_mode, :global)
    maybe_reload_store()
    :ok
  end

  @spec current() :: {:ok, loaded_config()} | {:error, term()}
  def current do
    case Process.whereis(SymphonyConfigStore) do
      pid when is_pid(pid) ->
        SymphonyConfigStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_config()} | {:error, term()}
  def load do
    load(config_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_config()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content, path)

      {:error, reason} ->
        {:error, {:missing_symphony_config_file, path, reason}}
    end
  end

  defp parse(content, path) when is_binary(content) and is_binary(path) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok,
         %{
           config: decoded,
           path: path
         }}

      {:ok, _decoded} ->
        {:error, :symphony_config_not_a_map}

      {:error, reason} ->
        {:error, {:symphony_config_parse_error, reason}}
    end
  end

  defp maybe_reload_store do
    if Process.whereis(SymphonyConfigStore) do
      _ = SymphonyConfigStore.force_reload()
    end

    :ok
  end
end
