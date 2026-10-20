defmodule SymphonyElixir.FactoryEditorTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Auth, FactoryControls, IssueStage, Tracker, UsageLedger, Users}
  alias SymphonyElixir.Factory.{Definition, StagePrompt, Store}
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixirWeb.FactoryPresenter

  @endpoint SymphonyElixirWeb.Endpoint
  @password "correct horse battery"

  defmodule LabelLinear do
    def graphql(query, variables, _opts \\ []) do
      send(Application.get_env(:symphony_elixir, :fake_linear_recipient), {:graphql, query, variables})

      cond do
        query =~ "SymphonyStageLabels" ->
          Process.get(:inventory) || {:ok, Application.get_env(:symphony_elixir, :fake_inventory)}

        query =~ "SymphonyCreateLabel" ->
          Application.get_env(:symphony_elixir, :fake_create, {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => %{"id" => "new-" <> variables.input.name}}}}})

        query =~ "SymphonyMemberByEmail" ->
          member(variables.email)

        query =~ "SymphonyStageLookup" ->
          {:ok, %{"data" => stage_lookup()}}

        query =~ "SymphonySetStage" ->
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

        query =~ "SymphonyCreateComment" ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      end
    end

    def fetch_issue_states_by_ids(ids) do
      {:ok,
       for id <- ids, String.starts_with?(id, "id-") do
         identifier = String.replace_prefix(id, "id-", "")
         labels = if identifier == "PAY-2", do: ["factory/merge"], else: []
         state = if identifier == "PAY-2", do: "In Progress", else: "In Review"

         %SymphonyElixir.Linear.Issue{
           id: id,
           identifier: identifier,
           title: "T",
           state: state,
           labels: labels,
           project_slug: "project"
         }
       end}
    end

    defp member("mia@acme.test"), do: users("Mia", false, ["PAY"])
    defp member("ada@acme.test"), do: users("Ada", true, [])
    defp member(_email), do: {:ok, %{"data" => %{"users" => %{"nodes" => []}}}}

    defp users(name, admin, teams) do
      nodes = Enum.map(teams, &%{"id" => "t-" <> &1, "key" => &1, "name" => &1 <> " team"})

      user = %{
        "id" => "u-" <> name,
        "displayName" => name,
        "admin" => admin,
        "guest" => false,
        "active" => true,
        "teams" => %{"nodes" => nodes}
      }

      {:ok, %{"data" => %{"users" => %{"nodes" => [user]}}}}
    end

    defp stage_lookup do
      %{
        "issue" => %{"team" => %{"id" => "t-PAY", "states" => %{"nodes" => [%{"id" => "s"}]}}, "labels" => %{"nodes" => []}},
        "issueLabels" => %{"nodes" => [%{"id" => "l", "team" => %{"id" => "t-PAY"}}]}
      }
    end
  end

  defmodule StubOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      totals = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      {:reply, %{running: [], retrying: [], agent_totals: totals, rate_limits: nil}, state}
    end

    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true}, state}
  end

  setup do
    Store.reset()
    Users.reset()
    UsageLedger.reset()
    Auth.clear_cache()
    keys = [:linear_client_module, :fake_linear_recipient, :fake_inventory, :fake_create]
    saved = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    Application.put_env(:symphony_elixir, :linear_client_module, LabelLinear)
    Application.put_env(:symphony_elixir, :fake_linear_recipient, self())

    on_exit(fn ->
      Store.reset()
      Users.reset()
      UsageLedger.reset()
      Auth.clear_cache()

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: "server-key")
    :ok
  end

  defp inventory(nodes, team_id \\ "t-PAY") do
    Application.put_env(:symphony_elixir, :fake_inventory, %{
      "data" => %{"teams" => %{"nodes" => if(team_id, do: [%{"id" => team_id}], else: [])}, "issueLabels" => %{"nodes" => nodes}}
    })
  end

  describe "label sync" do
    test "creates the stage group and missing stage labels for the team" do
      inventory([%{"id" => "x", "name" => "merge", "isGroup" => false, "team" => nil, "parent" => %{"id" => "other"}}])

      assert {:ok, ["factory", "factory/merge", "factory/qa"]} = Adapter.ensure_stage_labels("PAY", ["merge", "QA", "qa"])
      assert_received {:graphql, _, %{input: %{name: "factory", isGroup: true, teamId: "t-PAY"}}}
      assert_received {:graphql, _, %{input: %{name: "merge", parentId: "new-factory", teamId: "t-PAY"}}}
    end

    test "reuses the team's group, else a workspace-wide one, and skips labels that exist" do
      group = %{"id" => "g-team", "name" => "Factory", "isGroup" => true, "team" => %{"id" => "t-PAY"}, "parent" => nil}
      workspace = %{"id" => "g-ws", "name" => "factory", "isGroup" => true, "team" => nil, "parent" => nil}
      existing = %{"id" => "l1", "name" => "Merge", "isGroup" => false, "team" => %{"id" => "t-PAY"}, "parent" => %{"id" => "g-team"}}

      inventory([workspace, group, existing])
      assert {:ok, ["factory/qa"]} = Adapter.ensure_stage_labels("PAY", ["merge", "qa"])

      inventory([workspace])
      assert {:ok, ["factory/merge"]} = Adapter.ensure_stage_labels("PAY", ["merge"])
      assert_received {:graphql, _, %{input: %{name: "merge", parentId: "g-ws"}}}
    end

    test "reports unknown teams and failed creates" do
      inventory([], nil)
      assert {:error, :team_not_found} = Adapter.ensure_stage_labels("NOPE", ["merge"])

      inventory([])
      Application.put_env(:symphony_elixir, :fake_create, {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => false}}}})
      assert {:error, {:label_create_failed, "factory"}} = Adapter.ensure_stage_labels("PAY", ["merge"])

      group = %{"id" => "g", "name" => "factory", "isGroup" => true, "team" => %{"id" => "t-PAY"}, "parent" => nil}
      inventory([group])
      Application.put_env(:symphony_elixir, :fake_create, {:error, :boom})
      assert {:error, :boom} = Adapter.ensure_stage_labels("PAY", ["merge"])
    end

    test "the memory tracker records the request" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      assert {:ok, []} = Tracker.ensure_stage_labels("PAY", ["qa"])
      assert_received {:memory_tracker_ensure_labels, "PAY", ["qa"]}
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end
  end

  describe "definition details" do
    test "skills are stored at the stage's own path and reach the prompt" do
      definition = Definition.default_template()
      stages = Enum.map(definition["stages"], &if(&1["id"] == "merge", do: Map.put(&1, "skill", %{"path" => "/etc/x", "content" => "Use the merge queue."}), else: &1))
      {:ok, _} = Store.put("PAY", %{definition | "stages" => stages}, 0, "mia")

      assert Definition.stage(Store.get("PAY"), "merge")["skill"] == %{"path" => ".codex/skills/merge/SKILL.md", "content" => "Use the merge queue."}
      issue = %Issue{id: "i", identifier: "PAY-1", state: "In Progress", labels: ["factory/merge"]}
      assert StagePrompt.render(issue) =~ "### Skill for this stage (.codex/skills/merge/SKILL.md)\n\nUse the merge queue."
    end

    test "custom teams add their dispatch states to polling, and controls list agent stages" do
      definition = Definition.default_template()
      qa = %{"id" => "qa", "name" => "QA", "kind" => "agent", "linear_state" => "QA", "label" => nil}
      {:ok, _} = Store.put("PAY", %{definition | "stages" => definition["stages"] ++ [qa]}, 0, "mia")

      assert "QA" in IssueStage.active_state_names()
      assert Map.keys(FactoryControls.all("PAY")) |> Enum.sort() == ["implement", "merge", "qa", "rework", "todo"]
      # No team: the organisation default flow.
      assert Map.keys(FactoryControls.all()) |> Enum.sort() == ["implement", "merge", "rework", "todo"]
    end

    test "guests and signed-out users can't edit any flow" do
      guest = %Auth.User{id: "g", name: "g", guest: true, teams: [%{id: "t", key: "PAY", name: "P"}]}
      refute Auth.can_edit_factory?(guest, "PAY")
      refute Auth.can_edit_factory?(nil, "PAY")
      refute Auth.can_edit_factory?(%Auth.User{id: "m", name: "m", teams: []}, nil)
    end

    test "the presenter shows the default flow when no team has work or a flow yet" do
      payload = FactoryPresenter.payload([], Config.settings!())
      assert payload.teams == [%{key: "DEFAULT", name: "Default flow", custom: false}]
      assert payload.definitions["DEFAULT"]["stages"] |> length() == 7
    end
  end

  describe "editor events" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        server_host: "0.0.0.0",
        tracker_kind: "linear",
        tracker_api_token: "server-key",
        agent_backend: "claude"
      )

      name = Module.concat(__MODULE__, :Orchestrator)
      {:ok, _pid} = StubOrchestrator.start_link(name: name)

      config =
        :symphony_elixir
        |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
        |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: name, snapshot_timeout_ms: 200)

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
      start_supervised!({SymphonyElixirWeb.Endpoint, []})

      ada_params = %{"username" => "ada", "email" => "ada@acme.test", "password" => @password, "setup_code" => Users.setup_code()}
      {:ok, ada} = Users.register(ada_params, &Auth.check_linear_member/1)
      mia_params = %{"username" => "mia", "email" => "mia@acme.test", "password" => @password}
      {:ok, mia} = Users.register(mia_params, &Auth.check_linear_member/1)
      {:ok, mia} = Users.approve(mia.id, "ada")
      inventory([])
      %{ada: ada, mia: mia}
    end

    defp session_for(account),
      do: build_conn() |> Plug.Test.init_test_session(%{"user_id" => account.id, "session_version" => Users.get(account.id).session_version})

    test "members save their own team's flow; conflicts and invalid flows are reported", %{mia: mia} do
      {:ok, view, html} = live(session_for(mia), "/")
      assert html =~ "factory_flow.js?v="

      draft = Store.get("PAY") |> Map.update!("stages", &(&1 ++ [%{"id" => "qa", "name" => "QA", "kind" => "agent", "linear_state" => "In Progress", "label" => "qa"}]))
      render_hook(view, "factory_save", %{"team" => "PAY", "version" => 0, "definition" => draft})
      assert_reply(view, %{ok: true, definition: %{"version" => 1, "updated_by" => "mia"}})

      # Labels are synced to Linear in the background.
      assert_receive {:graphql, _, %{input: %{name: "qa", parentId: "new-factory"}}}, 1_000

      render_hook(view, "factory_save", %{"team" => "PAY", "version" => 0, "definition" => draft})
      assert_reply(view, %{ok: false, conflict: %{"version" => 1}})

      render_hook(view, "factory_save", %{"team" => "PAY", "version" => 1, "definition" => %{"stages" => []}})
      assert_reply(view, %{ok: false, errors: ["a factory needs at least one stage"]})

      render_hook(view, "factory_save", %{"team" => "WEB", "version" => 0, "definition" => draft})
      assert_reply(view, %{ok: false, errors: ["Only this team's members and Linear admins can change its flow."]})

      render_hook(view, "factory_save", %{"team" => "../x", "version" => 0, "definition" => draft})
      assert_reply(view, %{ok: false, errors: [_]})
    end

    test "moves follow the team's connections; agent-only moves need an admin", %{mia: mia, ada: ada} do
      {:ok, view, _html} = live(session_for(mia), "/")

      # PAY-1 is In Review: review -> merge is a person move.
      render_hook(view, "factory_move", %{"id" => "id-PAY-1", "to" => "merge"})
      assert_reply(view, %{ok: true})

      render_hook(view, "factory_move", %{"id" => "id-PAY-1", "to" => "done"})
      assert_reply(view, %{ok: false, error: "That move isn't a connection in this team's flow."})

      render_hook(view, "factory_move", %{"id" => "id-PAY-1", "to" => "nowhere"})
      assert_reply(view, %{ok: false, error: "That stage isn't in this team's flow."})

      # PAY-2 is in Merge: merge -> done is an agent move.
      render_hook(view, "factory_move", %{"id" => "id-PAY-2", "to" => "done"})
      assert_reply(view, %{ok: false, error: "Agents make that move. Only admins can force it."})

      {:ok, admin_view, _html} = live(session_for(ada), "/")
      render_hook(admin_view, "factory_move", %{"id" => "id-PAY-2", "to" => "done"})
      assert_reply(admin_view, %{ok: true})
    end

    test "members change their own team's stage controls", %{mia: mia} do
      {:ok, view, _html} = live(session_for(mia), "/")
      render_hook(view, "factory_control", %{"team" => "PAY", "stage" => "merge", "field" => "max_agents", "value" => 2})
      assert_reply(view, %{ok: true, controls: %{max_agents: 2}})
      assert FactoryControls.get({"PAY", "merge"}).max_agents == 2
      assert Store.custom?("PAY")
    end

    test "AI drafts run in the background and are pushed when ready", %{mia: mia} do
      bin = Path.join(System.tmp_dir!(), "symphony-editor-bin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin)
      draft = Jason.encode!(%{"instructions" => "Do QA.", "transitions" => [], "skill" => nil})
      File.write!(Path.join(bin, "claude"), "#!/bin/sh\nprintf '%s' '#{draft}'\n")
      File.chmod!(Path.join(bin, "claude"), 0o755)
      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)

      try do
        {:ok, view, _html} = live(session_for(mia), "/")
        render_hook(view, "factory_assist", %{"team" => "PAY", "stage" => "merge", "request" => "Use a merge queue.", "definition" => Store.get("PAY")})
        assert_reply(view, %{ok: true, pending: true, ref: ref})
        assert_push_event(view, "factory_assist_result", %{ref: ^ref, ok: true, suggestion: %{instructions: "Do QA."}}, 5_000)

        render_hook(view, "factory_assist", %{"team" => "PAY", "stage" => "merge", "request" => "", "definition" => %{"bad" => true}})
        assert_reply(view, %{ok: true, ref: ref2})
        assert_push_event(view, "factory_assist_result", %{ref: ^ref2, ok: false, error: "Describe what the stage should do."}, 5_000)

        render_hook(view, "factory_assist", %{"team" => "WEB", "stage" => "merge", "request" => "x"})
        assert_reply(view, %{ok: false, error: "Only this team's members" <> _})
      after
        System.put_env("PATH", path)
        File.rm_rf!(bin)
      end
    end
  end
end
