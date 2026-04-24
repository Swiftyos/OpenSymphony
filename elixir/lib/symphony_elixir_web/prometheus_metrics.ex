defmodule SymphonyElixirWeb.PrometheusMetrics do
  @moduledoc """
  Renders Prometheus exposition text for Symphony account usage and rate-limit data.
  """

  alias SymphonyElixir.{Accounts, Config}

  @usage_periods_file "usage_periods.csv"

  @metric_definitions [
    %{
      name: "symphony_account_rate_limit_limit",
      help: "Current account rate-limit bucket limit.",
      type: "gauge"
    },
    %{
      name: "symphony_account_rate_limit_remaining",
      help: "Current account rate-limit bucket remaining capacity.",
      type: "gauge"
    },
    %{
      name: "symphony_account_rate_limit_used",
      help: "Current account rate-limit bucket used capacity.",
      type: "gauge"
    },
    %{
      name: "symphony_account_rate_limit_usage_percent",
      help: "Current account rate-limit bucket usage percentage.",
      type: "gauge"
    },
    %{
      name: "symphony_account_rate_limit_reset_timestamp_seconds",
      help: "Current account rate-limit bucket reset time as a Unix timestamp.",
      type: "gauge"
    },
    %{
      name: "symphony_account_state_info",
      help: "Account identity and current state information.",
      type: "gauge"
    },
    %{
      name: "symphony_account_usage_period_tokens",
      help: "Observed token totals for an account usage period.",
      type: "gauge"
    },
    %{
      name: "symphony_account_usage_period_limit",
      help: "Limit for an account usage period bucket.",
      type: "gauge"
    },
    %{
      name: "symphony_account_usage_period_remaining",
      help: "Remaining capacity for an account usage period bucket.",
      type: "gauge"
    },
    %{
      name: "symphony_account_usage_period_used",
      help: "Used capacity for an account usage period bucket.",
      type: "gauge"
    },
    %{
      name: "symphony_account_usage_period_usage_percent",
      help: "Usage percentage for an account usage period bucket.",
      type: "gauge"
    }
  ]

  @type metric_value :: integer() | float()
  @type sample :: %{
          name: String.t(),
          labels: keyword(String.t()),
          value: metric_value()
        }

  @spec render(term()) :: String.t()
  def render(settings \\ Config.settings!()) do
    samples =
      settings
      |> accounts()
      |> Enum.flat_map(&account_samples/1)
      |> Enum.group_by(& &1.name)

    @metric_definitions
    |> Enum.map_join("\n\n", fn definition ->
      block_lines =
        [
          "# HELP #{definition.name} #{definition.help}",
          "# TYPE #{definition.name} #{definition.type}"
        ] ++
          (samples
           |> Map.get(definition.name, [])
           |> Enum.sort_by(&sample_sort_key/1)
           |> Enum.map(&render_sample/1))

      Enum.join(block_lines, "\n")
    end)
    |> Kernel.<>("\n")
  end

  defp accounts(%{accounts: %{enabled: true}} = settings) do
    case Accounts.list(nil, settings) do
      {:ok, accounts} -> accounts
      _ -> []
    end
  rescue
    _ -> []
  end

  defp accounts(_settings), do: []

  defp account_samples(account) do
    base_identity = identity_labels(account)

    [
      state_info_sample(account, base_identity)
      | current_rate_limit_samples(account, base_identity) ++ usage_period_samples(account, base_identity)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp state_info_sample(account, base_identity) do
    %{
      name: "symphony_account_state_info",
      labels:
        base_identity ++
          [
            state: string_value(Map.get(account, :state) || "unknown"),
            credential_kind: string_value(Map.get(account, :credential_kind))
          ],
      value: 1
    }
  end

  defp current_rate_limit_samples(account, base_identity) do
    account
    |> Map.get(:latest_rate_limits, %{})
    |> rate_limit_buckets()
    |> Enum.flat_map(fn {bucket_name, limit_id, bucket} ->
      labels =
        base_identity ++
          [
            limit_id: string_value(limit_id),
            bucket: string_value(bucket_name)
          ]

      limit = integer_value(Map.get(bucket, "limit") || Map.get(bucket, :limit))
      remaining = integer_value(Map.get(bucket, "remaining") || Map.get(bucket, :remaining))
      used = if is_integer(limit) and is_integer(remaining), do: max(limit - remaining, 0)
      usage_percent = bucket_usage_percent(bucket, used, limit)
      reset_timestamp = reset_timestamp_seconds(bucket)

      []
      |> maybe_add_sample("symphony_account_rate_limit_limit", labels, limit)
      |> maybe_add_sample("symphony_account_rate_limit_remaining", labels, remaining)
      |> maybe_add_sample("symphony_account_rate_limit_used", labels, used)
      |> maybe_add_sample("symphony_account_rate_limit_usage_percent", labels, usage_percent)
      |> maybe_add_sample("symphony_account_rate_limit_reset_timestamp_seconds", labels, reset_timestamp)
    end)
  end

  defp usage_period_samples(account, base_identity) do
    active_rows = active_usage_period_rows(account)
    closed_rows = closed_usage_period_rows(account)

    (active_rows ++ closed_rows)
    |> Enum.flat_map(fn row ->
      labels =
        base_identity ++
          [
            limit_id: string_value(Map.get(row, "limit_id")),
            bucket: string_value(Map.get(row, "bucket")),
            period: string_value(Map.get(row, "period")),
            period_started_at: string_value(Map.get(row, "period_started_at")),
            reset_at: string_value(Map.get(row, "reset_at")),
            period_status: string_value(Map.get(row, "period_status"))
          ]

      limit = integer_value(Map.get(row, "limit"))
      remaining = integer_value(Map.get(row, "remaining"))
      used = integer_value(Map.get(row, "used")) || if(is_integer(limit) and is_integer(remaining), do: max(limit - remaining, 0))
      usage_percent = float_value(Map.get(row, "usage_percent")) || percent_value(used, limit)

      token_samples =
        [
          {"input", integer_value(Map.get(row, "input_tokens"))},
          {"output", integer_value(Map.get(row, "output_tokens"))},
          {"total", integer_value(Map.get(row, "total_tokens"))}
        ]
        |> Enum.flat_map(fn {token_type, value} ->
          case value do
            nil ->
              []

            numeric ->
              [
                %{
                  name: "symphony_account_usage_period_tokens",
                  labels: labels ++ [token_type: token_type],
                  value: numeric
                }
              ]
          end
        end)

      (token_samples ++
         [])
      |> maybe_add_sample("symphony_account_usage_period_limit", labels, limit)
      |> maybe_add_sample("symphony_account_usage_period_remaining", labels, remaining)
      |> maybe_add_sample("symphony_account_usage_period_used", labels, used)
      |> maybe_add_sample("symphony_account_usage_period_usage_percent", labels, usage_percent)
    end)
  end

  defp active_usage_period_rows(account) do
    current_buckets = current_rate_limit_bucket_map(account)

    persisted_rows =
      account
      |> Map.get(:rate_limit_periods, %{})
      |> Enum.map(fn {bucket_name, period} ->
        normalize_active_usage_period_row(period, bucket_name, Map.get(current_buckets, bucket_name))
      end)
      |> Enum.reject(&is_nil/1)

    persisted_buckets =
      persisted_rows
      |> Enum.map(&Map.get(&1, "bucket"))
      |> MapSet.new()

    fallback_rows =
      current_buckets
      |> Enum.reject(fn {bucket_name, _bucket_data} -> MapSet.member?(persisted_buckets, bucket_name) end)
      |> Enum.map(fn {bucket_name, bucket_data} ->
        fallback_active_usage_period_row(bucket_name, bucket_data)
      end)

    persisted_rows ++ Enum.reject(fallback_rows, &is_nil/1)
  end

  defp closed_usage_period_rows(account) do
    account
    |> usage_periods_path()
    |> read_usage_period_rows()
    |> Enum.map(fn row ->
      Map.put(row, "period_status", "closed")
    end)
  end

  defp usage_periods_path(account) do
    case Accounts.account_summary(account) do
      %{usage_periods_csv: path} when is_binary(path) and path != "" -> path
      _ -> Path.join(Map.get(account, :account_dir, "."), @usage_periods_file)
    end
  end

  defp read_usage_period_rows(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> parse_usage_period_csv(contents)
      _ -> []
    end
  end

  defp parse_usage_period_csv(contents) when is_binary(contents) do
    case String.split(contents, ~r/\r\n|\n|\r/, trim: true) do
      [] ->
        []

      [header | rows] ->
        headers = parse_csv_line(header)

        rows
        |> Enum.map(&parse_csv_line/1)
        |> Enum.filter(&(length(&1) == length(headers)))
        |> Enum.map(fn fields ->
          headers
          |> Enum.zip(fields)
          |> Map.new()
          |> normalize_closed_usage_period_row()
        end)
    end
  end

  defp normalize_closed_usage_period_row(row) do
    %{
      "limit_id" => Map.get(row, "limit_id"),
      "bucket" => Map.get(row, "bucket"),
      "period" => Map.get(row, "period"),
      "period_started_at" => Map.get(row, "period_started_at"),
      "reset_at" => Map.get(row, "reset_at"),
      "limit" => integer_value(Map.get(row, "limit")),
      "remaining" => integer_value(Map.get(row, "remaining")),
      "used" => integer_value(Map.get(row, "used")),
      "usage_percent" => float_value(Map.get(row, "usage_percent")),
      "input_tokens" => integer_value(Map.get(row, "input_tokens")),
      "output_tokens" => integer_value(Map.get(row, "output_tokens")),
      "total_tokens" => integer_value(Map.get(row, "total_tokens"))
    }
  end

  defp parse_csv_line(line) when is_binary(line) do
    do_parse_csv_line(line, [], "", false)
    |> Enum.reverse()
    |> Enum.map(&normalize_csv_field/1)
  end

  defp do_parse_csv_line(<<>>, fields, current, _quoted), do: [current | fields]

  defp do_parse_csv_line(<<?", ?", rest::binary>>, fields, current, true),
    do: do_parse_csv_line(rest, fields, current <> "\"", true)

  defp do_parse_csv_line(<<?", rest::binary>>, fields, current, quoted),
    do: do_parse_csv_line(rest, fields, current, not quoted)

  defp do_parse_csv_line(<<?,, rest::binary>>, fields, current, false),
    do: do_parse_csv_line(rest, [current | fields], "", false)

  defp do_parse_csv_line(<<char::utf8, rest::binary>>, fields, current, quoted),
    do: do_parse_csv_line(rest, fields, current <> <<char::utf8>>, quoted)

  defp normalize_csv_field(field) do
    field
    |> String.trim()
    |> case do
      "\"" <> rest ->
        rest
        |> String.trim_trailing("\"")
        |> String.replace("\"\"", "\"")

      other ->
        other
    end
  end

  defp rate_limit_buckets(rate_limits) when is_map(rate_limits) do
    limit_id = rate_limit_id(rate_limits)

    [
      {"session", Map.get(rate_limits, "session") || Map.get(rate_limits, :session) || Map.get(rate_limits, "primary") || Map.get(rate_limits, :primary)},
      {"weekly", Map.get(rate_limits, "weekly") || Map.get(rate_limits, :weekly) || Map.get(rate_limits, "secondary") || Map.get(rate_limits, :secondary)}
    ]
    |> Enum.filter(fn {_bucket_name, bucket} -> is_map(bucket) end)
    |> Enum.map(fn {bucket_name, bucket} -> {bucket_name, limit_id, bucket} end)
  end

  defp rate_limit_buckets(_rate_limits), do: []

  defp current_rate_limit_bucket_map(account) do
    account
    |> Map.get(:latest_rate_limits, %{})
    |> rate_limit_buckets()
    |> Map.new(fn {bucket_name, limit_id, bucket} ->
      {bucket_name, %{limit_id: limit_id, bucket: bucket}}
    end)
  end

  defp normalize_active_usage_period_row(period, bucket_name, current_bucket_data) when is_map(period) do
    current_bucket = bucket_from_bucket_data(current_bucket_data)
    current_limit_id = limit_id_from_bucket_data(current_bucket_data)
    limit = integer_value(map_value(period, :limit) || map_value(current_bucket, :limit))
    remaining = integer_value(map_value(period, :remaining) || map_value(current_bucket, :remaining))
    used = integer_value(map_value(period, :used)) || bucket_used(limit, remaining)

    %{
      "limit_id" => map_value(period, :limit_id) || current_limit_id,
      "bucket" => map_value(period, :bucket) || bucket_name,
      "period" => map_value(period, :period) || bucket_name,
      "period_started_at" => datetime_string(map_value(period, :started_at)) || bucket_period_started_at(current_bucket),
      "reset_at" => datetime_string(map_value(period, :reset_at)) || bucket_reset_at_string(current_bucket),
      "period_status" => "active",
      "limit" => limit,
      "remaining" => remaining,
      "used" => used,
      "usage_percent" => float_value(map_value(period, :usage_percent)) || bucket_usage_percent(current_bucket, used, limit),
      "input_tokens" => integer_value(map_value(period, :input_tokens)),
      "output_tokens" => integer_value(map_value(period, :output_tokens)),
      "total_tokens" => integer_value(map_value(period, :total_tokens))
    }
  end

  defp normalize_active_usage_period_row(_period, _bucket_name, _current_bucket_data), do: nil

  defp fallback_active_usage_period_row(bucket_name, %{limit_id: limit_id, bucket: bucket})
       when is_map(bucket) do
    limit = integer_value(map_value(bucket, :limit))
    remaining = integer_value(map_value(bucket, :remaining))
    used = bucket_used(limit, remaining)

    %{
      "limit_id" => limit_id,
      "bucket" => bucket_name,
      "period" => bucket_name,
      "period_started_at" => bucket_period_started_at(bucket),
      "reset_at" => bucket_reset_at_string(bucket),
      "period_status" => "active",
      "limit" => limit,
      "remaining" => remaining,
      "used" => used,
      "usage_percent" => bucket_usage_percent(bucket, used, limit),
      "input_tokens" => nil,
      "output_tokens" => nil,
      "total_tokens" => nil
    }
  end

  defp fallback_active_usage_period_row(_bucket_name, _bucket_data), do: nil

  defp limit_id_from_bucket_data(%{limit_id: limit_id}), do: limit_id
  defp limit_id_from_bucket_data(_bucket_data), do: nil

  defp bucket_from_bucket_data(%{bucket: bucket}), do: bucket
  defp bucket_from_bucket_data(_bucket_data), do: nil

  defp bucket_used(limit, remaining) when is_integer(limit) and is_integer(remaining), do: max(limit - remaining, 0)
  defp bucket_used(_limit, _remaining), do: nil

  defp bucket_period_started_at(bucket) when is_map(bucket) do
    with %DateTime{} = reset_at <- reset_time(bucket),
         minutes when is_integer(minutes) and minutes > 0 <- bucket_window_minutes(bucket) do
      reset_at
      |> DateTime.add(-minutes * 60, :second)
      |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  end

  defp bucket_period_started_at(_bucket), do: nil

  defp bucket_window_minutes(bucket) when is_map(bucket) do
    integer_value(
      Map.get(bucket, "windowDurationMins") ||
        Map.get(bucket, :windowDurationMins) ||
        Map.get(bucket, "window_duration_mins") ||
        Map.get(bucket, :window_duration_mins) ||
        Map.get(bucket, "window_minutes") ||
        Map.get(bucket, :window_minutes)
    )
  end

  defp bucket_window_minutes(_bucket), do: nil

  defp bucket_reset_at_string(bucket) do
    case reset_time(bucket) do
      %DateTime{} = reset_at -> DateTime.to_iso8601(reset_at)
      _ -> nil
    end
  end

  defp rate_limit_id(rate_limits) do
    Map.get(rate_limits, "limit_id") ||
      Map.get(rate_limits, :limit_id) ||
      Map.get(rate_limits, "limitId") ||
      Map.get(rate_limits, :limitId) ||
      Map.get(rate_limits, "limit_name") ||
      Map.get(rate_limits, :limit_name) ||
      Map.get(rate_limits, "limitName") ||
      Map.get(rate_limits, :limitName)
  end

  defp reset_timestamp_seconds(bucket) do
    bucket
    |> reset_time()
    |> case do
      %DateTime{} = timestamp -> DateTime.to_unix(timestamp)
      _ -> nil
    end
  end

  defp reset_time(bucket) when is_map(bucket) do
    absolute =
      Map.get(bucket, "reset_at") ||
        Map.get(bucket, :reset_at) ||
        Map.get(bucket, "resetAt") ||
        Map.get(bucket, :resetAt) ||
        Map.get(bucket, "resets_at") ||
        Map.get(bucket, :resets_at) ||
        Map.get(bucket, "resetsAt") ||
        Map.get(bucket, :resetsAt)

    relative =
      Map.get(bucket, "reset_in_seconds") ||
        Map.get(bucket, :reset_in_seconds) ||
        Map.get(bucket, "resets_in_seconds") ||
        Map.get(bucket, :resets_in_seconds) ||
        Map.get(bucket, "reset_after_seconds") ||
        Map.get(bucket, :reset_after_seconds)

    normalize_datetime(absolute) || relative_reset(relative)
  end

  defp reset_time(_bucket), do: nil

  defp bucket_usage_percent(bucket, used, limit) when is_map(bucket) do
    float_value(
      Map.get(bucket, "usage_percent") ||
        Map.get(bucket, :usage_percent) ||
        Map.get(bucket, "usedPercent") ||
        Map.get(bucket, :usedPercent)
    ) || percent_value(used, limit)
  end

  defp bucket_usage_percent(_bucket, used, limit), do: percent_value(used, limit)

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp relative_reset(value) do
    case integer_value(value) do
      seconds when is_integer(seconds) and seconds > 0 ->
        DateTime.utc_now() |> DateTime.add(seconds, :second)

      _ ->
        nil
    end
  end

  defp identity_labels(account) do
    [
      backend: string_value(Map.get(account, :backend)),
      account_id: string_value(Map.get(account, :id)),
      account_email: string_value(Map.get(account, :email))
    ]
  end

  defp maybe_add_sample(samples, _name, _labels, nil), do: samples

  defp maybe_add_sample(samples, name, labels, value) do
    [
      %{
        name: name,
        labels: labels,
        value: value
      }
      | samples
    ]
  end

  defp render_sample(%{name: name, labels: labels, value: value}) do
    "#{name}#{render_labels(labels)} #{render_value(value)}"
  end

  defp render_labels([]), do: ""

  defp render_labels(labels) do
    rendered =
      labels
      |> Enum.map(fn {key, value} -> "#{key}=\"#{escape_label_value(value)}\"" end)
      |> Enum.join(",")

    "{#{rendered}}"
  end

  defp render_value(value) when is_integer(value), do: Integer.to_string(value)
  defp render_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)

  defp escape_label_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\"", "\\\"")
  end

  defp sample_sort_key(sample) do
    {sample.name, Enum.map(sample.labels, fn {key, value} -> {key, to_string(value)} end)}
  end

  defp percent_value(used, limit) when is_integer(used) and is_integer(limit) and limit > 0 do
    Float.round(used * 100 / limit, 2)
  end

  defp percent_value(_used, _limit), do: nil

  defp normalize_datetime(%DateTime{} = timestamp), do: timestamp

  defp normalize_datetime(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value) do
      {:ok, timestamp} -> timestamp
      _ -> nil
    end
  end

  defp normalize_datetime(value) when is_binary(value) do
    trimmed = String.trim(value)

    case DateTime.from_iso8601(trimmed) do
      {:ok, timestamp, _offset} ->
        timestamp

      _ ->
        case Integer.parse(trimmed) do
          {unix_seconds, ""} -> normalize_datetime(unix_seconds)
          _ -> nil
        end
    end
  end

  defp normalize_datetime(_value), do: nil

  defp datetime_string(value) do
    case normalize_datetime(value) do
      %DateTime{} = timestamp -> DateTime.to_iso8601(timestamp)
      _ -> nil
    end
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_float(value) and trunc(value) == value,
    do: trunc(value)

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp float_value(value) when is_float(value), do: value
  defp float_value(value) when is_integer(value), do: value * 1.0

  defp float_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp float_value(_value), do: nil

  defp string_value(nil), do: ""
  defp string_value(value), do: to_string(value)
end
