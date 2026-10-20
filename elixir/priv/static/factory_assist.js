// "Draft with AI" for the factory editor.
//
// The person describes what a stage should do; the server asks the configured
// harness CLI (claude -p / codex exec) to draft the stage's agent instructions,
// suggested connections, and an optional skill file. Nothing is applied until
// the person reviews the preview and clicks Apply.
//
// window.SymphonyAssist.forPanel(panel) -> function(team, draft, stage, apply)
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

  window.SymphonyAssist = {
    forPanel: function (panel) {
      return function (team, draft, stage, apply) {
        open(panel, team, draft, stage, apply);
      };
    }
  };
})();
