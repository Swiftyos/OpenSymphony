defmodule SymphonyElixir.RunEvents do
  @moduledoc """
  How event payloads travel between a runner and the controller.

  Agent events carry atoms, structs and `DateTime`s, so a payload is an Erlang
  term encoded with `term_to_binary/1` and base64ed for JSON. The controller
  decodes with the `:safe` option, which refuses to create atoms or functions
  that don't already exist in the controller.

  Runner and controller run the same release, but modules load on demand: an
  atom that only appears in runner-side code (the Codex trace log's
  `:trace_sequence`, say) doesn't exist in a controller that never loaded that
  module. So when a safe decode fails, every module of every loaded application
  (Symphony and its dependencies) is loaded once and the decode is tried again.
  An atom that none of them contains is still refused.
  """

  @modules_loaded_key {__MODULE__, :modules_loaded}

  @doc "Encodes one event payload as a JSON-safe string."
  @spec encode(term()) :: String.t()
  def encode(term), do: term |> :erlang.term_to_binary() |> Base.encode64()

  @doc "Decodes a payload produced by `encode/1`; `{:error, :invalid}` for anything else."
  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, binary} <- decode64(encoded) do
      case safe_binary_to_term(binary) do
        {:ok, term} -> {:ok, term}
        :error -> retry_with_modules_loaded(binary)
      end
    end
  end

  def decode(_encoded), do: {:error, :invalid}

  defp safe_binary_to_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp retry_with_modules_loaded(binary) do
    with true <- load_all_modules(),
         {:ok, term} <- safe_binary_to_term(binary) do
      {:ok, term}
    else
      _failed -> {:error, :invalid}
    end
  end

  # Loads every module of every loaded application the first time a decode
  # fails; true when this call loaded them, false when an earlier one had.
  defp load_all_modules do
    if :persistent_term.get(@modules_loaded_key, false) do
      false
    else
      for {app, _description, _version} <- Application.loaded_applications(),
          module <- List.wrap(Application.spec(app, :modules)),
          do: Code.ensure_loaded(module)

      :persistent_term.put(@modules_loaded_key, true)
      true
    end
  end

  defp decode64(encoded) do
    case Base.decode64(encoded) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid}
    end
  end
end
