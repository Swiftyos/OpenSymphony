# Tests tagged :postgres need a database: SYMPHONY_TEST_DATABASE_URL=ecto://postgres@localhost/symphony_test
exclude = if System.get_env("SYMPHONY_TEST_DATABASE_URL"), do: [], else: [:postgres]
ExUnit.start(exclude: exclude)
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/runner_support.exs", __DIR__)
