defmodule SymphonyElixir.StateTransfer do
  @moduledoc """
  Moves Symphony's state documents from one controller to another:
  `symphony state export` packs a state directory (`~/.symphony` of a file-store
  controller) into a `.tar.gz`, and `symphony state import` writes such an
  archive into the configured `StateStore` (Postgres with
  `SYMPHONY_DATABASE_URL`, or files with `--state-dir`). Both ends can stream,
  so state goes from a VM into a Kubernetes pod without a file in between:

      ssh vm 'symphony state export ~/.symphony -' |
        kubectl exec -i deploy/symphony-controller -- symphony state import -

  Only documents that mean the same on another host are moved, from an
  allowlist (never a directory walk):

    * `users.json`, `mcp_tokens.json` (SHA-256 hashes, so tokens keep working
      on any controller, plus copies encrypted with `secret_key_base`, which
      the setup page shows only where that key matches), `project_routes.json`,
      `teams.json`,
      `factories/<scope>.json`, `usage.json`, `session_history.json` and
      `inbox.json` (queued messages, keyed by issue);
    * `secret_key_base`, unless the target is configured with
      `SYMPHONY_SECRET_KEY_BASE` (or `--skip-secret-key-base` says it is set in
      the config file). It signs session cookies and encrypts the copies of
      MCP tokens the setup page shows.

  Left out on purpose: `sessions.json` (agent sessions to resume, pointing at
  this host's workspaces and agent session files), `retries.json` (this host's
  retry queue with its worker host and workspace paths; the first poll picks
  the issues up again), `runs.json`, `run_registry/` and `runs/` (runs started
  here, whose processes won't exist on the new controller, which would adopt or
  signal them), and `accounts/` (managed account logins the agent CLIs read
  from disk; not state documents).

  The archive holds `manifest.json` (keys, sizes and SHA-256s) and
  `state/<key>` per document. An import checks every document first and writes
  nothing if any is invalid, or if an existing key holds different content and
  `--overwrite` isn't given. Re-importing the same archive changes nothing.
  Summaries list keys and sizes, never contents.
  """

  alias SymphonyElixir.{PrivateFile, Repo, StateStore}

  @format "symphony-state"
  @format_version 1
  @manifest "manifest.json"
  @documents_prefix "state/"
  @secret_key "secret_key_base"
  @json_keys ~w(users.json mcp_tokens.json project_routes.json teams.json usage.json session_history.json inbox.json)
  @factory_key ~r/\Afactories\/[A-Za-z0-9][A-Za-z0-9_-]{0,127}\.json\z/
  @min_secret_bytes 64

  @left_out [
    {"sessions.json", "agent sessions to resume; they point at this host's workspaces and agent session files"},
    {"retries.json", "this host's retry queue (worker host, workspace paths); the first poll picks the issues up again"},
    {"runs.json", "runs started on this host (legacy registry); their processes won't exist on the new controller"},
    {"run_registry", "runs started on this host; their processes won't exist on the new controller"},
    {"runs", "run specs, outboxes and logs of this host's runs"},
    {"accounts", "managed account logins read by the agent CLIs; set them up again with `symphony accounts login|import`"}
  ]

  @usage """
  Usage:
    symphony state export <state-dir> <out.tar.gz|->
    symphony state import <archive.tar.gz|-> [--dry-run] [--overwrite] [--skip-secret-key-base] [--state-dir <dir>]
      Imports into Postgres when SYMPHONY_DATABASE_URL is set, otherwise into files under --state-dir.
  """

  @type document :: {String.t(), binary()}
  @type action :: :new | :unchanged | :replace | :conflict | :skip
  @type plan_entry :: %{key: String.t(), bytes: non_neg_integer(), action: action(), body: binary()}

  @doc "Runs `symphony state <args>`; `io` overrides `:stdin`, `:stdout`, `:puts`, `:error_puts` and `:getenv` (tests)."
  @spec run([String.t()], keyword()) :: :ok | {:error, String.t()}
  def run(args, io \\ [])

  def run(["export", state_dir, out], io), do: export(state_dir, out, io)

  def run(["import" | rest], io) do
    case OptionParser.parse(rest, strict: [dry_run: :boolean, overwrite: :boolean, skip_secret_key_base: :boolean, state_dir: :string]) do
      {opts, [source], []} -> import(source, opts, io)
      _ -> {:error, String.trim(@usage)}
    end
  end

  def run(_args, _io), do: {:error, String.trim(@usage)}

  @doc "Whether `key` (a path relative to the state root) is a document that is moved."
  @spec portable_key?(String.t()) :: boolean()
  def portable_key?(key) when key in @json_keys or key == @secret_key, do: true
  def portable_key?(key) when is_binary(key), do: Regex.match?(@factory_key, key)

  ## Export

  @doc "Packs the portable documents of `state_dir` into an archive; returns it with the keys it holds and what was left out."
  @spec export_archive(Path.t()) :: {:ok, binary(), [document()], [{String.t(), String.t()}]} | {:error, String.t()}
  def export_archive(state_dir) do
    dir = Path.expand(state_dir)

    with true <- File.dir?(dir) || {:error, "State directory not found: #{dir}"},
         {:ok, documents} <- collect(dir),
         :ok <- validate_all(documents),
         {:ok, archive} <- pack(documents) do
      {:ok, archive, documents, left_out(dir)}
    end
  end

  defp export(state_dir, out, io) do
    puts = if out == "-", do: error_puts(io), else: puts(io)

    with {:ok, archive, documents, left_out} <- export_archive(state_dir),
         :ok <- write_out(out, archive, io) do
      puts.("Exported #{length(documents)} document(s), #{total_bytes(documents)} bytes, from #{Path.expand(state_dir)}#{destination(out)}")
      Enum.each(documents, fn {key, body} -> puts.("  #{pad(key)} #{byte_size(body)} bytes") end)
      print_left_out(left_out, puts)
      :ok
    end
  end

  defp destination("-"), do: ""
  defp destination(out), do: " to #{Path.expand(out)}"

  defp collect(dir) do
    factory_keys =
      dir
      |> Path.join("factories/*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, dir))

    (@json_keys ++ [@secret_key] ++ Enum.sort(factory_keys))
    |> Enum.filter(&portable_key?/1)
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      case File.read(Path.join(dir, key)) do
        {:ok, body} -> {:cont, {:ok, [{key, body} | acc]}}
        {:error, :enoent} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, "Can't read #{key}: #{:file.format_error(reason)}"}}
      end
    end)
    |> case do
      {:ok, documents} -> {:ok, Enum.reverse(documents)}
      error -> error
    end
  end

  defp left_out(dir) do
    for {name, reason} <- @left_out, File.exists?(Path.join(dir, name)), do: {name, reason}
  end

  defp print_left_out([], _puts), do: :ok

  defp print_left_out(left_out, puts) do
    puts.("Left out (not valid on another controller):")
    Enum.each(left_out, fn {name, reason} -> puts.("  #{pad(name)} #{reason}") end)
  end

  defp pack(documents) do
    manifest = %{
      "format" => @format,
      "version" => @format_version,
      "exported_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "documents" => Enum.map(documents, fn {key, body} -> %{"key" => key, "bytes" => byte_size(body), "sha256" => sha256(body)} end)
    }

    entries = [{~c"#{@manifest}", Jason.encode!(manifest, pretty: true)} | Enum.map(documents, fn {key, body} -> {~c"#{@documents_prefix}#{key}", body} end)]

    with_private_tmp(fn tmp ->
      path = Path.join(tmp, "state.tar.gz")

      case :erl_tar.create(String.to_charlist(path), entries, [:compressed]) do
        :ok -> File.read(path)
        {:error, reason} -> {:error, "Can't write the archive: #{inspect(reason)}"}
      end
    end)
  end

  defp write_out("-", archive, io), do: stdout(io).(archive)

  defp write_out(out, archive, _io) do
    path = Path.expand(out)

    if File.exists?(path),
      do: {:error, "#{path} already exists; pick another path or remove it first"},
      else: archive_write(path, archive)
  end

  defp archive_write(path, archive) do
    case PrivateFile.write(path, archive) do
      :ok -> :ok
      {:error, reason} -> {:error, "Can't write #{path}: #{:file.format_error(reason)}"}
    end
  end

  ## Import

  @doc "Reads an archive made by `export_archive/1` into its documents, checking the manifest, checksums and keys."
  @spec read_archive(binary()) :: {:ok, [document()]} | {:error, String.t()}
  def read_archive(archive) when is_binary(archive) do
    with {:ok, entries} <- extract(archive),
         {:ok, manifest} <- manifest(entries),
         {:ok, documents} <- manifest_documents(manifest, Map.delete(entries, @manifest)),
         :ok <- validate_all(documents) do
      {:ok, documents}
    end
  end

  defp extract(archive) do
    case :erl_tar.extract({:binary, archive}, [:memory, :compressed]) do
      {:ok, entries} -> {:ok, Map.new(entries, fn {name, body} -> {List.to_string(name), body} end)}
      {:error, reason} -> {:error, "Not a Symphony state archive (#{inspect(reason)})"}
    end
  end

  defp manifest(%{@manifest => body}) do
    case Jason.decode(body) do
      {:ok, %{"format" => @format, "version" => @format_version, "documents" => listed} = manifest} when is_list(listed) ->
        {:ok, manifest}

      {:ok, %{"format" => @format, "version" => version}} ->
        {:error, "Unsupported state archive version #{inspect(version)}"}

      _ ->
        {:error, "Not a Symphony state archive (bad #{@manifest})"}
    end
  end

  defp manifest(_entries), do: {:error, "Not a Symphony state archive (no #{@manifest})"}

  defp manifest_documents(%{"documents" => listed}, entries) do
    result =
      Enum.reduce_while(listed, {:ok, [], entries}, fn entry, {:ok, acc, remaining} ->
        case manifest_document(entry, remaining) do
          {:ok, {key, _body} = document} -> {:cont, {:ok, [document | acc], Map.delete(remaining, @documents_prefix <> key)}}
          {:error, _message} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, documents, remaining} when map_size(remaining) == 0 -> {:ok, Enum.reverse(documents)}
      {:ok, _documents, remaining} -> {:error, "Archive holds entries its manifest doesn't list: #{remaining |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"}
      error -> error
    end
  end

  defp manifest_document(%{"key" => key, "sha256" => digest}, entries) when is_binary(key) and is_binary(digest) do
    cond do
      not portable_key?(key) -> {:error, "Archive holds #{inspect(key)}, which is not a portable state document"}
      not Map.has_key?(entries, @documents_prefix <> key) -> {:error, "Archive is missing #{key} (listed twice, or not packed)"}
      sha256(entries[@documents_prefix <> key]) != digest -> {:error, "#{key} doesn't match its checksum; the archive is damaged"}
      true -> {:ok, {key, entries[@documents_prefix <> key]}}
    end
  end

  defp manifest_document(_entry, _entries), do: {:error, "Not a Symphony state archive (bad manifest entry)"}

  defp validate_all(documents) do
    Enum.find_value(documents, :ok, fn {key, body} ->
      case validate(key, body) do
        :ok -> nil
        {:error, _message} = error -> error
      end
    end)
  end

  defp validate(@secret_key, body) do
    if byte_size(String.trim(body)) >= @min_secret_bytes, do: :ok, else: {:error, "#{@secret_key} is shorter than #{@min_secret_bytes} bytes"}
  end

  defp validate(key, body) do
    case Jason.decode(body) do
      {:ok, %{}} -> :ok
      _ -> {:error, "#{key} is not a JSON object; fix or remove it before moving state"}
    end
  end

  @doc """
  What importing `documents` into the current `StateStore` would do, per key:
  `:new`, `:unchanged` (same content already there), `:replace` (different,
  with `overwrite: true`), `:conflict` (different, without it) or `:skip`
  (the session secret when `skip_secret_key_base: true`).
  """
  @spec plan([document()], keyword()) :: {:ok, [plan_entry()]} | {:error, String.t()}
  def plan(documents, opts \\ []) do
    root = StateStore.root()

    documents
    |> Enum.reduce_while({:ok, []}, fn {key, body}, {:ok, acc} ->
      case action(key, body, root, opts) do
        {:ok, action} -> {:cont, {:ok, [%{key: key, bytes: byte_size(body), action: action, body: body} | acc]}}
        {:error, reason} -> {:halt, {:error, "Can't read #{key} from the target: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp action(key, body, root, opts) do
    if key == @secret_key and Keyword.get(opts, :skip_secret_key_base, false) do
      {:ok, :skip}
    else
      compare(StateStore.read(Path.join(root, key)), body, Keyword.get(opts, :overwrite, false))
    end
  end

  defp compare({:error, :enoent}, _body, _overwrite?), do: {:ok, :new}
  defp compare({:ok, body}, body, _overwrite?), do: {:ok, :unchanged}
  defp compare({:ok, _other}, _body, true), do: {:ok, :replace}
  defp compare({:ok, _other}, _body, false), do: {:ok, :conflict}
  defp compare({:error, reason}, _body, _overwrite?), do: {:error, reason}

  @doc "Writes the `:new` and `:replace` entries of a plan; stops at the first failure."
  @spec apply_plan([plan_entry()]) :: :ok | {:error, String.t()}
  def apply_plan(entries) do
    root = StateStore.root()

    Enum.find_value(entries, :ok, fn
      %{action: action, key: key, body: body} when action in [:new, :replace] ->
        case StateStore.write(Path.join(root, key), body) do
          :ok -> nil
          {:error, reason} -> {:error, "Writing #{key} failed: #{inspect(reason)}; documents before it were written, rerun with --overwrite"}
        end

      _entry ->
        nil
    end)
  end

  @doc """
  Points `StateStore` at the import target: Postgres (repo and migrations
  only, no orchestrator) when `SYMPHONY_DATABASE_URL` is set, or files under
  `state_dir`. Returns a description of the target without credentials.
  """
  @spec prepare_target(Path.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def prepare_target(state_dir) do
    case {Repo.database_url(), state_dir} do
      {nil, nil} ->
        {:error, "Nothing to import into: set SYMPHONY_DATABASE_URL to import into Postgres, or pass --state-dir <dir> to import into files"}

      {nil, dir} ->
        Application.put_env(:symphony_elixir, :state_store, StateStore.File)
        Application.put_env(:symphony_elixir, :state_root, Path.expand(dir))
        {:ok, "files in #{Path.expand(dir)}"}

      {_url, dir} when is_binary(dir) ->
        {:error, "--state-dir imports into files; unset SYMPHONY_DATABASE_URL to use it"}

      {url, nil} ->
        start_postgres(url)
    end
  end

  defp start_postgres(url) do
    with {:ok, _apps} <- Application.ensure_all_started(:ecto_sql),
         {:ok, _apps} <- Application.ensure_all_started(:postgrex),
         {:ok, _pid} <- start_state_store() do
      {:ok, "Postgres #{redact(url)}"}
    else
      {:error, reason} -> {:error, "Can't start the Postgres state store (#{redact(url)}): #{inspect(reason, limit: 10)}"}
    end
  end

  # Unlinked, so a failed migration or connection comes back as an error
  # instead of taking the CLI process down.
  defp start_state_store do
    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        start_and_unlink()
      end)

    case Task.await(task, :infinity) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_and_unlink do
    case StateStore.Supervisor.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}

      other ->
        other
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp redact(url) do
    uri = URI.parse(url)
    "#{uri.host || "localhost"}#{if uri.port, do: ":#{uri.port}"}#{uri.path}"
  end

  defp import(source, opts, io) do
    puts = puts(io)
    secret_configured? = configured_secret?(Keyword.get(io, :getenv, &System.get_env/1))
    plan_opts = [overwrite: Keyword.get(opts, :overwrite, false), skip_secret_key_base: Keyword.get(opts, :skip_secret_key_base, false) or secret_configured?]

    with {:ok, archive} <- read_source(source, io),
         {:ok, documents} <- read_archive(archive),
         {:ok, target} <- prepare_target(Keyword.get(opts, :state_dir)),
         {:ok, entries} <- plan(documents, plan_opts) do
      dry_run? = Keyword.get(opts, :dry_run, false)
      puts.("#{if dry_run?, do: "Dry run: would import", else: "Importing"} #{length(entries)} document(s) into #{target}")
      Enum.each(entries, &puts.(plan_line(&1, secret_configured?)))
      finish(entries, dry_run?, puts)
    end
  end

  defp finish(entries, dry_run?, puts) do
    conflicts = for %{action: :conflict, key: key} <- entries, do: key
    counts = entries |> Enum.frequencies_by(& &1.action) |> Enum.sort() |> Enum.map_join(", ", fn {action, n} -> "#{n} #{action}" end)

    cond do
      conflicts != [] and not dry_run? ->
        {:error, "#{length(conflicts)} existing document(s) differ: #{Enum.join(conflicts, ", ")}. Nothing was written; rerun with --overwrite to replace them."}

      dry_run? ->
        puts.("Nothing written (#{counts})#{if conflicts != [], do: "; --overwrite is needed for the conflicts", else: ""}")
        :ok

      Enum.any?(entries, &(&1.action in [:new, :replace])) ->
        with :ok <- apply_plan(entries) do
          puts.("Done (#{counts}). Restart the controller so every store loads the imported state.")
          :ok
        end

      true ->
        puts.("Already up to date (#{counts})")
        :ok
    end
  end

  defp plan_line(%{action: :skip, key: key, bytes: bytes}, true), do: "  skip      #{pad(key)} #{bytes} bytes (SYMPHONY_SECRET_KEY_BASE is set)"
  defp plan_line(%{action: :skip, key: key, bytes: bytes}, false), do: "  skip      #{pad(key)} #{bytes} bytes (--skip-secret-key-base)"
  defp plan_line(%{action: :conflict, key: key, bytes: bytes}, _secret), do: "  conflict  #{pad(key)} #{bytes} bytes (exists with different content)"
  defp plan_line(%{action: action, key: key, bytes: bytes}, _secret), do: "  #{String.pad_trailing(to_string(action), 9)} #{pad(key)} #{bytes} bytes"

  defp configured_secret?(getenv) do
    case getenv.("SYMPHONY_SECRET_KEY_BASE") do
      secret when is_binary(secret) -> byte_size(secret) >= @min_secret_bytes
      nil -> false
    end
  end

  defp read_source("-", io) do
    case stdin(io).() do
      data when is_binary(data) and data != "" -> {:ok, data}
      _ -> {:error, "No archive on stdin"}
    end
  end

  defp read_source(path, _io) do
    case File.read(Path.expand(path)) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "Can't read #{Path.expand(path)}: #{:file.format_error(reason)}"}
    end
  end

  ## Helpers

  defp puts(io), do: Keyword.get(io, :puts, &IO.puts/1)
  defp error_puts(io), do: Keyword.get(io, :error_puts, &IO.puts(:stderr, &1))
  defp stdin(io), do: Keyword.get(io, :stdin, fn -> binary_stdio(fn -> IO.binread(:stdio, :eof) end) end)

  defp stdout(io) do
    Keyword.get(io, :stdout, fn data ->
      binary_stdio(fn -> IO.binwrite(:stdio, data) end)
    end)
  end

  # The escript's stdio is unicode, which would re-encode archive bytes; the
  # archive goes through it as raw bytes.
  defp binary_stdio(fun) do
    previous = Keyword.get(:io.getopts(:standard_io), :encoding, :latin1)
    :ok = :io.setopts(:standard_io, encoding: :latin1)

    try do
      fun.()
    after
      :io.setopts(:standard_io, encoding: previous)
    end
  end

  defp with_private_tmp(fun) do
    tmp = Path.join(System.tmp_dir!(), "symphony-state-#{System.unique_integer([:positive])}")

    try do
      with :ok <- PrivateFile.ensure_private_dir(tmp), do: fun.(tmp)
    after
      File.rm_rf(tmp)
    end
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  defp total_bytes(documents), do: documents |> Enum.map(fn {_key, body} -> byte_size(body) end) |> Enum.sum()
  defp pad(key), do: String.pad_trailing(key, 34)
end
