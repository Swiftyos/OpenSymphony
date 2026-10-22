defmodule SymphonyElixir.Users.Import do
  @moduledoc """
  Provisions accounts from a CSV of Linear team roles, so people get their
  access the first time they arrive through Google sign-in (IAP).

  The CSV has a header row with these columns, in any order:

      email,linear_team_name,linear_team_id,role

    * `member` or `admin` with a `linear_team_id`: the person works in that team
      (`access`), or administers it (`team_admin`). An email may be on several
      rows with different roles; listed twice for one team, `admin` wins.
    * `global_viewer` with no team: sees every team, changes nothing
      (`SymphonyElixir.Policy`).

  An optional `linear_team_key` column (`PAY`) names a team's key outright.

  Team ids are turned into team keys (`PAY`) by the teams Symphony knows
  (`SymphonyElixir.Teams`), else by looking the ids up in Linear, else by the
  row's `linear_team_key`; the `teams:` option (`%{id => key}`) stands in for
  Linear. A team Symphony didn't know yet is added to `SymphonyElixir.Teams`
  (with its name and workflow states from Linear), so it shows in the
  dashboard and follows the default flow; the report lists them in
  `teams_added`. A team Linear doesn't return for Symphony's Linear API key
  (the key can't see it) and with no `linear_team_key` is a row problem.

  Rules:

    * Accounts are matched by email, ignoring case; missing ones are created
      active, marked `imported_at`, and may sign in even when Linear has no user
      with the email (`SymphonyElixir.Auth`).
    * The CSV is the truth for each (email, team) it lists: `admin` makes the
      person a team admin, `member` makes them a member (and no longer that
      team's admin). Grants for teams it doesn't list are kept.
    * A global admin (the bootstrap account, or the `admin` role) listed as a
      `global_viewer` stays an admin. Nobody is removed or disabled; accounts
      the CSV doesn't list are only reported.
    * Running it again with the same CSV changes nothing.
    * A row with a problem (bad email, unknown role or team) is reported, and
      nothing (accounts or teams) is written unless `skip_invalid: true`.

  Options: `dry_run:` (report only), `teams:`, `skip_invalid:`, `by:` (who to
  record, `"import"` by default).
  """

  require Logger

  alias SymphonyElixir.{Teams, Users}

  @columns ["email", "linear_team_name", "linear_team_id", "role"]
  @optional_columns ["linear_team_key"]
  @team_roles ["member", "admin"]

  @type report :: %{
          dry_run: boolean(),
          written: boolean(),
          rows: non_neg_integer(),
          accounts: non_neg_integer(),
          teams: non_neg_integer(),
          teams_added: [String.t()],
          created: non_neg_integer(),
          updated: non_neg_integer(),
          unchanged: non_neg_integer(),
          admins_kept: non_neg_integer(),
          errors: [%{line: pos_integer(), reason: String.t()}],
          not_in_csv: [String.t()],
          changes: [map()]
        }

  @doc """
  Imports a CSV given as its contents or a path to it. See the moduledoc.
  """
  @spec from_csv(binary(), keyword()) :: {:ok, report()} | {:error, term()}
  def from_csv(path_or_binary, opts \\ []) when is_binary(path_or_binary) do
    with {:ok, body} <- read(path_or_binary),
         {:ok, rows} <- parse(body),
         :ok <- admin_present(),
         {:ok, teams, new_teams} <- team_keys(rows, opts) do
      run(rows, teams, new_teams, opts)
    end
  end

  @doc "The report without emails: counts only, for logs."
  @spec summary(report()) :: map()
  def summary(report) do
    report
    |> Map.take([:dry_run, :written, :rows, :accounts, :teams, :created, :updated, :unchanged, :admins_kept])
    |> Map.merge(%{errors: length(report.errors), not_in_csv: length(report.not_in_csv), teams_added: length(report.teams_added)})
  end

  # Contents have a line break; anything else is a path.
  defp read(input) do
    if String.contains?(input, "\n") do
      {:ok, input}
    else
      case File.read(input) do
        {:ok, body} -> {:ok, body}
        {:error, reason} -> {:error, {:unreadable, reason}}
      end
    end
  end

  # ------------------------------------------------------------------ parsing

  defp parse(body) do
    case body |> String.trim_leading("\uFEFF") |> csv_rows() do
      [header | rows] -> rows_by_column(Enum.map(header, &(&1 |> String.trim() |> String.downcase())), rows)
      [] -> {:error, :empty_csv}
    end
  end

  # Each row as a map of the columns used, with its line number.
  defp rows_by_column(header, rows) do
    case @columns -- header do
      [] ->
        index = Map.new(@columns ++ Enum.filter(@optional_columns, &(&1 in header)), &{&1, Enum.find_index(header, fn name -> name == &1 end)})
        {:ok, for({fields, line} <- Enum.with_index(rows, 2), fields not in [[], [""]], do: row(index, fields, line))}

      missing ->
        {:error, {:missing_columns, missing}}
    end
  end

  defp row(index, fields, line) do
    index
    |> Map.new(fn {column, i} -> {column, String.trim(Enum.at(fields, i, ""))} end)
    |> Map.put("line", line)
  end

  # RFC 4180: comma-separated, fields in double quotes may hold commas, line
  # breaks and doubled quotes.
  defp csv_rows(body), do: body |> String.graphemes() |> csv_rows([], [], "", false)

  defp csv_rows([], rows, fields, field, _quoted), do: Enum.reverse(finish_row(rows, fields, field))
  defp csv_rows(["\"", "\"" | rest], rows, fields, field, true), do: csv_rows(rest, rows, fields, field <> "\"", true)
  defp csv_rows(["\"" | rest], rows, fields, field, true), do: csv_rows(rest, rows, fields, field, false)
  defp csv_rows([char | rest], rows, fields, field, true), do: csv_rows(rest, rows, fields, field <> char, true)
  defp csv_rows(["\"" | rest], rows, fields, "", false), do: csv_rows(rest, rows, fields, "", true)
  defp csv_rows(["," | rest], rows, fields, field, false), do: csv_rows(rest, rows, [field | fields], "", false)
  defp csv_rows([newline | rest], rows, fields, field, false) when newline in ["\n", "\r\n", "\r"], do: csv_rows(rest, finish_row(rows, fields, field), [], "", false)
  defp csv_rows([char | rest], rows, fields, field, false), do: csv_rows(rest, rows, fields, field <> char, false)

  defp finish_row(rows, [], ""), do: rows
  defp finish_row(rows, fields, field), do: [Enum.reverse([field | fields]) | rows]

  # ------------------------------------------------------------------ teams

  # Without a bootstrap or admin-role account, the first person to sign in
  # would no longer become the bootstrap admin once accounts exist.
  defp admin_present do
    if Enum.any?(Users.list(), &(&1.bootstrap_admin or Map.get(&1, :role) == "admin")),
      do: :ok,
      else: {:error, :no_admin_account}
  end

  # Team ids to keys: teams Symphony knows, then Linear (or the `teams:`
  # option), then the CSV's own `linear_team_key`. Teams Symphony didn't know
  # come back to be added.
  defp team_keys(rows, opts) do
    wanted = team_refs(rows)
    known = for {id, _ref} <- wanted, team = Teams.by_id(id), into: %{}, do: {id, team.key}
    unknown = wanted |> Map.keys() |> Enum.reject(&Map.has_key?(known, &1))

    with {:ok, found} <- linear_teams(unknown, opts) do
      new_teams =
        for id <- unknown, team = found[id] || csv_team(id, wanted[id]), is_binary(team.key) do
          Map.update(team, :name, wanted[id].name, &(&1 || wanted[id].name))
        end

      {:ok, Map.merge(known, Map.new(new_teams, &{&1.id, &1.key})), new_teams}
    end
  end

  # Each team id the rows name, with the name and key the CSV gives it.
  defp team_refs(rows) do
    for %{"linear_team_id" => id} = row <- rows, id != "", String.downcase(row["role"]) in @team_roles, reduce: %{} do
      acc ->
        key = row |> Map.get("linear_team_key", "") |> String.trim() |> String.upcase()
        name = if row["linear_team_name"] == "", do: nil, else: row["linear_team_name"]

        Map.update(acc, id, %{name: name, key: if(key == "", do: nil, else: key)}, fn ref ->
          %{name: ref.name || name, key: ref.key || if(key == "", do: nil, else: key)}
        end)
    end
  end

  defp csv_team(id, %{key: key} = ref) when is_binary(key) do
    if Regex.match?(~r/^[A-Z0-9][A-Z0-9_-]{0,15}$/, key), do: %{id: id, key: key, name: ref.name, states: []}
  end

  defp csv_team(_id, _ref), do: nil

  defp linear_teams([], _opts), do: {:ok, %{}}

  defp linear_teams(ids, opts) do
    case Keyword.get(opts, :teams) do
      %{} = given ->
        {:ok, for({id, key} <- given, id in ids, into: %{}, do: {id, %{id: id, key: key, name: nil, states: []}})}

      nil ->
        case Teams.lookup(ids, []) do
          {:ok, found, _missing} -> {:ok, Map.new(found, &{&1.id, &1})}
          # Without Linear, only the CSV's keys can name teams.
          {:error, :linear_not_configured} -> {:ok, %{}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ------------------------------------------------------------------ plan

  defp run(rows, teams, new_teams, opts) do
    {wanted, errors} = Enum.reduce(rows, {%{}, []}, &collect(&1, &2, teams))
    errors = Enum.reverse(errors)
    accounts = Users.list()
    plans = for {email, want} <- Enum.sort(wanted), do: plan(email, want, Enum.find(accounts, &(&1.email == email)))
    changed = Enum.reject(plans, &(&1.action == :unchanged))
    dry_run? = Keyword.get(opts, :dry_run, false)
    valid? = errors == [] or Keyword.get(opts, :skip_invalid, false)
    write? = not dry_run? and changed != [] and valid?

    # Teams first: the accounts' grants name them.
    if not dry_run? and valid? and new_teams != [] do
      {:ok, _teams} = Teams.register(new_teams, Keyword.get(opts, :by, "import"))
    end

    if write? do
      {:ok, _accounts} = Users.provision(Enum.map(changed, &{&1.email, &1.attrs}), Keyword.get(opts, :by, "import"))
    end

    report = %{
      dry_run: dry_run?,
      written: write?,
      rows: length(rows),
      accounts: map_size(wanted),
      teams: wanted |> Map.values() |> Enum.flat_map(&Map.keys(&1.teams)) |> Enum.uniq() |> length(),
      teams_added: new_teams |> Enum.map(& &1.key) |> Enum.sort(),
      created: Enum.count(plans, &(&1.action == :created)),
      updated: Enum.count(plans, &(&1.action == :updated)),
      unchanged: Enum.count(plans, &(&1.action == :unchanged)),
      admins_kept: Enum.count(plans, & &1.admin_kept),
      errors: errors,
      not_in_csv: accounts |> Enum.map(& &1.email) |> Enum.reject(&Map.has_key?(wanted, &1)) |> Enum.sort(),
      changes: Enum.map(changed, &Map.drop(&1, [:attrs, :admin_kept]))
    }

    Logger.info("Accounts import #{inspect(summary(report))}")
    {:ok, report}
  end

  defp collect(%{"line" => line} = row, {wanted, errors}, teams) do
    email = String.downcase(row["email"])
    role = String.downcase(row["role"])
    team_id = row["linear_team_id"]

    cond do
      not Regex.match?(~r/^[^@\s,]+@[^@\s,]+\.[^@\s,]+$/, email) ->
        {wanted, [%{line: line, reason: "invalid email"} | errors]}

      role == "global_viewer" ->
        {Map.update(wanted, email, %{global_viewer: true, teams: %{}}, &%{&1 | global_viewer: true}), errors}

      role not in @team_roles ->
        {wanted, [%{line: line, reason: "unknown role #{inspect(row["role"])}"} | errors]}

      team_id == "" ->
        {wanted, [%{line: line, reason: "#{role} needs a linear_team_id"} | errors]}

      not is_binary(teams[team_id]) ->
        reason =
          "unknown Linear team id #{team_id}: Symphony's Linear API key can't see that team; " <>
            "give the key access to it, or add the team's key in a linear_team_key column"

        {wanted, [%{line: line, reason: reason} | errors]}

      true ->
        want = Map.get(wanted, email, %{global_viewer: false, teams: %{}})
        team_role = higher_role(want.teams[teams[team_id]], String.to_existing_atom(role))
        {Map.put(wanted, email, put_in(want, [:teams, teams[team_id]], team_role)), errors}
    end
  end

  # Listed as admin and as member of one team: admin.
  defp higher_role(:admin, _role), do: :admin
  defp higher_role(_current, role), do: role

  defp plan(email, want, account) do
    current = account || %{team_admin: [], access: [], role: nil, bootstrap_admin: false}
    admin_teams = for {key, :admin} <- want.teams, do: key
    member_teams = for {key, :member} <- want.teams, do: key
    team_admin = Enum.sort(Enum.uniq(current.team_admin ++ admin_teams) -- member_teams)
    access = Enum.sort(Enum.uniq(current.access ++ member_teams))
    admin? = current.bootstrap_admin or current.role == "admin"
    role = if want.global_viewer and not admin?, do: "global_viewer", else: current.role

    action = plan_action(account, {team_admin, access, role}, {Enum.sort(current.team_admin), Enum.sort(current.access), current.role})

    %{
      email: email,
      action: action,
      role: role,
      team_admin_added: team_admin -- current.team_admin,
      team_admin_removed: current.team_admin -- team_admin,
      access_added: access -- current.access,
      admin_kept: want.global_viewer and admin?,
      attrs: %{role: role, team_admin: team_admin, access: access}
    }
  end

  defp plan_action(nil, _wanted, _current), do: :created
  defp plan_action(_account, same, same), do: :unchanged
  defp plan_action(_account, _wanted, _current), do: :updated
end
