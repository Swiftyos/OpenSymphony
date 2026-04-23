defmodule SymphonyElixir.Accounts do
  @moduledoc """
  Stores and selects provider accounts for usage-aware backend rotation.
  """

  require Logger

  alias SymphonyElixir.Config

  @backends ["codex", "claude"]
  @states ["healthy", "unknown", "limited", "exhausted", "paused", "disabled"]
  @metadata_file "metadata.json"
  @state_file "state.json"
  @rotation_file "rotation.json"
  @usage_periods_file "usage_periods.csv"
  @secret_mode 0o600
  @dir_mode 0o700
  @usage_period_csv_header [
    "logged_at",
    "backend",
    "account_id",
    "account_email",
    "limit_id",
    "bucket",
    "period",
    "period_started_at",
    "reset_at",
    "next_reset_at",
    "limit",
    "remaining",
    "used",
    "usage_percent",
    "weekly_usage_percent",
    "input_tokens",
    "output_tokens",
    "total_tokens"
  ]

  @type account :: map()
  @type selection_error :: %{
          reason: String.t(),
          backend: String.t(),
          skipped: [map()],
          next_available_at: String.t() | nil
        }

  @spec enabled?() :: boolean()
  def enabled?, do: Config.accounts_enabled?()

  @spec store_root() :: Path.t()
  def store_root, do: store_root(current_settings())

  @spec store_root(term()) :: Path.t()
  def store_root(settings) do
    settings
    |> accounts_settings()
    |> Map.fetch!(:store_root)
  end

  @spec list(String.t() | nil, term() | nil) :: {:ok, [account()]} | {:error, term()}
  def list(backend \\ nil, settings \\ nil) do
    settings = settings || current_settings()

    backends =
      case normalize_backend(backend) do
        nil -> @backends
        normalized -> [normalized]
      end

    accounts =
      backends
      |> Enum.flat_map(fn backend_name ->
        backend_name
        |> backend_dir(settings)
        |> account_dirs()
        |> Enum.flat_map(&load_account_from_dir(backend_name, &1, settings))
      end)
      |> Enum.sort_by(&{&1.backend, &1.id})

    {:ok, accounts}
  end

  @spec get(String.t(), String.t(), term() | nil) :: {:ok, account()} | {:error, :not_found | term()}
  def get(backend, id, settings \\ nil) when is_binary(id) do
    settings = settings || current_settings()
    backend = normalize_backend!(backend)
    dir = account_dir(backend, id, settings)

    case load_account_from_dir(backend, dir, settings) do
      [account] -> {:ok, account}
      [] -> {:error, :not_found}
    end
  rescue
    error -> {:error, error}
  end

  @spec create_or_update(String.t(), String.t(), keyword(), term() | nil) :: {:ok, account()} | {:error, term()}
  def create_or_update(backend, id, attrs \\ [], settings \\ nil) when is_binary(id) and is_list(attrs) do
    settings = settings || current_settings()
    backend = normalize_backend!(backend)
    id = normalize_id!(id)
    dir = account_dir(backend, id, settings)

    with :ok <- ensure_account_dirs(dir, backend),
         {:ok, existing} <- read_json(metadata_path(dir), %{}),
         metadata <- merge_metadata(existing, backend, id, attrs),
         :ok <- write_json(metadata_path(dir), metadata, @secret_mode),
         {:ok, state} <- read_json(state_path(dir), default_state()),
         :ok <- write_json(state_path(dir), Map.merge(default_state(), state), @secret_mode) do
      get(backend, id, settings)
    end
  rescue
    error -> {:error, error}
  end

  @spec login(String.t(), String.t(), keyword(), term() | nil) :: {:ok, account()} | {:error, term()}
  def login(backend, id, opts \\ [], settings \\ nil) do
    settings = settings || current_settings()
    backend = normalize_backend!(backend)

    with {:ok, account} <- create_or_update(backend, id, opts, settings) do
      case backend do
        "codex" -> login_codex(account, opts, settings)
        "claude" -> login_claude(account, opts, settings)
      end
    end
  rescue
    error -> {:error, error}
  end

  @spec verify(String.t(), String.t(), keyword(), term() | nil) :: {:ok, map()} | {:error, term()}
  def verify(backend, id, opts \\ [], settings \\ nil) do
    settings = settings || current_settings()

    with {:ok, account} <- get(backend, id, settings) do
      command = Keyword.get(opts, :command) || default_provider_command(account.backend)

      case account.backend do
        "codex" ->
          run_provider(command, ["login", "status"], credential_env(account), opts)

        "claude" ->
          run_provider(command, ["auth", "status", "--json"], credential_env(account), opts)
      end
      |> case do
        {:ok, output} -> {:ok, %{account: account_summary(account), output: String.trim(output)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec pause(String.t(), String.t(), keyword(), term() | nil) :: {:ok, account()} | {:error, term()}
  def pause(backend, id, opts \\ [], settings \\ nil) do
    settings = settings || current_settings()

    with {:ok, account} <- get(backend, id, settings),
         {:ok, metadata} <- read_json(metadata_path(account.account_dir), %{}),
         {:ok, state} <- read_json(state_path(account.account_dir), default_state()) do
      paused_until = Keyword.get(opts, :until)
      reason = Keyword.get(opts, :reason) || "manually paused"

      metadata =
        metadata
        |> Map.put("paused_until", normalize_datetime_string(paused_until))
        |> Map.put("paused_reason", reason)
        |> Map.put("updated_at", now_iso())

      state =
        state
        |> Map.merge(%{
          "state" => "paused",
          "failure_reason" => reason,
          "updated_at" => now_iso()
        })

      with :ok <- write_json(metadata_path(account.account_dir), metadata, @secret_mode),
           :ok <- write_json(state_path(account.account_dir), state, @secret_mode) do
        get(backend, id, settings)
      end
    end
  end

  @spec resume(String.t(), String.t(), term() | nil) :: {:ok, account()} | {:error, term()}
  def resume(backend, id, settings \\ nil) do
    settings = settings || current_settings()

    with {:ok, account} <- get(backend, id, settings),
         {:ok, metadata} <- read_json(metadata_path(account.account_dir), %{}),
         {:ok, state} <- read_json(state_path(account.account_dir), default_state()) do
      metadata =
        metadata
        |> Map.delete("paused_until")
        |> Map.delete("paused_reason")
        |> Map.put("enabled", true)
        |> Map.put("updated_at", now_iso())

      state =
        state
        |> Map.merge(%{
          "state" => "unknown",
          "failure_reason" => nil,
          "exhausted_until" => nil,
          "updated_at" => now_iso()
        })

      with :ok <- write_json(metadata_path(account.account_dir), metadata, @secret_mode),
           :ok <- write_json(state_path(account.account_dir), state, @secret_mode) do
        get(backend, id, settings)
      end
    end
  end

  @spec disable(String.t(), String.t(), term() | nil) :: {:ok, account()} | {:error, term()}
  def disable(backend, id, settings \\ nil), do: set_enabled(backend, id, false, settings)

  @spec enable(String.t(), String.t(), term() | nil) :: {:ok, account()} | {:error, term()}
  def enable(backend, id, settings \\ nil), do: set_enabled(backend, id, true, settings)

  @spec remove(String.t(), String.t(), term() | nil) :: :ok | {:error, term()}
  def remove(backend, id, settings \\ nil) do
    settings = settings || current_settings()
    backend = normalize_backend!(backend)
    dir = account_dir(backend, id, settings)
    File.rm_rf(dir)
  rescue
    error -> {:error, error}
  end

  @spec select_for_dispatch(String.t(), String.t() | nil, map(), term() | nil) ::
          {:ok, account() | nil} | {:error, selection_error()}
  def select_for_dispatch(backend, worker_host, running, settings \\ nil)
      when is_map(running) do
    settings = settings || current_settings()
    accounts_settings = accounts_settings(settings)
    backend = normalize_backend!(backend)

    if accounts_settings.enabled do
      with {:ok, accounts} <- list(backend, settings) do
        accounts = Enum.filter(accounts, &account_matches_host?(&1, worker_host))

        cond do
          accounts == [] and accounts_settings.allow_host_auth_fallback ->
            {:ok, nil}

          accounts == [] ->
            {:error, unavailable_error(backend, [], "no configured #{backend} accounts")}

          true ->
            select_usable_account(backend, accounts, running, accounts_settings, settings)
        end
      end
    else
      {:ok, nil}
    end
  end

  @spec credential_env(account() | nil) :: [{String.t(), String.t()}]
  def credential_env(nil), do: []

  def credential_env(%{backend: "codex", codex_home: codex_home}) when is_binary(codex_home) do
    [{"CODEX_HOME", codex_home}]
  end

  def credential_env(%{backend: "claude"} = account) do
    account
    |> claude_credential_env()
    |> Enum.reject(fn
      {"ANTHROPIC_API_KEY", ""} -> false
      {_key, value} -> is_nil(value) or value == ""
    end)
  end

  def credential_env(_account), do: []

  @spec account_summary(account() | nil) :: map() | nil
  def account_summary(nil), do: nil

  def account_summary(account) when is_map(account) do
    %{
      backend: Map.get(account, :backend),
      id: Map.get(account, :id),
      email: Map.get(account, :email),
      state: Map.get(account, :state),
      credential_kind: Map.get(account, :credential_kind),
      worker_host: Map.get(account, :worker_host),
      exhausted_until: Map.get(account, :exhausted_until),
      paused_until: Map.get(account, :paused_until),
      failure_reason: Map.get(account, :failure_reason),
      latest_rate_limits: Map.get(account, :latest_rate_limits),
      latest_reset_at: latest_reset_at(account),
      token_totals: Map.get(account, :token_totals),
      usage_periods_csv: usage_periods_csv_path(account)
    }
  end

  @spec record_rate_limits(account() | nil, map() | nil, term() | nil) :: :ok
  def record_rate_limits(account, rate_limits, settings \\ nil)
  def record_rate_limits(nil, _rate_limits, _settings), do: :ok
  def record_rate_limits(_account, nil, _settings), do: :ok

  def record_rate_limits(account, rate_limits, settings) when is_map(account) and is_map(rate_limits) do
    settings = settings || current_settings()
    accounts_settings = accounts_settings(settings)

    with {:ok, state} <- read_json(state_path(account.account_dir), default_state()) do
      exhausted_until = exhausted_until_from_rate_limits(rate_limits, accounts_settings)
      {state, usage_period_rows} = rotate_rate_limit_periods(state, rate_limits, account)

      next_state =
        cond do
          is_binary(exhausted_until) ->
            "exhausted"

          limited_rate_limits?(rate_limits) ->
            "limited"

          true ->
            "healthy"
        end

      state =
        state
        |> Map.merge(%{
          "state" => next_state,
          "latest_rate_limits" => rate_limits,
          "exhausted_until" => exhausted_until,
          "failure_reason" => if(next_state == "exhausted", do: "rate limits exhausted", else: nil),
          "updated_at" => now_iso()
        })

      append_usage_period_rows(account, usage_period_rows)
      :ok = write_json(state_path(account.account_dir), state, @secret_mode)
    end

    :ok
  end

  @spec record_usage(account() | nil, map() | nil, DateTime.t() | nil, term() | nil) :: :ok
  def record_usage(account, token_delta, timestamp \\ nil, settings \\ nil)
  def record_usage(nil, _token_delta, _timestamp, _settings), do: :ok
  def record_usage(_account, nil, _timestamp, _settings), do: :ok

  def record_usage(account, token_delta, timestamp, _settings)
      when is_map(account) and is_map(token_delta) do
    timestamp = timestamp || DateTime.utc_now()

    delta =
      [:input_tokens, :output_tokens, :total_tokens]
      |> Enum.reduce(%{}, fn key, acc ->
        Map.put(acc, Atom.to_string(key), max(0, Map.get(token_delta, key, 0)))
      end)

    with {:ok, state} <- read_json(state_path(account.account_dir), default_state()) do
      usage = update_usage_totals(Map.get(state, "token_totals", %{}), delta, timestamp)
      rate_limit_periods = update_rate_limit_period_token_totals(Map.get(state, "rate_limit_periods", %{}), delta)

      state =
        state
        |> Map.put("token_totals", usage)
        |> Map.put("rate_limit_periods", rate_limit_periods)
        |> Map.put("updated_at", now_iso())

      :ok = write_json(state_path(account.account_dir), state, @secret_mode)
    end

    :ok
  end

  @spec mark_exhausted(account() | nil, term(), term() | nil) :: :ok
  def mark_exhausted(account, reason, settings \\ nil)
  def mark_exhausted(nil, _reason, _settings), do: :ok

  def mark_exhausted(account, reason, settings) when is_map(account) do
    settings = settings || current_settings()
    accounts_settings = accounts_settings(settings)
    until_iso = DateTime.utc_now() |> DateTime.add(accounts_settings.exhausted_cooldown_ms, :millisecond) |> DateTime.to_iso8601()

    with {:ok, state} <- read_json(state_path(account.account_dir), default_state()) do
      state =
        state
        |> Map.merge(%{
          "state" => "exhausted",
          "exhausted_until" => until_iso,
          "failure_reason" => quota_reason(reason),
          "updated_at" => now_iso()
        })

      :ok = write_json(state_path(account.account_dir), state, @secret_mode)
    end

    :ok
  end

  @spec mark_success(account() | nil, term() | nil) :: :ok
  def mark_success(account, settings \\ nil)
  def mark_success(nil, _settings), do: :ok

  def mark_success(account, _settings) when is_map(account) do
    with {:ok, state} <- read_json(state_path(account.account_dir), default_state()) do
      state =
        state
        |> Map.put("last_success_at", now_iso())
        |> Map.update("state", "healthy", fn
          state when state in ["unknown", "limited"] -> "healthy"
          state -> state
        end)
        |> Map.put("updated_at", now_iso())

      :ok = write_json(state_path(account.account_dir), state, @secret_mode)
    end

    :ok
  end

  @spec quota_error?(term()) :: boolean()
  def quota_error?(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1_000)
    |> String.downcase()
    |> String.contains?(["rate limit", "rate_limit", "quota", "credit", "429", "exhausted", "maxed"])
  end

  @spec normalize_backend(String.t() | nil) :: String.t() | nil
  def normalize_backend(nil), do: nil

  def normalize_backend(backend) when is_binary(backend) do
    case backend |> String.trim() |> String.downcase() do
      backend when backend in @backends -> backend
      _ -> nil
    end
  end

  def normalize_backend(_backend), do: nil

  @spec normalize_backend!(String.t()) :: String.t()
  def normalize_backend!(backend) do
    case normalize_backend(backend) do
      nil -> raise ArgumentError, "account backend must be one of: #{Enum.join(@backends, ", ")}"
      normalized -> normalized
    end
  end

  @spec backend_dir(String.t(), term()) :: Path.t()
  def backend_dir(backend, settings), do: Path.join(store_root(settings), normalize_backend!(backend))

  @spec account_dir(String.t(), String.t(), term()) :: Path.t()
  def account_dir(backend, id, settings), do: Path.join(backend_dir(backend, settings), safe_segment(normalize_id!(id)))

  defp select_usable_account(backend, accounts, running, accounts_settings, settings) do
    running_counts = running_account_counts(running, backend)

    evaluated =
      Enum.map(accounts, fn account ->
        {account, account_unavailable_reason(account, running_counts, accounts_settings)}
      end)

    usable =
      evaluated
      |> Enum.filter(fn {_account, reason} -> is_nil(reason) end)
      |> Enum.map(&elem(&1, 0))

    if usable == [] do
      skipped =
        Enum.map(evaluated, fn {account, reason} ->
          %{
            account_id: account.id,
            email: account.email,
            reason: reason || "unavailable"
          }
        end)

      {:error, unavailable_error(backend, skipped, "no usable #{backend} accounts")}
    else
      account = choose_round_robin(backend, usable, settings)
      {:ok, account}
    end
  end

  defp account_unavailable_reason(account, running_counts, accounts_settings) do
    cond do
      account.enabled == false ->
        "disabled"

      account.state == "disabled" ->
        "disabled"

      paused?(account) ->
        paused_reason(account)

      cooldown_active?(account.exhausted_until) ->
        "cooling down until #{account.exhausted_until}"

      Map.get(running_counts, account.id, 0) >= accounts_settings.max_concurrent_sessions_per_account ->
        "account concurrency limit reached"

      budget_exhausted?(account, accounts_settings, :daily) ->
        "daily token budget exhausted"

      budget_exhausted?(account, accounts_settings, :monthly) ->
        "monthly token budget exhausted"

      true ->
        nil
    end
  end

  defp paused?(%{state: "paused", paused_until: nil}), do: true
  defp paused?(%{paused_until: paused_until}) when is_binary(paused_until), do: future_iso?(paused_until)
  defp paused?(_account), do: false

  defp paused_reason(account) do
    account.paused_reason ||
      if(account.paused_until, do: "paused until #{account.paused_until}", else: "paused")
  end

  defp cooldown_active?(nil), do: false
  defp cooldown_active?(until_iso) when is_binary(until_iso), do: future_iso?(until_iso)

  defp future_iso?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> DateTime.compare(timestamp, DateTime.utc_now()) == :gt
      _ -> false
    end
  end

  defp budget_exhausted?(account, accounts_settings, :daily) do
    budget = account.daily_token_budget || accounts_settings.daily_token_budget
    usage_total = token_total_for_period(account.token_totals, "daily", Date.utc_today() |> Date.to_iso8601())
    is_integer(budget) and budget > 0 and usage_total >= budget
  end

  defp budget_exhausted?(account, accounts_settings, :monthly) do
    budget = account.monthly_token_budget || accounts_settings.monthly_token_budget
    month = Date.utc_today() |> Calendar.strftime("%Y-%m")
    usage_total = token_total_for_period(account.token_totals, "monthly", month)
    is_integer(budget) and budget > 0 and usage_total >= budget
  end

  defp token_total_for_period(token_totals, period_key, current_period) when is_map(token_totals) do
    period = Map.get(token_totals, period_key, %{})

    if Map.get(period, "period") == current_period do
      integer_value(Map.get(period, "total_tokens"))
    else
      0
    end
  end

  defp token_total_for_period(_token_totals, _period_key, _current_period), do: 0

  defp choose_round_robin(backend, accounts, settings) do
    sorted_accounts = Enum.sort_by(accounts, & &1.id)
    rotation_path = Path.join(backend_dir(backend, settings), @rotation_file)
    {:ok, rotation} = read_json(rotation_path, %{})
    last_id = Map.get(rotation, "last_account_id")

    index =
      case Enum.find_index(sorted_accounts, &(&1.id == last_id)) do
        nil -> 0
        idx -> rem(idx + 1, length(sorted_accounts))
      end

    account = Enum.at(sorted_accounts, index)

    rotation =
      rotation
      |> Map.put("last_account_id", account.id)
      |> Map.put("updated_at", now_iso())

    :ok = write_json(rotation_path, rotation, @secret_mode)
    account
  end

  defp running_account_counts(running, backend) when is_map(running) do
    Enum.reduce(running, %{}, fn
      {_issue_id, %{backend: ^backend, account_id: account_id}}, acc when is_binary(account_id) ->
        Map.update(acc, account_id, 1, &(&1 + 1))

      _entry, acc ->
        acc
    end)
  end

  defp unavailable_error(backend, skipped, reason) do
    %{
      reason: reason,
      backend: backend,
      skipped: skipped,
      next_available_at: next_available_at(skipped)
    }
  end

  defp next_available_at(skipped) when is_list(skipped) do
    skipped
    |> Enum.flat_map(fn
      %{reason: reason} when is_binary(reason) ->
        Regex.scan(~r/\d{4}-\d{2}-\d{2}T[^ ]+Z?/, reason)
        |> List.flatten()

      _ ->
        []
    end)
    |> Enum.sort()
    |> List.first()
  end

  defp account_dirs(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(path, &1))
        |> Enum.filter(&File.dir?/1)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, action: "list account directory", path: path, reason: reason
    end
  end

  defp load_account_from_dir(backend, dir, settings) do
    with true <- File.regular?(metadata_path(dir)),
         {:ok, metadata} <- read_json(metadata_path(dir), %{}),
         {:ok, state} <- read_json(state_path(dir), default_state()) do
      [normalize_account(backend, dir, metadata, state, accounts_settings(settings))]
    else
      _ -> []
    end
  end

  defp normalize_account(backend, dir, metadata, state, settings) do
    id = Map.get(metadata, "id") || Path.basename(dir)
    state_name = normalize_state(Map.get(state, "state"))

    %{
      backend: backend,
      id: id,
      email: normalize_optional_string(Map.get(metadata, "email")),
      enabled: Map.get(metadata, "enabled", true),
      credential_kind: Map.get(metadata, "credential_kind") || default_credential_kind(backend),
      worker_host: normalize_optional_string(Map.get(metadata, "worker_host")),
      state: effective_state(state_name, metadata),
      account_dir: dir,
      codex_home: Path.join(dir, "codex_home"),
      claude_config_dir: Path.join(dir, "claude_config"),
      claude_oauth_token_file: Path.join(dir, "claude_oauth_token"),
      paused_until: normalize_optional_string(Map.get(metadata, "paused_until")),
      paused_reason: normalize_optional_string(Map.get(metadata, "paused_reason")),
      exhausted_until: normalize_optional_string(Map.get(state, "exhausted_until")),
      failure_reason: normalize_optional_string(Map.get(state, "failure_reason")),
      latest_rate_limits: Map.get(state, "latest_rate_limits"),
      last_success_at: normalize_optional_string(Map.get(state, "last_success_at")),
      token_totals: Map.get(state, "token_totals", default_token_totals()),
      rate_limit_periods: Map.get(state, "rate_limit_periods", %{}),
      daily_token_budget: positive_integer_value(Map.get(metadata, "daily_token_budget")) || settings.daily_token_budget,
      monthly_token_budget: positive_integer_value(Map.get(metadata, "monthly_token_budget")) || settings.monthly_token_budget
    }
  end

  defp effective_state(_state, %{"enabled" => false}), do: "disabled"

  defp effective_state(_state, %{"paused_until" => paused_until}) when is_binary(paused_until) do
    if future_iso?(paused_until), do: "paused", else: "unknown"
  end

  defp effective_state(state, _metadata), do: state

  defp normalize_state(state) when state in @states, do: state
  defp normalize_state(_state), do: "unknown"

  defp merge_metadata(existing, backend, id, attrs) do
    now = now_iso()

    existing
    |> Map.merge(%{
      "backend" => backend,
      "id" => id,
      "enabled" => Keyword.get(attrs, :enabled, Map.get(existing, "enabled", true)),
      "credential_kind" => Keyword.get(attrs, :credential_kind, Map.get(existing, "credential_kind", default_credential_kind(backend))),
      "email" => Keyword.get(attrs, :email, Map.get(existing, "email")),
      "worker_host" => Keyword.get(attrs, :worker_host, Map.get(existing, "worker_host")),
      "daily_token_budget" => Keyword.get(attrs, :daily_token_budget, Map.get(existing, "daily_token_budget")),
      "monthly_token_budget" => Keyword.get(attrs, :monthly_token_budget, Map.get(existing, "monthly_token_budget")),
      "created_at" => Map.get(existing, "created_at", now),
      "updated_at" => now
    })
    |> drop_nil_values()
  end

  defp set_enabled(backend, id, enabled, settings) do
    settings = settings || current_settings()

    with {:ok, account} <- get(backend, id, settings),
         {:ok, metadata} <- read_json(metadata_path(account.account_dir), %{}),
         {:ok, state} <- read_json(state_path(account.account_dir), default_state()) do
      metadata =
        metadata
        |> Map.put("enabled", enabled)
        |> Map.put("updated_at", now_iso())

      state =
        state
        |> Map.put("state", if(enabled, do: "unknown", else: "disabled"))
        |> Map.put("updated_at", now_iso())

      with :ok <- write_json(metadata_path(account.account_dir), metadata, @secret_mode),
           :ok <- write_json(state_path(account.account_dir), state, @secret_mode) do
        get(backend, id, settings)
      end
    end
  end

  defp ensure_account_dirs(dir, "codex") do
    with :ok <- mkdir_private(dir),
         :ok <- mkdir_private(Path.join(dir, "codex_home")) do
      :ok
    end
  end

  defp ensure_account_dirs(dir, "claude") do
    with :ok <- mkdir_private(dir),
         :ok <- mkdir_private(Path.join(dir, "claude_config")) do
      :ok
    end
  end

  defp mkdir_private(path) do
    with :ok <- File.mkdir_p(path) do
      File.chmod(path, @dir_mode)
    end
  end

  defp login_codex(account, opts, settings) do
    command = Keyword.get(opts, :command) || "codex"

    case run_provider(command, ["login", "--device-auth"], credential_env(account), Keyword.put(opts, :stream, true)) do
      {:ok, output} ->
        email = Keyword.get(opts, :email) || extract_email(output) || account.email
        create_or_update(account.backend, account.id, [email: email, credential_kind: "codex_home"], settings)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp login_claude(account, opts, settings) do
    token = Keyword.get(opts, :token)
    command = Keyword.get(opts, :command) || "claude"

    token_result =
      cond do
        is_binary(token) and String.trim(token) != "" ->
          {:ok, token}

        true ->
          command
          |> run_provider(["setup-token"], claude_login_env(), opts |> Keyword.put(:stream, true) |> Keyword.put(:pty, true))
          |> case do
            {:ok, output} -> extract_claude_oauth_token(output)
            {:error, reason} -> {:error, reason}
          end
      end

    case token_result do
      {:ok, oauth_token} ->
        token_file = account.claude_oauth_token_file
        :ok = File.write(token_file, String.trim(oauth_token) <> "\n")
        :ok = File.chmod(token_file, @secret_mode)
        email = Keyword.get(opts, :email) || account.email
        create_or_update(account.backend, account.id, [email: email, credential_kind: "claude_oauth_token"], settings)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_provider(command, args, env, opts) do
    command_parts = shell_words(command)

    case command_parts do
      [] ->
        {:error, :missing_provider_command}

      [executable | command_args] ->
        env = Enum.map(env, fn {key, value} -> {key, to_string(value)} end)

        if Keyword.get(opts, :stream, false) do
          run_provider_stream(executable, command_args ++ args, env, opts)
        else
          case System.cmd(executable, command_args ++ args,
                 env: env,
                 stderr_to_stdout: true,
                 into: Keyword.get(opts, :into, "")
               ) do
            {output, 0} -> {:ok, IO.iodata_to_binary(output)}
            {output, status} -> {:error, %{exit_status: status, output: IO.iodata_to_binary(output)}}
          end
        end
    end
  rescue
    error -> {:error, error}
  end

  defp run_provider_stream(executable, args, env, opts) do
    with {:ok, executable_path} <- resolve_executable(executable),
         {:ok, executable_path, args, interactive?} <- maybe_wrap_with_pty(executable_path, args, opts) do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable_path)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(args, &String.to_charlist/1),
            env: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
          ]
        )

      if interactive?, do: forward_stdin_to_port(port)
      receive_provider_stream(port, [])
    end
  end

  defp maybe_wrap_with_pty(executable, args, opts) do
    if Keyword.get(opts, :pty, false) do
      case System.find_executable("script") do
        nil ->
          {:error, :script_command_not_found_for_pty_login}

        script ->
          {:ok, script, script_args(executable, args), true}
      end
    else
      {:ok, executable, args, false}
    end
  end

  defp script_args(executable, args) do
    case :os.type() do
      {:unix, :darwin} ->
        ["-q", "/dev/null", executable | args]

      _ ->
        ["-q", "-c", shell_join([executable | args]), "/dev/null"]
    end
  end

  defp shell_join(parts), do: parts |> Enum.map(&shell_quote/1) |> Enum.join(" ")

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp forward_stdin_to_port(port) when is_port(port) do
    spawn(fn -> do_forward_stdin_to_port(port) end)
    :ok
  end

  defp do_forward_stdin_to_port(port) do
    case IO.read(:stdio, :line) do
      data when is_binary(data) ->
        if :erlang.port_info(port) != :undefined do
          Port.command(port, sanitize_interactive_input(data))
          do_forward_stdin_to_port(port)
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp sanitize_interactive_input(data) when is_binary(data) do
    data
    |> String.replace("\e[200~", "")
    |> String.replace("\e[201~", "")
  end

  defp receive_provider_stream(port, chunks) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        receive_provider_stream(port, [data | chunks])

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

      {^port, {:exit_status, status}} ->
        {:error, %{exit_status: status, output: IO.iodata_to_binary(Enum.reverse(chunks))}}
    end
  end

  defp resolve_executable(executable) do
    cond do
      String.contains?(executable, "/") and File.exists?(executable) ->
        {:ok, executable}

      is_binary(System.find_executable(executable)) ->
        {:ok, System.find_executable(executable)}

      true ->
        {:error, {:provider_command_not_found, executable}}
    end
  end

  defp shell_words(command) when is_binary(command) do
    command
    |> String.split(~r/\s+/, trim: true)
  end

  defp claude_credential_env(account) do
    token =
      account.claude_oauth_token_file
      |> File.read()
      |> case do
        {:ok, token} -> String.trim(token)
        _ -> nil
      end

    [
      {"CLAUDE_CODE_OAUTH_TOKEN", token},
      {"CLAUDE_CONFIG_DIR", account.claude_config_dir},
      {"ANTHROPIC_API_KEY", ""}
    ]
  end

  # Claude's setup-token flow should use the operator's currently active Claude
  # auth, exactly like running `claude setup-token` directly over SSH. The stored
  # OAuth token is what we isolate and inject into later worker runs.
  defp claude_login_env, do: []

  defp account_matches_host?(%{worker_host: nil}, nil), do: true
  defp account_matches_host?(%{worker_host: nil}, _worker_host), do: false
  defp account_matches_host?(%{worker_host: host}, host), do: true
  defp account_matches_host?(_account, _worker_host), do: false

  defp metadata_path(dir), do: Path.join(dir, @metadata_file)
  defp state_path(dir), do: Path.join(dir, @state_file)

  defp default_state do
    %{
      "state" => "unknown",
      "latest_rate_limits" => nil,
      "exhausted_until" => nil,
      "failure_reason" => nil,
      "last_success_at" => nil,
      "token_totals" => default_token_totals(),
      "rate_limit_periods" => %{},
      "updated_at" => now_iso()
    }
  end

  defp default_token_totals do
    %{
      "total" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
      "daily" => %{"period" => Date.utc_today() |> Date.to_iso8601(), "input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
      "monthly" => %{"period" => Date.utc_today() |> Calendar.strftime("%Y-%m"), "input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
    }
  end

  defp update_usage_totals(token_totals, delta, timestamp) do
    daily_period = DateTime.to_date(timestamp) |> Date.to_iso8601()
    monthly_period = DateTime.to_date(timestamp) |> Calendar.strftime("%Y-%m")

    token_totals
    |> Map.merge(default_token_totals(), fn _key, _default, value -> value end)
    |> update_usage_period("total", nil, delta)
    |> update_usage_period("daily", daily_period, delta)
    |> update_usage_period("monthly", monthly_period, delta)
  end

  defp update_usage_period(token_totals, key, period, delta) do
    current = Map.get(token_totals, key, %{})
    current = if is_nil(period) or Map.get(current, "period") == period, do: current, else: %{"period" => period}

    updated =
      Enum.reduce(["input_tokens", "output_tokens", "total_tokens"], current, fn token_key, acc ->
        Map.put(acc, token_key, integer_value(Map.get(acc, token_key)) + integer_value(Map.get(delta, token_key)))
      end)

    updated = if is_nil(period), do: updated, else: Map.put(updated, "period", period)
    Map.put(token_totals, key, updated)
  end

  defp update_rate_limit_period_token_totals(periods, delta) when is_map(periods) and is_map(delta) do
    Enum.reduce(periods, %{}, fn {bucket, period}, acc ->
      updated =
        Enum.reduce(["input_tokens", "output_tokens", "total_tokens"], period, fn token_key, period_acc ->
          Map.put(period_acc, token_key, integer_value(Map.get(period_acc, token_key)) + integer_value(Map.get(delta, token_key)))
        end)

      Map.put(acc, bucket, updated)
    end)
  end

  defp update_rate_limit_period_token_totals(_periods, _delta), do: %{}

  defp rotate_rate_limit_periods(state, rate_limits, account) do
    current_periods = Map.get(state, "rate_limit_periods", %{})
    now = now_iso()
    limit_id = rate_limit_id(rate_limits)

    {next_periods, rows} =
      rate_limit_bucket_entries(rate_limits)
      |> Enum.reduce({current_periods, []}, fn {bucket_name, period_name, bucket}, {periods, rows} ->
        reset_at = bucket_absolute_reset_at(bucket)

        if is_nil(reset_at) do
          {periods, rows}
        else
          existing = Map.get(periods, bucket_name)

          cond do
            is_nil(existing) ->
              {Map.put(periods, bucket_name, new_rate_limit_period(bucket_name, period_name, limit_id, bucket, reset_at, now)), rows}

            Map.get(existing, "reset_at") != reset_at ->
              row = usage_period_row(account, existing, bucket, reset_at, now)
              {Map.put(periods, bucket_name, new_rate_limit_period(bucket_name, period_name, limit_id, bucket, reset_at, now)), [row | rows]}

            true ->
              {Map.put(periods, bucket_name, refresh_rate_limit_period(existing, limit_id, bucket, now)), rows}
          end
        end
      end)

    {Map.put(state, "rate_limit_periods", next_periods), Enum.reverse(rows)}
  end

  defp rate_limit_bucket_entries(rate_limits) when is_map(rate_limits) do
    session_bucket =
      Map.get(rate_limits, "session") ||
        Map.get(rate_limits, :session) ||
        Map.get(rate_limits, "primary") ||
        Map.get(rate_limits, :primary)

    weekly_bucket =
      Map.get(rate_limits, "weekly") ||
        Map.get(rate_limits, :weekly) ||
        Map.get(rate_limits, "secondary") ||
        Map.get(rate_limits, :secondary)

    [
      {"session", "session", session_bucket},
      {"weekly", "weekly", weekly_bucket}
    ]
    |> Enum.filter(fn {_bucket_name, _period_name, bucket} -> is_map(bucket) end)
    |> Enum.map(fn {bucket_name, fallback_period_name, bucket} ->
      {bucket_name, bucket_period_name(bucket, bucket_name, fallback_period_name), bucket}
    end)
  end

  defp rate_limit_bucket_entries(_rate_limits), do: []

  defp new_rate_limit_period(bucket_name, period_name, limit_id, bucket, reset_at, now) do
    %{
      "bucket" => bucket_name,
      "period" => period_name,
      "limit_id" => limit_id,
      "started_at" => now,
      "reset_at" => reset_at,
      "last_seen_at" => now,
      "limit" => integer_value(Map.get(bucket, "limit") || Map.get(bucket, :limit)),
      "remaining" => integer_value(Map.get(bucket, "remaining") || Map.get(bucket, :remaining)),
      "input_tokens" => 0,
      "output_tokens" => 0,
      "total_tokens" => 0
    }
  end

  defp refresh_rate_limit_period(period, limit_id, bucket, now) do
    period
    |> Map.put("limit_id", limit_id || Map.get(period, "limit_id"))
    |> Map.put("last_seen_at", now)
    |> Map.put("limit", integer_value(Map.get(bucket, "limit") || Map.get(bucket, :limit)))
    |> Map.put("remaining", integer_value(Map.get(bucket, "remaining") || Map.get(bucket, :remaining)))
  end

  defp usage_period_row(account, period, next_bucket, next_reset_at, now) do
    limit = integer_value(Map.get(period, "limit"))
    remaining = integer_value(Map.get(period, "remaining"))
    used = if limit > 0, do: max(0, limit - remaining), else: 0
    usage_percent = usage_percent(used, limit)
    period_name = Map.get(period, "period")

    %{
      "logged_at" => now,
      "backend" => Map.get(account, :backend),
      "account_id" => Map.get(account, :id),
      "account_email" => Map.get(account, :email),
      "limit_id" => Map.get(period, "limit_id"),
      "bucket" => Map.get(period, "bucket"),
      "period" => period_name,
      "period_started_at" => Map.get(period, "started_at"),
      "reset_at" => Map.get(period, "reset_at"),
      "next_reset_at" => next_reset_at,
      "limit" => limit,
      "remaining" => remaining,
      "used" => used,
      "usage_percent" => usage_percent,
      "weekly_usage_percent" => if(period_name == "weekly", do: usage_percent),
      "input_tokens" => integer_value(Map.get(period, "input_tokens")),
      "output_tokens" => integer_value(Map.get(period, "output_tokens")),
      "total_tokens" => integer_value(Map.get(period, "total_tokens")),
      "next_limit" => integer_value(Map.get(next_bucket, "limit") || Map.get(next_bucket, :limit)),
      "next_remaining" => integer_value(Map.get(next_bucket, "remaining") || Map.get(next_bucket, :remaining))
    }
  end

  defp append_usage_period_rows(_account, []), do: :ok

  defp append_usage_period_rows(account, rows) when is_list(rows) do
    path = usage_periods_csv_path(account)
    write_header? = not File.regular?(path)

    csv =
      rows
      |> Enum.map(&usage_period_csv_line/1)
      |> Enum.join()

    contents =
      if write_header? do
        Enum.join(@usage_period_csv_header, ",") <> "\n" <> csv
      else
        csv
      end

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, contents, [:append]) do
      File.chmod(path, @secret_mode)
    end
  rescue
    error ->
      Logger.warning("Failed to append account usage period CSV for #{account_log_label(account)}: #{Exception.message(error)}")
      :ok
  end

  defp usage_period_csv_line(row) do
    @usage_period_csv_header
    |> Enum.map(fn field -> csv_escape(Map.get(row, field)) end)
    |> Enum.join(",")
    |> Kernel.<>("\n")
  end

  defp usage_periods_csv_path(nil), do: nil
  defp usage_periods_csv_path(%{account_dir: account_dir}) when is_binary(account_dir), do: Path.join(account_dir, @usage_periods_file)
  defp usage_periods_csv_path(_account), do: nil

  defp account_log_label(%{backend: backend, id: id}) when is_binary(backend) and is_binary(id),
    do: "#{backend}:#{id}"

  defp account_log_label(_account), do: "unknown"

  defp csv_escape(nil), do: ""

  defp csv_escape(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 2)
  end

  defp csv_escape(value) do
    value = to_string(value)

    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp usage_percent(_used, limit) when limit <= 0, do: nil
  defp usage_percent(used, limit), do: Float.round(used * 100 / limit, 2)

  defp rate_limit_id(rate_limits) do
    normalize_optional_string(
      Map.get(rate_limits, "limit_id") ||
        Map.get(rate_limits, :limit_id) ||
        Map.get(rate_limits, "limitId") ||
        Map.get(rate_limits, :limitId) ||
        Map.get(rate_limits, "limit_name") ||
        Map.get(rate_limits, :limit_name) ||
        Map.get(rate_limits, "limitName") ||
        Map.get(rate_limits, :limitName)
    )
  end

  defp bucket_period_name(bucket, bucket_name, fallback) do
    raw =
      Map.get(bucket, "period") ||
        Map.get(bucket, :period) ||
        Map.get(bucket, "window") ||
        Map.get(bucket, :window) ||
        Map.get(bucket, "name") ||
        Map.get(bucket, :name) ||
        fallback

    raw
    |> to_string()
    |> String.downcase()
    |> condense_period_name(bucket_name, fallback)
  end

  defp condense_period_name(value, _bucket_name, fallback) when value in ["", "nil"], do: fallback

  defp condense_period_name(value, bucket_name, fallback) do
    cond do
      String.contains?(value, ["week", "weekly", "7d"]) -> "weekly"
      String.contains?(value, ["session", "5h", "five"]) -> "session"
      bucket_name in ["secondary", "weekly"] -> "weekly"
      bucket_name in ["primary", "session"] -> "session"
      true -> fallback
    end
  end

  defp bucket_absolute_reset_at(bucket) when is_map(bucket) do
    reset_at =
      Map.get(bucket, "reset_at") ||
        Map.get(bucket, :reset_at) ||
        Map.get(bucket, "resetAt") ||
        Map.get(bucket, :resetAt)

    normalize_datetime_string(reset_at)
  end

  defp bucket_absolute_reset_at(_bucket), do: nil

  defp exhausted_until_from_rate_limits(rate_limits, accounts_settings) do
    if exhausted_rate_limits?(rate_limits) do
      reset_at_from_rate_limits(rate_limits) ||
        DateTime.utc_now()
        |> DateTime.add(accounts_settings.exhausted_cooldown_ms, :millisecond)
        |> DateTime.to_iso8601()
    end
  end

  defp exhausted_rate_limits?(rate_limits) when is_map(rate_limits) do
    primary =
      Map.get(rate_limits, "session") ||
        Map.get(rate_limits, :session) ||
        Map.get(rate_limits, "primary") ||
        Map.get(rate_limits, :primary)

    secondary =
      Map.get(rate_limits, "weekly") ||
        Map.get(rate_limits, :weekly) ||
        Map.get(rate_limits, "secondary") ||
        Map.get(rate_limits, :secondary)

    credits = Map.get(rate_limits, "credits") || Map.get(rate_limits, :credits)

    zero_remaining?(primary) or zero_remaining?(secondary) or depleted_credits?(credits)
  end

  defp limited_rate_limits?(rate_limits) when is_map(rate_limits) do
    primary =
      Map.get(rate_limits, "session") ||
        Map.get(rate_limits, :session) ||
        Map.get(rate_limits, "primary") ||
        Map.get(rate_limits, :primary)

    secondary =
      Map.get(rate_limits, "weekly") ||
        Map.get(rate_limits, :weekly) ||
        Map.get(rate_limits, "secondary") ||
        Map.get(rate_limits, :secondary)

    low_remaining?(primary) or low_remaining?(secondary)
  end

  defp zero_remaining?(nil), do: false

  defp zero_remaining?(bucket) when is_map(bucket) do
    case integer_value(Map.get(bucket, "remaining") || Map.get(bucket, :remaining)) do
      0 -> true
      _ -> false
    end
  end

  defp low_remaining?(nil), do: false

  defp low_remaining?(bucket) when is_map(bucket) do
    remaining = integer_value(Map.get(bucket, "remaining") || Map.get(bucket, :remaining))
    limit = integer_value(Map.get(bucket, "limit") || Map.get(bucket, :limit))
    limit > 0 and remaining > 0 and remaining / limit < 0.1
  end

  defp depleted_credits?(nil), do: false

  defp depleted_credits?(credits) when is_map(credits) do
    unlimited = Map.get(credits, "unlimited") || Map.get(credits, :unlimited)
    has_credits = Map.get(credits, "has_credits") || Map.get(credits, :has_credits)
    balance = Map.get(credits, "balance") || Map.get(credits, :balance)

    cond do
      unlimited == true -> false
      has_credits == false -> true
      is_number(balance) -> balance <= 0
      is_binary(balance) -> Decimal.compare(Decimal.new(balance), Decimal.new(0)) in [:lt, :eq]
      true -> false
    end
  rescue
    _ -> false
  end

  defp reset_at_from_rate_limits(rate_limits) do
    [
      Map.get(rate_limits, "session") || Map.get(rate_limits, :session),
      Map.get(rate_limits, "weekly") || Map.get(rate_limits, :weekly),
      Map.get(rate_limits, "primary") || Map.get(rate_limits, :primary),
      Map.get(rate_limits, "secondary") || Map.get(rate_limits, :secondary)
    ]
    |> Enum.flat_map(&bucket_reset_candidates/1)
    |> Enum.sort()
    |> List.first()
  end

  defp latest_reset_at(%{latest_rate_limits: %{} = rate_limits}), do: reset_at_from_rate_limits(rate_limits)
  defp latest_reset_at(_account), do: nil

  defp bucket_reset_candidates(nil), do: []

  defp bucket_reset_candidates(bucket) when is_map(bucket) do
    absolute =
      Map.get(bucket, "reset_at") ||
        Map.get(bucket, :reset_at) ||
        Map.get(bucket, "resetAt") ||
        Map.get(bucket, :resetAt)

    relative =
      Map.get(bucket, "reset_in_seconds") ||
        Map.get(bucket, :reset_in_seconds) ||
        Map.get(bucket, "reset_after_seconds") ||
        Map.get(bucket, :reset_after_seconds)

    [normalize_datetime_string(absolute), relative_reset(relative)]
    |> Enum.reject(&is_nil/1)
  end

  defp relative_reset(value) do
    case integer_value(value) do
      seconds when seconds > 0 -> DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
      _ -> nil
    end
  end

  defp normalize_datetime_string(nil), do: nil

  defp normalize_datetime_string(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp normalize_datetime_string(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> DateTime.to_iso8601(timestamp)
      _ -> if(value == "", do: nil, else: value)
    end
  end

  defp default_provider_command("codex"), do: "codex"
  defp default_provider_command("claude"), do: "claude"

  defp default_credential_kind("codex"), do: "codex_home"
  defp default_credential_kind("claude"), do: "claude_oauth_token"

  defp extract_claude_oauth_token(output) when is_binary(output) do
    token =
      output
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reverse()
      |> Enum.find(&String.match?(&1, ~r/^(sk-ant-oat|oauth|claude)[A-Za-z0-9._:-]+/))

    case token do
      nil -> {:error, {:missing_claude_oauth_token, output}}
      token -> {:ok, token}
    end
  end

  defp extract_email(output) when is_binary(output) do
    Regex.run(~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, output)
    |> case do
      [email | _] -> email
      _ -> nil
    end
  end

  defp accounts_settings(nil), do: Config.accounts_settings()

  defp accounts_settings(%{accounts: accounts}) do
    %{
      enabled: Map.get(accounts, :enabled, false),
      store_root: Map.get(accounts, :store_root, Path.expand("~/.symphony/accounts")),
      allow_host_auth_fallback: Map.get(accounts, :allow_host_auth_fallback, false),
      rotation_strategy: Map.get(accounts, :rotation_strategy, "usage_aware_round_robin"),
      max_concurrent_sessions_per_account: Map.get(accounts, :max_concurrent_sessions_per_account, 1),
      exhausted_cooldown_ms: Map.get(accounts, :exhausted_cooldown_ms, 300_000),
      daily_token_budget: Map.get(accounts, :daily_token_budget),
      monthly_token_budget: Map.get(accounts, :monthly_token_budget)
    }
  end

  defp accounts_settings(%{} = accounts) do
    %{
      enabled: Map.get(accounts, :enabled, false),
      store_root: Map.get(accounts, :store_root, Path.expand("~/.symphony/accounts")),
      allow_host_auth_fallback: Map.get(accounts, :allow_host_auth_fallback, false),
      rotation_strategy: Map.get(accounts, :rotation_strategy, "usage_aware_round_robin"),
      max_concurrent_sessions_per_account: Map.get(accounts, :max_concurrent_sessions_per_account, 1),
      exhausted_cooldown_ms: Map.get(accounts, :exhausted_cooldown_ms, 300_000),
      daily_token_budget: Map.get(accounts, :daily_token_budget),
      monthly_token_budget: Map.get(accounts, :monthly_token_budget)
    }
  end

  defp normalize_id!(id) when is_binary(id) do
    case String.trim(id) do
      "" -> raise ArgumentError, "account id must not be blank"
      id -> id
    end
  end

  defp safe_segment(value) do
    value
    |> URI.encode(&(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 in ~c"-_.@"))
    |> String.replace("%", "_")
  end

  defp read_json(path, default) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, value} when is_map(value) -> {:ok, value}
          {:ok, _value} -> {:ok, default}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, default}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_json(path, data, mode) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(data, pretty: true) <> "\n") do
      File.chmod(path, mode)
    end
  end

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn
      {_key, nil}, acc -> acc
      {key, nested}, acc -> Map.put(acc, key, nested)
    end)
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value), do: value

  defp integer_value(value) when is_integer(value) and value >= 0, do: value
  defp integer_value(value) when is_float(value) and value >= 0, do: trunc(value)

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _rest} when num >= 0 -> num
      _ -> 0
    end
  end

  defp integer_value(_value), do: 0

  defp positive_integer_value(value) do
    case integer_value(value) do
      number when number > 0 -> number
      _ -> nil
    end
  end

  defp quota_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 500)
    |> String.slice(0, 500)
  end

  defp current_settings do
    case Config.settings() do
      {:ok, settings} -> settings
      {:error, _reason} -> %{accounts: default_accounts_settings()}
    end
  end

  defp default_accounts_settings do
    %{
      enabled: false,
      store_root: Path.expand("~/.symphony/accounts"),
      allow_host_auth_fallback: false,
      rotation_strategy: "usage_aware_round_robin",
      max_concurrent_sessions_per_account: 1,
      exhausted_cooldown_ms: 300_000,
      daily_token_budget: nil,
      monthly_token_budget: nil
    }
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
