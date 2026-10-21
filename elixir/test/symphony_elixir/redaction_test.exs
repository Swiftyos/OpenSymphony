defmodule SymphonyElixir.RedactionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Redaction

  test "redact removes GitHub tokens, JWTs and private keys" do
    installation = "ghs_" <> String.duplicate("a", 36)
    pat = "github_pat_" <> String.duplicate("b", 30)
    personal = "ghp_" <> String.duplicate("c", 36)
    jwt = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOjF9.signature"

    text = "token #{installation} #{pat} #{personal} #{jwt}"
    redacted = Redaction.redact(text)
    assert redacted =~ "[REDACTED]"
    refute redacted =~ installation
    refute redacted =~ pat
    refute redacted =~ personal
    refute redacted =~ jwt
    assert Redaction.redact(:atom) == :atom

    pem = "-----BEGIN RSA PRIVATE KEY-----\nsecret\n-----END RSA PRIVATE KEY-----"
    refute Redaction.redact("key #{pem}") =~ "secret"
  end

  test "filter redacts string and format messages and leaves the rest alone" do
    token = "ghs_" <> String.duplicate("d", 36)

    assert %{msg: {:string, text}} = Redaction.filter(%{msg: {:string, String.to_charlist("token " <> token)}}, [])
    assert text == "token [REDACTED]"

    assert %{msg: {:string, text}} = Redaction.filter(%{msg: {"token ~s", [token]}}, [])
    assert text == "token [REDACTED]"

    # A format that does not match its arguments falls back to inspect, still redacted.
    assert %{msg: {:string, text}} = Redaction.filter(%{msg: {~c"bad~s ~s", [token]}}, [])
    assert text =~ "[REDACTED]"
    refute text =~ token

    assert %{msg: {:string, "token [REDACTED]"}} = Redaction.filter(%{msg: "token " <> token}, [])

    clean = %{msg: {:string, ~c"nothing secret"}}
    assert Redaction.filter(clean, []) == clean

    report = %{msg: {:report, %{token: token}}}
    assert %{msg: {:report, %{token: "[REDACTED]"}}} = Redaction.filter(report, [])

    bad = %{msg: {:string, {:bad, :chardata}}}
    assert Redaction.filter(bad, []) == bad
    assert Redaction.filter(%{msg: 123}, []) == %{msg: 123}
    assert Redaction.filter(%{not_msg: true}, []) == %{not_msg: true}
    assert Redaction.configure() == :ok
  end

  test "filter scans invalid unicode, odd chardata and improper report lists without raising" do
    token = "ghs_" <> String.duplicate("e", 36)

    assert %{msg: {:string, <<0xFF>>}} = Redaction.filter(%{msg: {:string, <<0xFF>>}}, [])
    assert %{msg: {:string, [<<0xFF>>]}} = Redaction.filter(%{msg: {:string, [<<0xFF>>]}}, [])

    assert %{msg: {:report, [head | tail]}} = Redaction.filter(%{msg: {:report, [token | :tail]}}, [])
    assert head == "[REDACTED]"
    assert tail == :tail

    assert %{msg: {:string, text}, meta: %{token: "[REDACTED]"}} =
             Redaction.filter(%{msg: {:string, "ok"}, meta: %{token: token}}, [])

    assert text == "ok"
  end

  test "Basic and Bearer authorization values are redacted, the scheme is kept" do
    token = "ghs_test_installation_token_1234567890"
    git_header = "Authorization: Basic " <> Base.encode64("x-access-token:" <> token)

    assert Redaction.redact(git_header) == "Authorization: Basic [REDACTED]"
    assert Redaction.redact("authorization: bearer abcdefghijklmnop1234") == "authorization: bearer [REDACTED]"
    assert Redaction.redact("Authorization: BEARER\tabc.def-ghi_jkl~mno+p/q=") == "Authorization: BEARER\t[REDACTED]"
    assert Redaction.redact("Bearer eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOjF9.sig") == "Bearer [REDACTED]"
    # Short values and plain prose are left alone.
    assert Redaction.redact("Basic short") == "Basic short"
    assert Redaction.redact("a basic idea, nothing more") == "a basic idea, nothing more"
    assert Redaction.redact("plain text without secrets") == "plain text without secrets"
  end

  test "reports and metadata have their string values redacted, keeping their shape" do
    token = "ghs_" <> String.duplicate("f", 36)
    report = %{label: {:supervisor, :child}, report: [reason: {:error, "failed with #{token}"}, args: [token, 1, :x]], uri: URI.parse("https://x/#{token}")}

    assert %{msg: {:report, redacted}, meta: meta} = Redaction.filter(%{msg: {:report, report}, meta: %{header: "Bearer " <> token, pid: self(), line: 3}}, [])
    assert redacted.label == {:supervisor, :child}
    assert redacted.report[:reason] == {:error, "failed with [REDACTED]"}
    assert redacted.report[:args] == ["[REDACTED]", 1, :x]
    assert %URI{path: "/[REDACTED]"} = redacted.uri
    assert meta == %{header: "Bearer [REDACTED]", pid: self(), line: 3}

    # Bounded depth: values nested deeper than the limit are left as they are.
    deep = Enum.reduce(1..20, token, fn _, acc -> [acc] end)
    assert %{msg: {:report, _}} = Redaction.filter(%{msg: {:report, deep}}, [])
  end

  test "the filter never raises, whatever the event" do
    token = "ghs_" <> String.duplicate("g", 36)

    odd = [
      %{msg: {:string, [0x110000]}},
      %{msg: {:string, [<<0xFF>>, token]}},
      %{msg: {:string, [?a | <<0xC3>>]}},
      %{msg: {:string, {:bad, :chardata}}},
      %{msg: {:report, [token | :improper]}},
      %{msg: {:report, {token, %{nested: [token]}}}},
      %{msg: {:report, :not_a_map}},
      %{msg: {~c"~p ~p", [:only_one]}},
      %{msg: {:io_lib_format, :bad}},
      %{msg: {:string, "ok"}, meta: :not_a_map},
      %{msg: nil},
      %{},
      :not_a_map,
      nil
    ]

    for event <- odd do
      result = Redaction.filter(event, [])
      refute inspect(result, limit: :infinity) =~ token
    end

    # Invalid UTF-8 is still scanned byte by byte.
    assert %{msg: {:string, redacted}} = Redaction.filter(%{msg: {:string, [<<0xFF>>, " ", token]}}, [])
    assert redacted == <<0xFF, " [REDACTED]">>
    assert %{msg: {:string, "[" <> _}} = Redaction.filter(%{msg: {:string, [0x110000, token]}}, [])
  end

  test "the filter is cheap for messages without secrets" do
    events = for i <- 1..10_000, do: %{msg: {:string, "workspace prepared issue=MT-#{i} status=ok elapsed_ms=#{i}"}, meta: %{issue_id: "i-#{i}", line: i}}
    _warmup = Redaction.filter(hd(events), [])

    {elapsed_us, results} = :timer.tc(fn -> Enum.map(events, &Redaction.filter(&1, [])) end)

    assert results == events
    assert elapsed_us < 1_000_000, "10k clean messages took #{elapsed_us}us"
  end
end

defmodule SymphonyElixir.RedactionThrowTest do
  # Not async: it swaps the global default inspect function.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Redaction

  test "a throw while formatting returns the event instead of escaping the filter" do
    previous = Inspect.Opts.default_inspect_fun()
    on_exit(fn -> Inspect.Opts.default_inspect_fun(previous) end)

    # A format that does not match its arguments falls back to inspect/1.
    event = %{msg: {~c"bad~s ~s", [:one]}}
    Inspect.Opts.default_inspect_fun(fn _term, _opts -> throw(:inspect_threw) end)
    result = Redaction.filter(event, [])
    Inspect.Opts.default_inspect_fun(previous)

    assert result == event
  end
end
