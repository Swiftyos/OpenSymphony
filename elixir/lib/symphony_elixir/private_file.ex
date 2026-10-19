defmodule SymphonyElixir.PrivateFile do
  @moduledoc """
  Writes Symphony's state files (accounts, session secret, factories, usage)
  so they are never readable by other local users, even briefly.

  The containing directory is created owner-only (0700) before anything is
  written, the content goes to a uniquely named temp file that is chmod 0600,
  and an atomic rename puts it in place.
  """

  @spec write(Path.t(), iodata()) :: :ok | {:error, term()}
  def write(path, content) do
    dir = Path.dirname(path)
    tmp = path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    with :ok <- ensure_private_dir(dir),
         :ok <- File.write(tmp, content),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  @doc """
  Creates `path` with `content` only if it doesn't exist yet. Returns the file's
  content either way, so two processes racing to create it agree on one value.
  """
  @spec create_once(Path.t(), binary()) :: {:ok, binary()} | {:error, term()}
  def create_once(path, content) do
    with :ok <- ensure_private_dir(Path.dirname(path)) do
      case File.open(path, [:write, :exclusive, :binary]) do
        {:ok, io} ->
          # Tighten before writing; the umask may have created it 0644.
          File.chmod(path, 0o600)
          IO.binwrite(io, content)
          File.close(io)
          {:ok, content}

        {:error, :eexist} ->
          File.read(path)

        error ->
          error
      end
    end
  end

  @spec ensure_private_dir(Path.t()) :: :ok | {:error, term()}
  def ensure_private_dir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end
end
