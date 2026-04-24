defmodule SymphonyElixir.ClaudeCode.RateLimitProbeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.RateLimitProbe

  test "parses anthropic unified rate-limit headers into session + weekly buckets" do
    headers = [
      {"anthropic-ratelimit-unified-5h-status", "allowed"},
      {"anthropic-ratelimit-unified-5h-utilization", "0.1"},
      {"anthropic-ratelimit-unified-5h-reset", "1777032600"},
      {"anthropic-ratelimit-unified-7d-status", "allowed"},
      {"anthropic-ratelimit-unified-7d-utilization", "0.01"},
      {"anthropic-ratelimit-unified-7d-reset", "1777510800"}
    ]

    assert {:ok, rate_limits} = RateLimitProbe.rate_limits_from_response(headers)

    assert rate_limits["limit_id"] == "anthropic_oauth"
    session = rate_limits["session"]
    weekly = rate_limits["weekly"]

    assert session["status"] == "allowed"
    assert session["period"] == "session"
    assert session["limit"] == 100
    assert session["remaining"] == 90
    assert session["usage_percent"] == 10.0
    assert session["utilization"] == 0.1
    assert is_binary(session["reset_at"])

    assert weekly["period"] == "weekly"
    assert weekly["limit"] == 100
    assert weekly["remaining"] == 99
    assert weekly["usage_percent"] == 1.0
  end

  test "marks a bucket as exhausted when Anthropic returns rate_limited status" do
    headers = %{
      "anthropic-ratelimit-unified-5h-status" => "rate_limited",
      "anthropic-ratelimit-unified-5h-utilization" => "1.0",
      "anthropic-ratelimit-unified-5h-reset" => "1777032600"
    }

    assert {:ok, rate_limits} = RateLimitProbe.rate_limits_from_response(headers)
    assert rate_limits["session"]["remaining"] == 0
    assert rate_limits["session"]["status"] == "rate_limited"
    refute Map.has_key?(rate_limits, "weekly")
  end

  test "returns :empty_rate_limit_headers when no unified headers are present" do
    assert {:error, :empty_rate_limit_headers} =
             RateLimitProbe.rate_limits_from_response([{"content-type", "application/json"}])
  end

  test "probe/2 calls the injected request function with OAuth bearer headers" do
    account = fake_claude_account!("probe-headers", "oauth-token-xyz")

    parent = self()

    req_fun = fn payload, headers ->
      send(parent, {:req, payload, headers})

      {:ok,
       %{
         status: 200,
         headers: [
           {"anthropic-ratelimit-unified-5h-status", "allowed"},
           {"anthropic-ratelimit-unified-5h-utilization", "0.42"},
           {"anthropic-ratelimit-unified-5h-reset", "1777032600"}
         ]
       }}
    end

    assert {:ok, rate_limits} = RateLimitProbe.probe(account, req_fun: req_fun)
    assert rate_limits["session"]["remaining"] == 58

    assert_received {:req, payload, headers}
    assert payload["system"] =~ "Claude Code"
    assert payload["model"] == "claude-haiku-4-5"
    assert {"authorization", "Bearer oauth-token-xyz"} in headers
    assert {"anthropic-beta", "oauth-2025-04-20"} in headers
  end

  test "probe/2 reports an error when the oauth token file is empty" do
    account = fake_claude_account!("probe-missing-token", "")

    assert {:error, :missing_claude_oauth_token} = RateLimitProbe.probe(account, req_fun: &unreachable/2)
  end

  test "probe/2 surfaces rate limits even on a 401 response when headers are present" do
    account = fake_claude_account!("probe-401", "oauth-token-xyz")

    req_fun = fn _payload, _headers ->
      {:ok,
       %{
         status: 401,
         body: "{\"error\":\"auth\"}",
         headers: [
           {"anthropic-ratelimit-unified-5h-status", "allowed"},
           {"anthropic-ratelimit-unified-5h-utilization", "0.2"},
           {"anthropic-ratelimit-unified-5h-reset", "1777032600"}
         ]
       }}
    end

    # suppress the Logger warning line
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, rate_limits} = RateLimitProbe.probe(account, req_fun: req_fun)
      assert rate_limits["session"]["remaining"] == 80
    end)
  end

  test "probe/2 returns the underlying transport error" do
    account = fake_claude_account!("probe-transport", "oauth-token-xyz")

    req_fun = fn _payload, _headers -> {:error, :econnrefused} end

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :econnrefused} = RateLimitProbe.probe(account, req_fun: req_fun)
    end)
  end

  defp fake_claude_account!(suffix, token) do
    dir =
      System.tmp_dir!()
      |> Path.join("symphony-elixir-probe-#{suffix}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    token_file = Path.join(dir, "claude_oauth_token")
    File.write!(token_file, token)

    on_exit(fn -> File.rm_rf(dir) end)

    %{
      backend: "claude",
      id: "probe-#{suffix}",
      claude_oauth_token_file: token_file
    }
  end

  defp unreachable(_payload, _headers), do: flunk("request function should not be invoked")
end
