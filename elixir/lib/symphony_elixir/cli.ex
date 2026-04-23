defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with `symphony.yml` or legacy `WORKFLOW.md`.
  """

  alias SymphonyElixir.{Accounts, LogFile}

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_symphony_config_file_path: (String.t() -> :ok | {:error, term()}),
          validate_config: (-> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result()),
          accounts_login: (String.t(), String.t(), keyword() -> {:ok, map()} | {:error, term()}),
          accounts_import: (String.t(), String.t(), keyword() -> {:ok, map()} | {:error, term()}),
          accounts_list: (String.t() | nil -> {:ok, [map()]} | {:error, term()}),
          accounts_verify: (String.t(), String.t(), keyword() -> {:ok, map()} | {:error, term()}),
          accounts_pause: (String.t(), String.t(), keyword() -> {:ok, map()} | {:error, term()}),
          accounts_resume: (String.t(), String.t() -> {:ok, map()} | {:error, term()}),
          accounts_remove: (String.t(), String.t() -> :ok | {:error, term()}),
          accounts_enable: (String.t(), String.t() -> {:ok, map()} | {:error, term()}),
          accounts_disable: (String.t(), String.t() -> {:ok, map()} | {:error, term()})
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        if accounts_command?(args) do
          System.halt(0)
        else
          wait_for_shutdown()
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  defp accounts_command?(["accounts" | _args]), do: true
  defp accounts_command?(_args), do: false

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps())

  def evaluate(["accounts" | account_args], deps) do
    evaluate_accounts(account_args, deps)
  end

  def evaluate(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("symphony.yml"), deps)
        end

      {opts, [config_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(config_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(config_path, deps) do
    expanded_path = Path.expand(config_path)
    mode = startup_mode_for_path(expanded_path)

    if deps.file_regular?.(expanded_path) do
      case mode do
        :legacy ->
          :ok = deps.set_workflow_file_path.(expanded_path)

        :global ->
          :ok = deps.set_symphony_config_file_path.(expanded_path)
      end

      with :ok <- validate_config(expanded_path, deps) do
        case deps.ensure_all_started.() do
          {:ok, _started_apps} ->
            :ok

          {:error, reason} ->
            {:error, "Failed to start Symphony with config #{expanded_path}: #{inspect(reason)}"}
        end
      end
    else
      {:error, "Config file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    """
    Usage:
      symphony [--logs-root <path>] [--port <port>] [path-to-symphony.yml|path-to-WORKFLOW.md]
      symphony accounts login codex <id> [--email <email>] [path-to-symphony.yml|path-to-WORKFLOW.md]
      symphony accounts login claude <id> [--email <email>] [--token-stdin|--token-file <path>|--token-env <VAR>] [path-to-symphony.yml|path-to-WORKFLOW.md]
        Claude setup-token output is streamed live, so SSH users can open the printed auth URL elsewhere.
      symphony accounts import claude <id> [--email <email>] [--from <CLAUDE_CONFIG_DIR>] [path-to-symphony.yml|path-to-WORKFLOW.md]
      symphony accounts list [codex|claude] [path-to-symphony.yml|path-to-WORKFLOW.md]
      symphony accounts verify <codex|claude> <id> [path-to-symphony.yml|path-to-WORKFLOW.md]
      symphony accounts pause <codex|claude> <id> [--until <timestamp>] [--reason <text>] [path-to-symphony.yml|path-to-WORKFLOW.md]
      symphony accounts resume <codex|claude> <id> [path-to-symphony.yml|path-to-WORKFLOW.md]
      symphony accounts remove <codex|claude> <id> [path-to-symphony.yml|path-to-WORKFLOW.md]
    """
    |> String.trim()
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_symphony_config_file_path: &SymphonyElixir.SymphonyConfig.set_config_file_path/1,
      validate_config: &SymphonyElixir.Config.validate!/0,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end,
      accounts_login: &Accounts.login/3,
      accounts_import: &Accounts.import_account/3,
      accounts_list: &Accounts.list/1,
      accounts_verify: &Accounts.verify/3,
      accounts_pause: &Accounts.pause/3,
      accounts_resume: &Accounts.resume/2,
      accounts_remove: &Accounts.remove/2,
      accounts_enable: &Accounts.enable/2,
      accounts_disable: &Accounts.disable/2
    }
  end

  defp evaluate_accounts(["login", backend, id | rest], deps) do
    with {:ok, opts, config_path} <-
           parse_account_options(rest,
             email: :string,
             command: :string,
             token: :string,
             token_stdin: :boolean,
             token_file: :string,
             token_env: :string
           ),
         {:ok, opts} <- resolve_account_login_token_opts(opts),
         :ok <- maybe_set_account_config_path(config_path, deps),
         {:ok, account} <- account_dep(deps, :accounts_login).(backend, id, opts) do
      IO.puts("Stored #{account.backend} account #{account.id}#{email_suffix(account)}")
      :ok
    else
      {:error, %OptionParser.ParseError{} = error} -> {:error, error.message}
      {:error, reason} -> {:error, "Failed to login account: #{format_account_error(reason)}"}
    end
  end

  defp evaluate_accounts(["import", backend, id | rest], deps) do
    with {:ok, opts, config_path} <-
           parse_account_options(rest,
             email: :string,
             from: :string
           ),
         :ok <- maybe_set_account_config_path(config_path, deps),
         {:ok, account} <- account_dep(deps, :accounts_import).(backend, id, opts) do
      IO.puts("Imported #{account.backend} account #{account.id}#{email_suffix(account)}")
      :ok
    else
      {:error, %OptionParser.ParseError{} = error} -> {:error, error.message}
      {:error, reason} -> {:error, "Failed to import account: #{format_account_error(reason)}"}
    end
  end

  defp evaluate_accounts(["list" | rest], deps) do
    with {:ok, backend, config_path} <- parse_account_list_options(rest),
         :ok <- maybe_set_account_config_path(config_path, deps),
         {:ok, accounts} <- account_dep(deps, :accounts_list).(backend) do
      print_accounts(accounts)
      :ok
    else
      {:error, %OptionParser.ParseError{} = error} -> {:error, error.message}
      {:error, reason} -> {:error, "Failed to list accounts: #{format_account_error(reason)}"}
    end
  end

  defp evaluate_accounts(["verify", backend, id | rest], deps) do
    with {:ok, opts, config_path} <- parse_account_options(rest, command: :string),
         :ok <- maybe_set_account_config_path(config_path, deps),
         {:ok, result} <- account_dep(deps, :accounts_verify).(backend, id, opts) do
      account = Map.get(result, :account) || %{}
      IO.puts("Verified #{Map.get(account, :backend, backend)} account #{Map.get(account, :id, id)}#{email_suffix(account)}")

      case Map.get(result, :output) do
        output when is_binary(output) and output != "" -> IO.puts(output)
        _ -> :ok
      end

      :ok
    else
      {:error, %OptionParser.ParseError{} = error} -> {:error, error.message}
      {:error, reason} -> {:error, "Failed to verify account: #{format_account_error(reason)}"}
    end
  end

  defp evaluate_accounts(["pause", backend, id | rest], deps) do
    with {:ok, opts, config_path} <- parse_account_options(rest, until: :string, reason: :string),
         :ok <- maybe_set_account_config_path(config_path, deps),
         {:ok, account} <- account_dep(deps, :accounts_pause).(backend, id, opts) do
      IO.puts("Paused #{account.backend} account #{account.id}#{email_suffix(account)}")
      :ok
    else
      {:error, %OptionParser.ParseError{} = error} -> {:error, error.message}
      {:error, reason} -> {:error, "Failed to pause account: #{format_account_error(reason)}"}
    end
  end

  defp evaluate_accounts(["resume", backend, id | rest], deps) do
    with {:ok, _opts, config_path} <- parse_account_options(rest, []),
         :ok <- maybe_set_account_config_path(config_path, deps),
         {:ok, account} <- account_dep(deps, :accounts_resume).(backend, id) do
      IO.puts("Resumed #{account.backend} account #{account.id}#{email_suffix(account)}")
      :ok
    else
      {:error, reason} -> {:error, "Failed to resume account: #{format_account_error(reason)}"}
    end
  end

  defp evaluate_accounts(["remove", backend, id | rest], deps) do
    with {:ok, _opts, config_path} <- parse_account_options(rest, []),
         :ok <- maybe_set_account_config_path(config_path, deps) do
      case account_dep(deps, :accounts_remove).(backend, id) do
        :ok ->
          IO.puts("Removed #{backend} account #{id}")
          :ok

        {:error, reason} ->
          {:error, "Failed to remove account: #{format_account_error(reason)}"}
      end
    else
      {:error, %OptionParser.ParseError{} = error} -> {:error, error.message}
      {:error, reason} -> {:error, "Failed to remove account: #{format_account_error(reason)}"}
    end
  end

  defp evaluate_accounts(["enable", backend, id | rest], deps) do
    with {:ok, _opts, config_path} <- parse_account_options(rest, []),
         :ok <- maybe_set_account_config_path(config_path, deps),
         {:ok, account} <- account_dep(deps, :accounts_enable).(backend, id) do
      IO.puts("Enabled #{account.backend} account #{account.id}#{email_suffix(account)}")
      :ok
    else
      {:error, reason} -> {:error, "Failed to enable account: #{format_account_error(reason)}"}
    end
  end

  defp evaluate_accounts(["disable", backend, id | rest], deps) do
    with {:ok, _opts, config_path} <- parse_account_options(rest, []),
         :ok <- maybe_set_account_config_path(config_path, deps),
         {:ok, account} <- account_dep(deps, :accounts_disable).(backend, id) do
      IO.puts("Disabled #{account.backend} account #{account.id}#{email_suffix(account)}")
      :ok
    else
      {:error, reason} -> {:error, "Failed to disable account: #{format_account_error(reason)}"}
    end
  end

  defp evaluate_accounts(_args, _deps), do: {:error, usage_message()}

  defp parse_account_options(args, switches) do
    case OptionParser.parse(args, strict: Keyword.put_new(switches, :config, :string)) do
      {opts, args, []} when length(args) <= 1 ->
        with {:ok, config_path} <- account_config_path(opts, args) do
          {:ok, Keyword.delete(opts, :config), config_path}
        end

      {_opts, _args, invalid} when invalid != [] ->
        {:error, %OptionParser.ParseError{message: "Invalid account option: #{inspect(invalid)}"}}

      _ ->
        {:error, %OptionParser.ParseError{message: usage_message()}}
    end
  end

  defp parse_account_list_options(args) do
    case OptionParser.parse(args, strict: [config: :string]) do
      {opts, args, []} when length(args) <= 2 ->
        parse_account_list_args(opts, args)

      {_opts, _args, invalid} when invalid != [] ->
        {:error, %OptionParser.ParseError{message: "Invalid account option: #{inspect(invalid)}"}}

      _ ->
        {:error, %OptionParser.ParseError{message: usage_message()}}
    end
  end

  defp parse_account_list_args(opts, []) do
    with {:ok, config_path} <- account_config_path(opts, []) do
      {:ok, nil, config_path}
    end
  end

  defp parse_account_list_args(opts, [backend]) when backend in ["codex", "claude"] do
    with {:ok, config_path} <- account_config_path(opts, []) do
      {:ok, backend, config_path}
    end
  end

  defp parse_account_list_args(opts, [config_path]) do
    with {:ok, config_path} <- account_config_path(opts, [config_path]) do
      {:ok, nil, config_path}
    end
  end

  defp parse_account_list_args(opts, [backend, config_path]) when backend in ["codex", "claude"] do
    with {:ok, config_path} <- account_config_path(opts, [config_path]) do
      {:ok, backend, config_path}
    end
  end

  defp parse_account_list_args(_opts, _args), do: {:error, %OptionParser.ParseError{message: usage_message()}}

  defp resolve_account_login_token_opts(opts) do
    token_sources =
      [
        Keyword.has_key?(opts, :token),
        Keyword.get(opts, :token_stdin, false),
        Keyword.has_key?(opts, :token_file),
        Keyword.has_key?(opts, :token_env)
      ]
      |> Enum.count(& &1)

    cond do
      token_sources > 1 ->
        {:error, %OptionParser.ParseError{message: "Pass only one of --token, --token-stdin, --token-file, or --token-env"}}

      Keyword.get(opts, :token_stdin, false) ->
        {:ok, opts |> Keyword.delete(:token_stdin) |> Keyword.put(:token, stdin_token())}

      token_file = Keyword.get(opts, :token_file) ->
        case File.read(Path.expand(token_file)) do
          {:ok, token} ->
            {:ok, opts |> Keyword.delete(:token_file) |> Keyword.put(:token, String.trim(token))}

          {:error, reason} ->
            {:error, "Unable to read token file #{Path.expand(token_file)}: #{:file.format_error(reason)}"}
        end

      token_env = Keyword.get(opts, :token_env) ->
        case System.get_env(token_env) do
          token when is_binary(token) and token != "" ->
            {:ok, opts |> Keyword.delete(:token_env) |> Keyword.put(:token, String.trim(token))}

          _ ->
            {:error, "Environment variable #{token_env} is not set or is empty"}
        end

      true ->
        {:ok, opts}
    end
  end

  defp stdin_token do
    IO.read(:stdio, :eof)
    |> to_string()
    |> String.trim()
  end

  defp account_config_path(opts, args) do
    config_opt = Keyword.get(opts, :config)
    trailing_path = List.first(args)

    cond do
      is_binary(config_opt) and is_binary(trailing_path) ->
        {:error, %OptionParser.ParseError{message: "Pass account config path either as --config or trailing path, not both"}}

      is_binary(config_opt) ->
        {:ok, config_opt}

      is_binary(trailing_path) ->
        {:ok, trailing_path}

      true ->
        {:ok, nil}
    end
  end

  defp maybe_set_account_config_path(nil, _deps), do: :ok

  defp maybe_set_account_config_path(config_path, deps) when is_binary(config_path) do
    expanded_path = Path.expand(config_path)

    if deps.file_regular?.(expanded_path) do
      case startup_mode_for_path(expanded_path) do
        :legacy -> :ok = deps.set_workflow_file_path.(expanded_path)
        :global -> :ok = deps.set_symphony_config_file_path.(expanded_path)
      end
    else
      {:error, "Config file not found: #{expanded_path}"}
    end
  end

  defp account_dep(deps, key), do: Map.get(deps, key, Map.fetch!(runtime_deps(), key))

  defp print_accounts([]), do: IO.puts("No accounts configured")

  defp print_accounts(accounts) when is_list(accounts) do
    Enum.each(accounts, fn account ->
      summary = Accounts.account_summary(account) || account

      [
        account_value(summary, :backend),
        account_value(summary, :id),
        account_value(summary, :email) || "-",
        account_value(summary, :state) || "unknown",
        account_value(summary, :credential_kind) || "-",
        account_value(summary, :failure_reason) || "-"
      ]
      |> Enum.join("\t")
      |> IO.puts()
    end)
  end

  defp email_suffix(%{email: email}) when is_binary(email) and email != "", do: " (#{email})"
  defp email_suffix(%{"email" => email}) when is_binary(email) and email != "", do: " (#{email})"
  defp email_suffix(_account), do: ""

  defp account_value(account, key) when is_map(account) do
    Map.get(account, key) || Map.get(account, Atom.to_string(key))
  end

  defp format_account_error(reason), do: inspect(reason, limit: 20, printable_limit: 1_000)

  defp validate_config(expanded_path, deps) do
    case deps.validate_config.() do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Invalid Symphony config #{expanded_path}: #{SymphonyElixir.Config.format_error(reason)}"}
    end
  end

  defp startup_mode_for_path(path) when is_binary(path) do
    if String.downcase(Path.extname(path)) == ".md" do
      :legacy
    else
      :global
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Configured agent backends may run without the usual guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
