# Creates the per-partition Postgres databases the parallel test runner uses.
# Called with the partition count; SYMPHONY_TEST_DATABASE_URL holds the base URL.
count =
  case System.argv() do
    [count | _] -> String.to_integer(count)
    _ -> 1
  end

base_url = System.fetch_env!("SYMPHONY_TEST_DATABASE_URL")

partition_url = fn n ->
  uri = URI.parse(base_url)
  %{uri | path: "#{uri.path}_p#{n}"} |> URI.to_string()
end

{:ok, _} = Application.ensure_all_started(:postgrex)

ensure_database! = fn url ->
  uri = URI.parse(url)
  database = String.trim_leading(uri.path || "", "/")
  admin_url = %{uri | path: "/postgres"}

  {user, password} =
    case String.split(admin_url.userinfo || "", ":", parts: 2) do
      [user, password] -> {user, password}
      [user] -> {user, ""}
      [] -> {"postgres", ""}
    end

  opts = [
    hostname: admin_url.host || "localhost",
    port: admin_url.port || 5432,
    username: URI.decode(user),
    password: URI.decode(password),
    database: "postgres",
    sync_connect: true
  ]

  {:ok, conn} = Postgrex.start_link(opts)

  try do
    %{rows: rows} =
      Postgrex.query!(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [database])

    if rows == [] do
      quoted = ~s(") <> String.replace(database, ~s("), ~s("")) <> ~s(")
      Postgrex.query!(conn, "CREATE DATABASE #{quoted}", [])
      IO.puts("created #{database}")
    end
  after
    GenServer.stop(conn)
  end
end

Enum.each(1..count, fn n -> ensure_database!.(partition_url.(n)) end)
