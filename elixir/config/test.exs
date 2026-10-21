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
  workflow_file_path: bootstrap_workflow

# Keep the usage ledger in memory during tests; never touch ~/.symphony.
config :symphony_elixir,
  usage_ledger_path: nil,
  agent_inbox_path: nil,
  factory_controls_path: nil,
  secret_key_base_path: nil,
  users_path: nil,
  factories_dir: nil,
  # Tests reload the factory store explicitly (Store.reload/0).
  factories_reload_ms: 0,
  sessions_path: nil,
  retries_path: nil,
  # Never trap SIGHUP or stop the VM from tests.
  handle_sighup: false,
  delayed_restart_stop: {Kernel, :send, [:delayed_restart_test_probe, :stopped]},
  # ConnTest requests use host "www.example.com"; the guard is tested explicitly.
  enforce_local_host: false,
  password_iterations: 1_000,
  # Tests sync labels explicitly.
  label_sync_on_boot: false
