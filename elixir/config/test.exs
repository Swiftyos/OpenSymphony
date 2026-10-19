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
config :symphony_elixir, usage_ledger_path: nil, factory_controls_path: nil, secret_key_base_path: nil
