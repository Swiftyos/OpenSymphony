defmodule SymphonyElixir.Redaction do
  @moduledoc """
  Removes credential-shaped strings from logs and transcripts.

  GitHub App installation tokens (`ghs_...`), other GitHub tokens
  (`ghp_...`, `github_pat_...`), signed JWTs, private keys, and the value of
  `Basic`/`Bearer` authorization headers (git's `http.extraHeader` carries the
  token base64-encoded) are secrets even when they are short-lived. A command
  that echoes its environment, or an HTTP error that quotes a header, must not
  put one in the log file or transcript.

  The logger filter runs for every log event, so it first looks for a few
  literal substrings every pattern needs (`:binary.match/2`) and only runs the
  single combined regex when one is present.
  """

  # Every pattern below contains one of these. Case variants cover the
  # case-insensitive `Basic`/`Bearer` pattern in the usual spellings.
  @prefilter_needles ["gh", "github_pat_", "eyJ", "-----BEGIN", "asic ", "earer ", "ASIC ", "EARER ", "asic\t", "earer\t"]

  # One regex, matched on bytes (no `u` flag), so invalid UTF-8 is scanned too.
  # Group 1 is the authorization scheme plus whitespace, kept in the output.
  @pattern ~r/(\b(?i:basic|bearer)\s+)[A-Za-z0-9+\/=._~-]{16,}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b|(?s:-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----)/

  @replacement "[REDACTED]"
  @max_depth 8
  @max_meta_depth 3

  @doc "Installs a primary logger filter so every handler sees redacted messages."
  @spec configure() :: :ok
  def configure do
    _ = :logger.remove_primary_filter(:symphony_redaction)
    :ok = :logger.add_primary_filter(:symphony_redaction, {&__MODULE__.filter/2, []})
    :ok
  end

  @doc false
  # OTP removes a primary filter that raises, which would switch redaction off
  # for the rest of the process's life, so this never raises.
  @spec filter(term(), term()) :: term()
  def filter(%{msg: message} = event, _options) do
    event
    |> Map.put(:msg, redact_message(message))
    |> redact_meta()
  rescue
    _error -> event
  catch
    _kind, _reason -> event
  end

  def filter(event, _options), do: event

  @doc "Replaces token-shaped substrings with `[REDACTED]`."
  @spec redact(term()) :: term()
  def redact(value) when is_binary(value) do
    if :binary.match(value, prefilter()) == :nomatch do
      value
    else
      Regex.replace(@pattern, value, fn _whole, scheme -> scheme <> @replacement end)
    end
  end

  def redact(value), do: value

  # A compiled :binary pattern is a reference, so it cannot be a module
  # attribute; it is compiled once and kept in :persistent_term.
  defp prefilter do
    case :persistent_term.get({__MODULE__, :prefilter}, nil) do
      nil ->
        pattern = :binary.compile_pattern(@prefilter_needles)
        :persistent_term.put({__MODULE__, :prefilter}, pattern)
        pattern

      pattern ->
        pattern
    end
  end

  # Structured reports (OTP crash and supervisor reports) keep their shape so
  # their formatting callbacks keep working; only string values change.
  defp redact_message({:report, report}), do: {:report, redact_term(report, @max_depth)}

  defp redact_message({:string, chardata} = message) do
    replace_if_redacted(message, chardata_text(chardata))
  end

  defp redact_message({format, arguments} = message) do
    text =
      try do
        format |> :io_lib.format(arguments) |> chardata_text()
      rescue
        _error -> inspect({format, arguments})
      end

    replace_if_redacted(message, text)
  end

  defp redact_message(message) when is_binary(message), do: replace_if_redacted(message, message)
  defp redact_message(message), do: message

  defp replace_if_redacted(message, text) do
    redacted = redact(text)
    if redacted == text, do: message, else: {:string, redacted}
  end

  # Chardata that is not valid Unicode (a binary with invalid UTF-8, say) is
  # still scanned byte by byte instead of being passed through unredacted.
  defp chardata_text(chardata) when is_binary(chardata), do: chardata

  defp chardata_text(chardata) do
    case :unicode.characters_to_binary(chardata) do
      binary when is_binary(binary) -> binary
      _error -> iodata_text(chardata)
    end
  end

  # Code points above 255 are not iodata either; inspect/2 still shows (and so
  # scans) every byte.
  defp iodata_text(chardata) do
    IO.iodata_to_binary(chardata)
  rescue
    _error -> inspect(chardata, limit: :infinity, printable_limit: :infinity)
  end

  defp redact_meta(%{meta: meta} = event) when is_map(meta) do
    %{event | meta: redact_term(meta, @max_meta_depth)}
  end

  defp redact_meta(event), do: event

  defp redact_term(value, _depth) when is_binary(value), do: redact(value)
  defp redact_term(value, 0), do: value

  # :maps.map, not Map.new: structs are maps but usually not Enumerable.
  defp redact_term(%{} = map, depth) do
    :maps.map(fn _key, value -> redact_term(value, depth - 1) end, map)
  end

  defp redact_term(list, depth) when is_list(list), do: redact_list(list, depth - 1)

  defp redact_term(tuple, depth) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> redact_list(depth - 1) |> List.to_tuple()
  end

  defp redact_term(value, _depth), do: value

  # Handles improper lists too.
  defp redact_list([head | tail], depth), do: [redact_term(head, depth) | redact_list(tail, depth)]
  defp redact_list([], _depth), do: []
  defp redact_list(tail, depth), do: redact_term(tail, depth)
end
