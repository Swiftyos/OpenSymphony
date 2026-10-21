# Tests tagged :postgres need a database: SYMPHONY_TEST_DATABASE_URL=ecto://postgres@localhost/symphony_test
# Give every git process in the suite an identity without an extra config
# command per temporary repository.
System.put_env("GIT_AUTHOR_NAME", "Test User")
System.put_env("GIT_AUTHOR_EMAIL", "test@example.com")
System.put_env("GIT_COMMITTER_NAME", "Test User")
System.put_env("GIT_COMMITTER_EMAIL", "test@example.com")

exclude = if System.get_env("SYMPHONY_TEST_DATABASE_URL"), do: [], else: [:postgres]
ExUnit.start(exclude: exclude)
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/runner_support.exs", __DIR__)
