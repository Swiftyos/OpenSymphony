import Config

bootstrap_root = Path.join(System.tmp_dir!(), "symphony-elixir-test-bootstrap")
bootstrap_workflow = Path.join(bootstrap_root, "WORKFLOW.md")

File.mkdir_p!(bootstrap_root)

unless File.exists?(bootstrap_workflow) do
  File.write!(
    bootstrap_workflow,
    """
    ---
    tracker:
      kind: memory
    ---
    Test bootstrap workflow.
    """
  )
end

config :symphony_elixir,
  startup_mode: :legacy,
  workflow_file_path: bootstrap_workflow,
  # Keep test logs out of the checkout and under the per-partition TMPDIR.
  log_file: Path.join(System.tmp_dir!(), "symphony-elixir-test.log")

# Keep the usage ledger in memory during tests; never touch ~/.symphony.
config :symphony_elixir,
  usage_ledger_path: nil,
  agent_inbox_path: nil,
  factory_controls_path: nil,
  secret_key_base_path: nil,
  users_path: nil,
  mcp_tokens_path: nil,
  project_routes_path: nil,
  teams_path: nil,
  # Tests run project status checks explicitly (ProjectRetirement.check/0).
  project_retirement_interval_ms: 0,
  factories_dir: nil,
  # Tests reload the factory store explicitly (Store.reload/0).
  factories_reload_ms: 0,
  sessions_path: nil,
  retries_path: nil,
  runs_path: nil,
  session_history_path: nil,
  # Never trap SIGHUP or stop the VM from tests.
  handle_sighup: false,
  delayed_restart_stop: {Kernel, :send, [:delayed_restart_test_probe, :stopped]},
  # ConnTest requests use host "www.example.com"; the guard is tested explicitly.
  enforce_local_host: false,
  password_iterations: 1_000,
  # Tests sync labels explicitly.
  label_sync_on_boot: false,
  # Tests start the repo cache refresher explicitly when they need it.
  repo_cache_refresher_enabled: false,
  # Tests start their own runner pod watches; the application's must never
  # pick up another test's Kubernetes launcher and Req plug.
  pod_watch_enabled: false,
  # Keep retry/backoff sleeps short; the tests still exercise the retry paths.
  run_host_remote_retry_sleep_ms: 5,
  runner_command_error_backoff_ms: 50,
  workflow_store_poll_interval_ms: 50

# Dashboard pages re-read the orchestrator at once on every update in tests;
# the production spacing (1s) is tested explicitly.
config :symphony_elixir, dashboard_refresh_interval_ms: 0
