// "Draft with AI" for the factory editor.
//
// The person describes what a stage should do; the server asks the configured
// harness CLI (claude -p / codex exec) to draft the stage's agent instructions,
// suggested connections, and an optional skill file. Nothing is applied until
// the person reviews the preview and clicks Apply.
//
// window.SymphonyAssist.forPanel(panel) -> function(team, draft, stage, apply)
// window.SymphonyAssist.flowForPanel(panel) -> function(scope, label, draft, apply)
(function () {
  "use strict";

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function button(label, cls, onClick) {
    var b = el("button", cls, label);
    b.type = "button";
    b.addEventListener("click", onClick);
    return b;
  }

  function open(panel, team, draft, stage, apply) {
    var dialog = el("div", "fx-assist");
    dialog.setAttribute("role", "dialog");
    dialog.setAttribute("aria-label", "Draft stage with AI");

    var head = el("div", "fx-drawer-head");
    var title = el("div");
    title.appendChild(el("h3", "fx-drawer-title", "✦ Draft “" + (stage.name || "stage") + "” with AI"));
    title.appendChild(
      el("p", "fx-drawer-copy", "Describe what should happen in this stage. Symphony asks your agent harness to draft the instructions and connections, and you review them before anything changes.")
    );
    head.appendChild(title);
    dialog.appendChild(head);

    var request = el("textarea", "fx-textarea");
    request.rows = 4;
    request.placeholder = "e.g. Before review, run the Playwright e2e suite against the PR's preview deploy. Send it back to implement if anything fails.";
    request.value = stage._assistRequest || "";
    dialog.appendChild(request);

    var skill = el("label", "fx-check");
    var skillBox = el("input");
    skillBox.type = "checkbox";
    skillBox.checked = true;
    skill.appendChild(skillBox);
    skill.appendChild(document.createTextNode(" Also draft a skill file agents can follow"));
    dialog.appendChild(skill);

    var status = el("p", "fx-drawer-copy");
    var preview = el("div", "fx-assist-preview");
    var actions = el("div", "fx-issue-actions");
    dialog.appendChild(status);
    dialog.appendChild(preview);
    dialog.appendChild(actions);

    var close = function () {
      dialog.remove();
    };

    var draftIt = function () {
      var text = request.value.trim();
      if (!text) {
        request.focus();
        return;
      }
      stage._assistRequest = text;
      status.textContent = "Drafting… this runs your agent harness and can take a minute.";
      preview.textContent = "";
      actions.textContent = "";
      actions.appendChild(button("Cancel", "fx-action", close));

      panel.push(
        "factory_assist",
        { team: team, stage: stage.id, request: text, skill: skillBox.checked, definition: draft },
        function (reply) {
          var finish = function (result) {
            actions.textContent = "";
            if (!result || !result.ok) {
              status.textContent = (result && result.error) || "The assistant couldn't draft this stage.";
              actions.appendChild(button("Try again", "fx-action is-primary", draftIt));
              actions.appendChild(button("Close", "fx-action", close));
              return;
            }
            renderPreview(result.suggestion);
          };
          // The server answers at once and pushes the draft when the harness finishes.
          if (reply && reply.ok && reply.pending) panel.waitFor("factory_assist_result", reply.ref, finish);
          else finish(reply);
        }
      );
    };

    var renderPreview = function (s) {
      status.textContent = "Review the draft. Apply puts it in the editor; you still need to Save.";
      preview.textContent = "";

      preview.appendChild(el("h4", "fx-assist-h", "Agent instructions"));
      preview.appendChild(el("pre", "fx-assist-text", s.instructions || "(none)"));

      if (s.transitions && s.transitions.length) {
        preview.appendChild(el("h4", "fx-assist-h", "Connections"));
        var list = el("ul", "fx-assist-list");
        s.transitions.forEach(function (t) {
          list.appendChild(el("li", null, t.from + " → " + t.to + " (" + (t.by === "human" ? "person" : "agent") + ")" + (t.criteria ? ": " + t.criteria : "")));
        });
        preview.appendChild(list);
      }

      if (s.skill && s.skill.content) {
        preview.appendChild(el("h4", "fx-assist-h", "Skill · " + s.skill.path));
        preview.appendChild(el("pre", "fx-assist-text", s.skill.content));
        preview.appendChild(el("p", "fx-field-hint", "Saved with the factory and added to the agent's prompt for this stage."));
      }

      actions.appendChild(
        button("Apply", "fx-action is-primary", function () {
          apply(s);
          close();
        })
      );
      actions.appendChild(button("Redraft", "fx-action", draftIt));
      actions.appendChild(button("Discard", "fx-action", close));
    };

    actions.appendChild(button("Draft", "fx-action is-primary", draftIt));
    actions.appendChild(button("Cancel", "fx-action", close));

    // Shown inside the stage drawer, above the form.
    var drawer = document.querySelector(".fx-drawer:not([hidden])");
    (drawer || document.body).insertBefore(dialog, drawer ? drawer.children[1] || null : null);
    request.focus();
  }

  var KIND_LABEL = { queue: "Queue", agent: "Agent", human: "Person", parked: "Parked", done: "Done" };

  // Whole-flow drafting: describe the process, get a complete flow (stages,
  // connections, instructions, skills) to review before it replaces the draft.
  function openFlow(panel, scope, scopeLabel, draft, apply) {
    var existing = document.querySelector(".fx-assist-modal");
    if (existing) existing.remove();

    var modal = el("div", "fx-assist-modal");
    var dialog = el("div", "fx-assist fx-assist-flow");
    dialog.setAttribute("role", "dialog");
    dialog.setAttribute("aria-modal", "true");
    dialog.setAttribute("aria-label", "Design the flow with AI");
    modal.appendChild(dialog);

    var head = el("div", "fx-drawer-head");
    var title = el("div");
    title.appendChild(el("h3", "fx-drawer-title", "✦ Design the " + scopeLabel + " flow with AI"));
    title.appendChild(
      el("p", "fx-drawer-copy", "Describe how work should move through this factory: the stages, who checks what, and what happens when something fails. Your agent harness drafts the whole flow, including stage instructions and skills. You review it before it replaces the draft in the editor.")
    );
    head.appendChild(title);
    dialog.appendChild(head);

    var request = el("textarea", "fx-textarea");
    request.rows = 6;
    request.placeholder =
      "e.g. Agents implement and open a PR. A second agent reviews the diff for security issues and sends it back if it finds any. Then QA runs Playwright against the preview deploy. A person approves, an agent merges. Anything blocked waits for a person.";
    request.value = draft && draft._flowRequest ? draft._flowRequest : "";
    dialog.appendChild(request);

    var skill = el("label", "fx-check");
    var skillBox = el("input");
    skillBox.type = "checkbox";
    skillBox.checked = true;
    skill.appendChild(skillBox);
    skill.appendChild(document.createTextNode(" Also write skill files for agent stages"));
    dialog.appendChild(skill);

    var status = el("p", "fx-drawer-copy");
    var preview = el("div", "fx-assist-preview");
    var actions = el("div", "fx-issue-actions");
    dialog.appendChild(status);
    dialog.appendChild(preview);
    dialog.appendChild(actions);

    var busy = false;
    var close = function () {
      modal.remove();
      document.removeEventListener("keydown", onKey);
    };
    var onKey = function (e) {
      if (e.key === "Escape" && !busy) close();
    };
    document.addEventListener("keydown", onKey);
    modal.addEventListener("click", function (e) {
      if (e.target === modal && !busy) close();
    });

    var draftIt = function () {
      var text = request.value.trim();
      if (!text) {
        request.focus();
        return;
      }
      if (draft) draft._flowRequest = text;
      busy = true;
      status.textContent = "Designing… your agent harness is writing the whole flow. This usually takes one to three minutes.";
      status.classList.add("is-working");
      preview.textContent = "";
      actions.textContent = "";
      actions.appendChild(button("Close", "fx-action", function () {
        busy = false;
        close();
      }));

      panel.push("factory_assist_flow", { team: scope, request: text, skills: skillBox.checked, definition: draft }, function (reply) {
        var finish = function (result) {
          busy = false;
          status.classList.remove("is-working");
          actions.textContent = "";
          if (!result || !result.ok) {
            status.textContent = (result && result.error) || "The assistant couldn't design this flow.";
            actions.appendChild(button("Try again", "fx-action is-primary", draftIt));
            actions.appendChild(button("Close", "fx-action", close));
            return;
          }
          renderPreview(result.suggestion);
        };
        if (reply && reply.ok && reply.pending) panel.waitFor("factory_assist_result", reply.ref, finish);
        else finish(reply);
      });
    };

    var renderPreview = function (s) {
      var d = s.definition;
      status.textContent = "Review the design. Apply replaces the editor's draft; nothing changes until you Save.";
      preview.textContent = "";
      if (s.summary) preview.appendChild(el("p", "fx-assist-summary", s.summary));

      var changes = s.changes || {};
      var chips = el("div", "fx-assist-changes");
      [["added", "Added"], ["changed", "Changed"], ["removed", "Removed"]].forEach(function (pair) {
        (changes[pair[0]] || []).forEach(function (name) {
          chips.appendChild(el("span", "fx-change fx-change-" + pair[0], pair[1] + " · " + name));
        });
      });
      if (chips.children.length) preview.appendChild(chips);

      preview.appendChild(el("h4", "fx-assist-h", "Stages (" + d.stages.length + ")"));
      var stages = el("div", "fx-assist-stages");
      d.stages.forEach(function (st) {
        var item = el("details", "fx-assist-stage");
        var summary = el("summary");
        summary.appendChild(el("span", "fx-kind fx-kind-" + st.kind, KIND_LABEL[st.kind] || st.kind));
        summary.appendChild(el("strong", null, st.name));
        summary.appendChild(el("span", "fx-assist-where", st.linear_state + (st.label ? " · " + st.label : "")));
        if (st.skill) summary.appendChild(el("span", "fx-assist-skill", "skill"));
        item.appendChild(summary);
        if (st.instructions) item.appendChild(el("pre", "fx-assist-text", st.instructions));
        if (st.skill && st.skill.content) {
          item.appendChild(el("h4", "fx-assist-h", "Skill · " + st.skill.path));
          item.appendChild(el("pre", "fx-assist-text", st.skill.content));
        }
        stages.appendChild(item);
      });
      preview.appendChild(stages);

      var names = {};
      d.stages.forEach(function (st) {
        names[st.id] = st.name;
      });
      preview.appendChild(el("h4", "fx-assist-h", "Connections (" + d.transitions.length + ")"));
      var list = el("ul", "fx-assist-list");
      d.transitions.forEach(function (t) {
        list.appendChild(el("li", null, names[t.from] + " → " + names[t.to] + " (" + (t.by === "human" ? "person" : "agent") + ")" + (t.criteria ? ": " + t.criteria : "")));
      });
      preview.appendChild(list);

      actions.appendChild(
        button("Apply to editor", "fx-action is-primary", function () {
          apply(s);
          close();
        })
      );
      actions.appendChild(button("Redraft", "fx-action", draftIt));
      actions.appendChild(button("Discard", "fx-action", close));
    };

    actions.appendChild(button("Design flow", "fx-action is-primary", draftIt));
    actions.appendChild(button("Cancel", "fx-action", close));

    document.body.appendChild(modal);
    request.focus();
  }

  window.SymphonyAssist = {
    forPanel: function (panel) {
      return function (team, draft, stage, apply) {
        open(panel, team, draft, stage, apply);
      };
    },
    flowForPanel: function (panel) {
      return function (scope, scopeLabel, draft, apply) {
        openFlow(panel, scope, scopeLabel, draft, apply);
      };
    }
  };
})();
