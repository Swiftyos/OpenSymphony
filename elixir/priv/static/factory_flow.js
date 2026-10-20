// Agent factory flow: per-team process diagram, stage drawer, and editor.
//
// Data-driven from each team's factory definition (stages with positions and
// transitions). Connections are routed orthogonally: they leave and enter on the
// sides that face each other, turn at right angles with rounded corners, share
// a side through evenly spaced ports, and loops travel in their own lanes so
// lines never sit on top of each other.
//
// window.SymphonyFlow.create(opts) -> flow
//   opts: { slot, drawerSlot, tip: {show, move, hide}, push(event, payload, cb),
//           toast(msg, tone), onFilter(stageId|null, label) }
(function () {
  "use strict";

  var SVG_NS = "http://www.w3.org/2000/svg";
  var NODE_W = 148;
  var NODE_H = 72;
  var GRID = 20;
  var RADIUS = 10;
  var LANE_GAP = 18;
  var KINDS = ["queue", "agent", "human", "parked", "done"];
  var KIND_LABEL = { queue: "Queue", agent: "Agent", human: "Human", parked: "Parked", done: "Done" };
  var KIND_HELP = {
    queue: "Waiting for an agent to pick it up.",
    agent: "An agent works issues in this stage.",
    human: "Waiting on a person.",
    parked: "On hold. Never dispatched.",
    done: "Finished."
  };
  var DISPATCHABLE = { queue: 1, agent: 1 };
  var HARNESS_LABELS = { codex: "Codex", claude: "Claude Code", opencode: "OpenCode" };
  var EFFORTS = ["low", "medium", "high", "max"];
  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ------------------------------------------------------------------ dom helpers

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function svg(tag, attrs) {
    var node = document.createElementNS(SVG_NS, tag);
    for (var key in attrs) if (attrs[key] !== undefined && attrs[key] !== null) node.setAttribute(key, attrs[key]);
    return node;
  }

  function button(label, cls, onClick) {
    var b = el("button", cls || "fx-action", label);
    b.type = "button";
    if (onClick) b.addEventListener("click", onClick);
    return b;
  }

  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function slugify(name) {
    var slug = String(name || "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 24);
    if (!/^[a-z]/.test(slug)) slug = "stage-" + slug;
    return slug.replace(/-+$/, "") || "stage";
  }

  function since(ms) {
    if (!ms) return "";
    var s = Math.max(0, (Date.now() - ms) / 1000);
    if (s < 90) return Math.round(s) + "s";
    if (s < 5400) return Math.round(s / 60) + "m";
    if (s < 129600) return Math.round(s / 3600) + "h";
    return Math.round(s / 86400) + "d";
  }

  function safeUrl(url) {
    return typeof url === "string" && /^https:\/\//i.test(url) ? url : null;
  }

  function snap(v) {
    return Math.round(v / GRID) * GRID;
  }

  // ------------------------------------------------------------------ geometry

  function rectOf(stage) {
    var p = stage.position || { x: 0, y: 0 };
    return { x: p.x - NODE_W / 2, y: p.y - NODE_H / 2, w: NODE_W, h: NODE_H, cx: p.x, cy: p.y };
  }

  function overlapsX(r, a, b) {
    var lo = Math.min(a, b);
    var hi = Math.max(a, b);
    return r.x < hi && r.x + r.w > lo;
  }

  // Assigns each transition its exit/entry side and a routing class.
  function classify(t, rects) {
    var a = rects[t.from];
    var b = rects[t.to];
    var dx = b.cx - a.cx;
    var dy = b.cy - a.cy;
    if (Math.abs(dx) >= NODE_W * 0.75) {
      if (dx > 0) {
        // Forward. Go over the top if another stage sits on the straight line.
        var blocked = Object.keys(rects).some(function (id) {
          if (id === t.from || id === t.to) return false;
          var r = rects[id];
          return overlapsX(r, a.x + a.w, b.x) && r.y < Math.max(a.cy, b.cy) + 8 && r.y + r.h > Math.min(a.cy, b.cy) - 8;
        });
        return blocked ? { kind: "over", out: "top", in: "top" } : { kind: "forward", out: "right", in: "left" };
      }
      return { kind: "loop", out: "bottom", in: "bottom" };
    }
    return dy > 0 ? { kind: "down", out: "bottom", in: "top" } : { kind: "up", out: "top", in: "bottom" };
  }

  function portPoint(rect, side, index, count) {
    var f = (index + 1) / (count + 1);
    if (side === "right") return { x: rect.x + rect.w, y: rect.y + rect.h * f };
    if (side === "left") return { x: rect.x, y: rect.y + rect.h * f };
    if (side === "top") return { x: rect.x + rect.w * f, y: rect.y };
    return { x: rect.x + rect.w * f, y: rect.y + rect.h };
  }

  // Polyline -> SVG path with rounded corners.
  function roundedPath(points) {
    var d = "M" + points[0].x + "," + points[0].y;
    for (var i = 1; i < points.length - 1; i++) {
      var p0 = points[i - 1];
      var p1 = points[i];
      var p2 = points[i + 1];
      var r = Math.min(RADIUS, dist(p0, p1) / 2, dist(p1, p2) / 2);
      var a = towards(p1, p0, r);
      var b = towards(p1, p2, r);
      d += " L" + a.x + "," + a.y + " Q" + p1.x + "," + p1.y + " " + b.x + "," + b.y;
    }
    var last = points[points.length - 1];
    return d + " L" + last.x + "," + last.y;
  }

  function dist(a, b) {
    return Math.abs(a.x - b.x) + Math.abs(a.y - b.y);
  }

  function towards(from, to, r) {
    var d = dist(from, to) || 1;
    return { x: from.x + ((to.x - from.x) / d) * r, y: from.y + ((to.y - from.y) / d) * r };
  }

  function midpoint(points) {
    var total = 0;
    for (var i = 1; i < points.length; i++) total += dist(points[i - 1], points[i]);
    var half = total / 2;
    for (var j = 1; j < points.length; j++) {
      var seg = dist(points[j - 1], points[j]);
      if (half <= seg) return towards(points[j - 1], points[j], half);
      half -= seg;
    }
    return points[0];
  }

  // Routes every transition. Returns {key: {points, d, mid, cls}}.
  function routeAll(definition) {
    var rects = {};
    definition.stages.forEach(function (s) {
      rects[s.id] = rectOf(s);
    });
    var transitions = definition.transitions.filter(function (t) {
      return rects[t.from] && rects[t.to];
    });
    var routes = {};
    var sides = {};

    transitions.forEach(function (t) {
      var c = classify(t, rects);
      routes[t.from + ">" + t.to] = { t: t, cls: c };
      (sides[t.from + ":" + c.out] = sides[t.from + ":" + c.out] || []).push({ key: t.from + ">" + t.to, other: t.to });
      (sides[t.to + ":" + c.in] = sides[t.to + ":" + c.in] || []).push({ key: t.from + ">" + t.to, other: t.from });
    });

    // Spread ports along each side, ordered by where the other end is, so lines
    // leaving one side don't cross each other.
    Object.keys(sides).forEach(function (key) {
      var parts = key.split(":");
      var stage = parts[0];
      var side = parts[1];
      var list = sides[key];
      var horizontal = side === "top" || side === "bottom";
      list.sort(function (a, b) {
        var ra = rects[a.other];
        var rb = rects[b.other];
        return horizontal ? ra.cx - rb.cx : ra.cy - rb.cy;
      });
      list.forEach(function (item, i) {
        var r = routes[item.key];
        var point = portPoint(rects[stage], side, i, list.length);
        if (r.t.from === stage && r.cls.out === side) r.start = point;
        else r.end = point;
      });
    });

    // Lanes: loops below, overs above, each in its own lane (shortest span closest).
    var below = [];
    var above = [];
    Object.keys(routes).forEach(function (key) {
      var r = routes[key];
      if (r.cls.kind === "loop") below.push(r);
      if (r.cls.kind === "over") above.push(r);
    });
    var span = function (r) {
      return Math.abs(r.start.x - r.end.x);
    };
    below.sort(function (a, b) {
      return span(a) - span(b);
    });
    above.sort(function (a, b) {
      return span(a) - span(b);
    });

    var stageList = Object.keys(rects).map(function (id) {
      return rects[id];
    });
    var bottomUnder = function (a, b) {
      return stageList.reduce(function (m, r) {
        return overlapsX(r, a, b) ? Math.max(m, r.y + r.h) : m;
      }, -Infinity);
    };
    var topOver = function (a, b) {
      return stageList.reduce(function (m, r) {
        return overlapsX(r, a, b) ? Math.min(m, r.y) : m;
      }, Infinity);
    };

    below.forEach(function (r, i) {
      var y = bottomUnder(r.start.x, r.end.x) + 22 + i * LANE_GAP;
      r.points = [r.start, { x: r.start.x, y: y }, { x: r.end.x, y: y }, r.end];
    });
    above.forEach(function (r, i) {
      var y = topOver(r.start.x, r.end.x) - 22 - i * LANE_GAP;
      r.points = [r.start, { x: r.start.x, y: y }, { x: r.end.x, y: y }, r.end];
    });

    // Forward and vertical routes bend halfway, nudged apart when they share a gap.
    var gapUse = {};
    Object.keys(routes).forEach(function (key) {
      var r = routes[key];
      if (r.points) return;
      if (r.cls.kind === "forward") {
        var gapKey = Math.round(r.start.x) + ":" + Math.round(r.end.x);
        var n = (gapUse[gapKey] = (gapUse[gapKey] || 0) + 1) - 1;
        var midX = (r.start.x + r.end.x) / 2 + (n % 2 ? 1 : -1) * Math.ceil(n / 2) * 8;
        r.points =
          Math.abs(r.start.y - r.end.y) < 1
            ? [r.start, r.end]
            : [r.start, { x: midX, y: r.start.y }, { x: midX, y: r.end.y }, r.end];
      } else {
        var midY = (r.start.y + r.end.y) / 2;
        r.points =
          Math.abs(r.start.x - r.end.x) < 1
            ? [r.start, r.end]
            : [r.start, { x: r.start.x, y: midY }, { x: r.end.x, y: midY }, r.end];
      }
    });

    Object.keys(routes).forEach(function (key) {
      var r = routes[key];
      r.d = roundedPath(r.points);
      r.mid = midpoint(r.points);
    });
    return routes;
  }

  function bounds(definition, routes) {
    var minX = Infinity;
    var minY = Infinity;
    var maxX = -Infinity;
    var maxY = -Infinity;
    definition.stages.forEach(function (s) {
      var r = rectOf(s);
      minX = Math.min(minX, r.x);
      minY = Math.min(minY, r.y);
      maxX = Math.max(maxX, r.x + r.w);
      maxY = Math.max(maxY, r.y + r.h + 18);
    });
    Object.keys(routes).forEach(function (k) {
      routes[k].points.forEach(function (p) {
        minY = Math.min(minY, p.y);
        maxY = Math.max(maxY, p.y);
      });
    });
    if (minX === Infinity) return { x: 0, y: 0, w: 1000, h: 300 };
    var pad = 30;
    return { x: minX - pad, y: minY - pad, w: Math.max(maxX - minX + pad * 2, 600), h: Math.max(maxY - minY + pad * 2, 220) };
  }

  // ------------------------------------------------------------------ flow

  // The default team's flow, unless it's empty and a project's flow has work
  // (a team whose projects all run their own flows).
  function issueCount(flow) {
    return Object.keys((flow && flow.nodes) || {}).reduce(function (n, id) {
      return n + (flow.nodes[id].count || 0);
    }, 0);
  }

  function busiest(data) {
    var flows = data.flows || {};
    if (!data.team || issueCount(flows[data.team]) > 0) return data.team;
    var best = null;
    (data.teams || []).forEach(function (t) {
      if (t.kind === "project" && issueCount(flows[t.key]) > (best ? issueCount(flows[best]) : 0)) best = t.key;
    });
    if (best) return best;
    // Nothing has run yet: a project with its own flow says more than the default.
    if (data.team === "DEFAULT") {
      var own = (data.teams || []).filter(function (t) {
        return t.kind === "project" && t.custom;
      })[0];
      if (own) return own.key;
    }
    return data.team;
  }

  function Flow(opts) {
    this.opts = opts;
    this.data = null;
    this.team = null;
    this.mode = "view";
    this.draft = null;
    this.baseVersion = null;
    this.selected = null; // {type: "stage"|"edge", id}
    this.errors = [];
    this.pending = {};
    this.lastKey = null;
    this.build();
  }

  Flow.prototype.build = function () {
    var self = this;
    var slot = this.opts.slot;
    slot.textContent = "";
    slot.classList.add("fx-diagram-slot");

    this.toolbar = el("div", "fx-flow-toolbar");
    slot.appendChild(this.toolbar);
    this.errorBox = el("div", "fx-flow-errors");
    this.errorBox.hidden = true;
    slot.appendChild(this.errorBox);

    // The canvas clips the diagram so it can be zoomed and panned in place.
    this.canvas = el("div", "fx-canvas");
    this.svg = svg("svg", { class: "fx-diagram", role: "img", "aria-label": "Agent factory process diagram" });
    this.canvas.appendChild(this.svg);
    this.canvas.appendChild(this.buildZoomControls());
    slot.appendChild(this.canvas);
    this.view = null; // null = fit the whole flow; else {x, y, w, h} in diagram units
    window.addEventListener("resize", function () {
      if (document.documentElement.classList.contains("fx-cinema") && self.fit) self.applyView();
    });

    // ⌘/Ctrl + wheel (and trackpad pinch, which arrives as ctrl+wheel) zooms at
    // the pointer. Once zoomed in, a plain wheel or two-finger scroll pans;
    // otherwise it scrolls the page as usual.
    this.svg.addEventListener(
      "wheel",
      function (e) {
        if (e.ctrlKey || e.metaKey) {
          e.preventDefault();
          self.zoomAt(self.svgPoint(e), Math.exp(e.deltaY * 0.0025));
        } else if (self.view) {
          e.preventDefault();
          var scale = self.view.w / (self.svg.getBoundingClientRect().width || 1);
          self.panBy(e.deltaX * scale, e.deltaY * scale);
        }
      },
      { passive: false }
    );
    // Dragging the empty background pans.
    this.svg.addEventListener("pointerdown", function (e) {
      if (e.target !== self.svg || e.button !== 0) return;
      self.pan = { x: e.clientX, y: e.clientY, moved: false };
      self.svg.setPointerCapture(e.pointerId);
    });

    this.drawer = el("div", "fx-drawer");
    this.drawer.hidden = true;
    this.opts.drawerSlot.textContent = "";
    this.opts.drawerSlot.appendChild(this.drawer);

    this.svg.addEventListener("pointermove", function (e) {
      self.onPointerMove(e);
    });
    this.svg.addEventListener("pointerup", function (e) {
      self.onPointerUp(e);
    });
    this.svg.addEventListener("click", function (e) {
      if (e.target === self.svg && !self.dragged) self.select(null);
    });
    document.addEventListener("keydown", function (e) {
      var tag = (e.target && e.target.tagName) || "";
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || (e.target && e.target.isContentEditable)) return;
      if ((e.key === "t" || e.key === "T") && !e.metaKey && !e.ctrlKey && !e.altKey) {
        self.toggleCinema();
        return;
      }
      if (self.mode !== "edit" || !self.selected) return;
      if (e.key === "Delete" || e.key === "Backspace") {
        e.preventDefault();
        self.deleteSelected();
      }
    });
  };

  Flow.prototype.setData = function (data) {
    this.data = data;
    var teams = (data.teams || []).map(function (t) {
      return t.key;
    });
    if (!this.team || teams.indexOf(this.team) === -1) {
      var hash = /team=([^&]+)/.exec(window.location.hash || "");
      if (hash) {
        try {
          hash[1] = decodeURIComponent(hash[1]);
        } catch (_e) {}
      }
      var saved = null;
      try {
        saved = window.localStorage.getItem("symphony.factory.team");
      } catch (_e) {}
      this.team = [hash && hash[1], saved, busiest(data), data.team, teams[0]].filter(function (t) {
        return t && teams.indexOf(t) !== -1;
      })[0];
      var stageHash = /stage=([a-z0-9-]+)/.exec(window.location.hash || "");
      if (stageHash) this.selected = { type: "stage", id: stageHash[1] };
    }
    // Server updates never clobber an unsaved draft.
    var key = JSON.stringify([this.team, this.mode, this.definition(), this.flow()]);
    if (key === this.lastKey) return;
    this.lastKey = key;
    this.render();
  };

  Flow.prototype.definition = function () {
    if (this.mode === "edit" && this.draft) return this.draft;
    return this.data && this.data.definitions ? this.data.definitions[this.team] : null;
  };

  Flow.prototype.flow = function () {
    return (this.data && this.data.flows && this.data.flows[this.team]) || { nodes: {}, edges: {} };
  };

  Flow.prototype.canEdit = function () {
    return !!(this.data && this.data.can_edit && this.data.can_edit[this.team]);
  };

  Flow.prototype.entry = function (key) {
    key = key || this.team;
    return ((this.data && this.data.teams) || []).filter(function (t) {
      return t.key === key;
    })[0] || null;
  };

  // How the flow a scope inherits is named: "default", "built-in", "PAY · Payments".
  Flow.prototype.sourceLabel = function (source) {
    if (source === "template") return "built-in";
    var t = this.entry(source);
    if (source === "DEFAULT" || (t && t.kind === "default")) return "default";
    return this.scopeLabel(source);
  };

  // "PAY · Payments", "Checkout API", "Default flow".
  Flow.prototype.scopeLabel = function (key) {
    var t = this.entry(key);
    if (!t) return key && key.indexOf("project:") === 0 ? key.slice(8) : key || "";
    if (t.kind === "default") return "Default flow";
    if (t.kind === "project") return t.name || t.slug;
    return t.key + (t.name ? " · " + t.name : "");
  };

  Flow.prototype.canControl = function () {
    return !!(this.data && this.data.can_control && this.data.can_control[this.team]);
  };

  Flow.prototype.render = function () {
    this.renderToolbar();
    this.renderErrors();
    this.renderDiagram();
    this.renderDrawer();
    this.syncHash();
  };

  Flow.prototype.syncHash = function () {
    try {
      var parts = [];
      if (this.team) parts.push("team=" + encodeURIComponent(this.team));
      if (this.selected && this.selected.type === "stage") parts.push("stage=" + this.selected.id);
      var hash = parts.length ? "#" + parts.join("&") : "";
      if (window.location.hash !== hash) window.history.replaceState(null, "", window.location.pathname + window.location.search + hash);
    } catch (_e) {}
  };

  // ------------------------------------------------------------------ toolbar

  Flow.prototype.renderToolbar = function () {
    var self = this;
    var bar = this.toolbar;
    bar.textContent = "";

    var teams = (this.data && this.data.teams) || [];
    if (teams.length > 1 || this.mode === "edit") {
      var select = el("select", "fx-team-select");
      select.setAttribute("aria-label", "Flow for");
      select.disabled = this.mode === "edit";
      var groups = { team: el("optgroup"), project: el("optgroup") };
      groups.team.label = "Teams";
      groups.project.label = "Projects";
      var defs = (this.data && this.data.definitions) || {};
      teams.forEach(function (t) {
        var definition = defs[t.key];
        var suffix = "";
        if (!t.custom && definition && definition.source) suffix = " — uses " + self.sourceLabel(definition.source) + " flow";
        var option = el("option", null, self.scopeLabel(t.key) + suffix);
        option.value = t.key;
        option.selected = t.key === self.team;
        if (t.kind === "default") select.appendChild(option);
        else groups[t.kind === "project" ? "project" : "team"].appendChild(option);
      });
      if (groups.team.children.length) select.appendChild(groups.team);
      if (groups.project.children.length) select.appendChild(groups.project);
      select.addEventListener("change", function () {
        self.team = select.value;
        self.selected = null;
        self.view = null;
        try {
          window.localStorage.setItem("symphony.factory.team", self.team);
        } catch (_e) {}
        self.lastKey = null;
        self.render();
      });
      bar.appendChild(select);
    } else if (teams.length === 1) {
      bar.appendChild(el("span", "fx-team-name", this.scopeLabel(teams[0].key)));
    }

    var definition = this.definition();
    var entry = this.entry();
    if (definition && definition.inherited && this.mode === "view") {
      var from = this.sourceLabel(definition.source);
      bar.appendChild(el("span", "fx-flow-meta", "Using the " + from + " flow"));
    } else if (definition && definition.updated_by && this.mode === "view") {
      bar.appendChild(el("span", "fx-flow-meta", "v" + definition.version + " · edited by " + definition.updated_by));
    }

    var spacer = el("span", "fx-flow-spacer");
    bar.appendChild(spacer);

    if (this.mode === "edit") {
      bar.appendChild(button("+ Stage", "fx-chip", function () {
        self.addStage();
      }));
      if (this.opts.assistFlow) {
        bar.appendChild(button("✦ Draft flow with AI", "fx-chip fx-assist-btn", function () {
          self.openFlowAssist();
        }));
      }
      bar.appendChild(el("span", "fx-flow-hint", "Drag stages · drag ＋ to connect · Delete removes"));
      if (entry && entry.custom && entry.kind !== "default") {
        bar.appendChild(button(entry.kind === "project" ? "Use team flow" : "Use default flow", "fx-chip", function () {
          self.resetScope();
        }));
      }
      bar.appendChild(button("Discard", "fx-chip", function () {
        self.exitEdit();
      }));
      var save = button(this.saving ? "Saving…" : "Save", "fx-action is-primary", function () {
        self.save();
      });
      save.disabled = !!this.saving;
      bar.appendChild(save);
    } else if (this.canEdit()) {
      var inherited = definition && definition.inherited;
      var noun = entry && entry.kind === "project" ? "this project" : entry && entry.kind === "team" ? "this team" : "";
      if (this.opts.assistFlow) {
        bar.appendChild(button("✦ Design with AI", "fx-chip fx-assist-btn", function () {
          self.enterEdit();
          self.openFlowAssist();
        }));
      }
      bar.appendChild(button(inherited && noun ? "Customize for " + noun : "Edit flow", "fx-chip", function () {
        self.enterEdit();
      }));
    }

    if (this.mode === "view" && definition) {
      var auto = autopilotOf(definition);
      var chip = button(auto.enabled ? "✋ Earned autonomy · " + auto.streak + " in a row" : "✋ Earned autonomy: off", "fx-chip fx-autopilot" + (auto.enabled ? " is-on" : ""), function () {
        self.openAutopilot(chip);
      });
      chip.title = "Every agent stage needs a person's approval until it gets enough approvals in a row";
      chip.disabled = !this.canEdit();
      bar.appendChild(chip);
    }
  };

  Flow.prototype.openAutopilot = function (anchor) {
    var self = this;
    var existing = this.toolbar.querySelector(".fx-popover");
    if (existing) return void existing.remove();
    var auto = autopilotOf(this.definition());
    var pop = el("div", "fx-popover");
    pop.appendChild(el("strong", null, "Earned autonomy"));
    pop.appendChild(
      el("p", "fx-field-hint", "Every agent stage in this flow needs a person to approve its moves until it gets this many approvals in a row. A send-back starts the count again. Stages marked ✋ always need approval.")
    );
    var on = el("label", "fx-check");
    var box = el("input");
    box.type = "checkbox";
    box.checked = auto.enabled;
    on.appendChild(box);
    on.appendChild(document.createTextNode(" Require approval until a stage has earned it"));
    pop.appendChild(on);
    var countRow = el("label", "fx-check");
    countRow.appendChild(document.createTextNode("Approvals in a row: "));
    var count = el("input", "fx-input fx-input-narrow");
    count.type = "number";
    count.min = 1;
    count.max = 100;
    count.value = auto.streak;
    countRow.appendChild(count);
    pop.appendChild(countRow);
    var actions = el("div", "fx-issue-actions");
    actions.appendChild(button("Save", "fx-action is-primary", function () {
      var streak = parseInt(count.value, 10);
      self.opts.push("factory_autopilot", { team: self.team, enabled: box.checked, streak: isNaN(streak) ? 0 : streak }, function (reply) {
        if (reply && reply.ok) {
          self.data.definitions[self.team] = reply.definition;
          pop.remove();
          self.lastKey = null;
          self.render();
          self.opts.toast(box.checked ? "Earned autonomy on: " + streak + " approvals in a row" : "Earned autonomy off", "ok");
        } else {
          self.opts.toast((reply && reply.error) || "Couldn't save", "error");
        }
      });
    }));
    actions.appendChild(button("Cancel", "fx-action", function () {
      pop.remove();
    }));
    pop.appendChild(actions);
    this.toolbar.appendChild(pop);
    count.focus();
  };

  Flow.prototype.openFlowAssist = function () {
    var self = this;
    this.opts.assistFlow(this.team, this.scopeLabel(), this.draft, function (suggestion) {
      var version = self.draft.version;
      var request = self.draft._flowRequest;
      self.draft = clone(suggestion.definition);
      self.draft.version = version;
      self.draft._flowRequest = request;
      self.selected = null;
      self.errors = [];
      self.lastKey = null;
      self.render();
      self.opts.toast("Draft applied. Review it, then Save.", "ok");
    });
  };

  Flow.prototype.resetScope = function () {
    var self = this;
    var entry = this.entry();
    var parent = entry.kind === "project" ? "its team's flow" : "the default flow";
    if (!window.confirm("Remove " + this.scopeLabel() + "'s own flow? It will use " + parent + " again.")) return;
    this.opts.push("factory_reset", { team: this.team }, function (reply) {
      if (reply && reply.ok) {
        self.opts.toast(self.scopeLabel() + " now uses " + parent, "ok");
        self.exitEdit();
      } else {
        self.errors = [(reply && reply.error) || "Couldn't remove the flow"];
        self.render();
      }
    });
  };

  Flow.prototype.renderErrors = function () {
    var box = this.errorBox;
    box.textContent = "";
    box.hidden = !this.errors.length;
    if (!this.errors.length) return;
    box.appendChild(el("strong", null, "Can't save yet:"));
    var list = el("ul");
    this.errors.forEach(function (e) {
      list.appendChild(el("li", null, e));
    });
    box.appendChild(list);
  };

  // ------------------------------------------------------------------ diagram

  Flow.prototype.renderDiagram = function () {
    var self = this;
    var root = this.svg;
    root.textContent = "";
    var definition = this.definition();
    if (!definition) return;

    var flow = this.flow();
    var routes = routeAll(definition);
    var box = bounds(definition, routes);
    this.fit = box;
    this.applyView();
    root.classList.toggle("is-editing", this.mode === "edit");
    root.classList.toggle("has-selection", !!this.selected);

    var defs = svg("defs", {});
    ["agent", "human", "idle", "selected"].forEach(function (kind) {
      var marker = svg("marker", {
        id: "fx-arrow-" + kind,
        viewBox: "0 0 10 10",
        refX: "8",
        refY: "5",
        markerUnits: "userSpaceOnUse",
        markerWidth: "9",
        markerHeight: "9",
        orient: "auto-start-reverse"
      });
      marker.appendChild(svg("path", { d: "M0,1 L9,5 L0,9 z", class: "fx-arrow fx-arrow-" + kind }));
      defs.appendChild(marker);
    });
    root.appendChild(defs);

    if (this.mode === "edit") {
      root.appendChild(svg("rect", { x: box.x, y: box.y, width: box.w, height: box.h, class: "fx-grid-bg", fill: "url(#fx-grid)" }));
      var pattern = svg("pattern", { id: "fx-grid", width: GRID, height: GRID, patternUnits: "userSpaceOnUse" });
      pattern.appendChild(svg("circle", { cx: 1, cy: 1, r: 1, class: "fx-grid-dot" }));
      defs.appendChild(pattern);
    }

    var counts = flow.edges || {};
    var maxCount = Object.keys(counts).reduce(function (m, k) {
      return Math.max(m, counts[k]);
    }, 1);

    var edgeLayer = svg("g", { class: "fx-edges" });
    var particleLayer = svg("g", { class: "fx-particles" });
    var chipLayer = svg("g", { class: "fx-edge-labels" });
    root.appendChild(edgeLayer);
    root.appendChild(particleLayer);

    Object.keys(routes).forEach(function (key, index) {
      var r = routes[key];
      var t = r.t;
      var count = counts[key] || 0;
      var selected = self.selected && self.selected.type === "edge" && self.selected.id === key;
      var kind = selected ? "selected" : count > 0 ? t.by : "idle";
      var width = count > 0 ? 1.5 + 3.5 * Math.sqrt(count / maxCount) : 1.4;
      var id = "fx-edge-" + index;

      edgeLayer.appendChild(
        svg("path", {
          id: id,
          d: r.d,
          class: "fx-edge fx-edge-by-" + t.by + " fx-edge-" + kind + (r.cls.kind === "loop" ? " fx-edge-is-loop" : ""),
          "stroke-width": selected ? 2.5 : width.toFixed(2),
          "marker-end": "url(#fx-arrow-" + kind + ")"
        })
      );

      var hit = svg("path", { d: r.d, class: "fx-edge-hit" });
      hit.addEventListener("click", function (e) {
        e.stopPropagation();
        self.select({ type: "edge", id: key });
      });
      hit.addEventListener("pointerenter", function (e) {
        self.opts.tip.show(e, function (tip) {
          var from = self.stageById(t.from);
          var to = self.stageById(t.to);
          tip.appendChild(el("strong", "fx-tip-value", (from ? from.name : t.from) + " → " + (to ? to.name : t.to)));
          tip.appendChild(el("div", "fx-tip-row", (t.by === "human" ? "A person moves it" : "An agent moves it") + (t.criteria ? ": " + t.criteria : "")));
          tip.appendChild(el("div", "fx-tip-row", count + (count === 1 ? " issue has" : " issues have") + " taken this path"));
        });
      });
      hit.addEventListener("pointermove", function (e) {
        self.opts.tip.move(e);
      });
      hit.addEventListener("pointerleave", function () {
        self.opts.tip.hide();
      });
      edgeLayer.appendChild(hit);

      var chip = svg("g", { class: "fx-edge-chip fx-edge-chip-" + t.by, transform: "translate(" + r.mid.x + "," + r.mid.y + ")" });
      var text = (t.by === "human" ? "◐ " : "") + (count > 0 ? String(count) : "");
      if (text.trim()) {
        var w = 10 + text.length * 6.5;
        chip.appendChild(svg("rect", { x: -w / 2, y: -9, width: w, height: 18, rx: 9 }));
        var label = svg("text", { "text-anchor": "middle", y: "4" });
        label.textContent = text;
        chip.appendChild(label);
        chipLayer.appendChild(chip);
      }

      if (count > 0 && !reduceMotion && t.by === "agent" && self.mode === "view") {
        var n = Math.min(3, 1 + Math.floor(Math.log(count) / Math.LN2));
        var dur = 2.2 + (index % 3) * 0.35;
        for (var i = 0; i < n; i++) {
          var dot = svg("circle", { r: "2.2", class: "fx-particle" });
          var motion = svg("animateMotion", { dur: dur + "s", repeatCount: "indefinite", begin: ((dur / n) * i).toFixed(2) + "s" });
          var mpath = svg("mpath", {});
          mpath.setAttribute("href", "#" + id);
          motion.appendChild(mpath);
          dot.appendChild(motion);
          particleLayer.appendChild(dot);
        }
      }
    });

    var nodeLayer = svg("g", { class: "fx-nodes" });
    root.appendChild(nodeLayer);
    root.appendChild(chipLayer);
    this.connector = svg("path", { class: "fx-connector", d: "" });
    root.appendChild(this.connector);

    definition.stages.forEach(function (stage) {
      nodeLayer.appendChild(self.renderNode(stage, flow.nodes[stage.id] || { issues: [], count: 0, running: 0 }));
    });
  };

  Flow.prototype.renderNode = function (stage, info) {
    var self = this;
    var r = rectOf(stage);
    var selected = this.selected && this.selected.type === "stage" && this.selected.id === stage.id;
    var g = svg("g", {
      class:
        "fx-node fx-node-kind-" +
        stage.kind +
        (info.running > 0 ? " is-running" : "") +
        (info.count === 0 ? " is-empty" : "") +
        (stage.paused ? " is-paused" : "") +
        (selected ? " is-selected" : ""),
      transform: "translate(" + r.x + "," + r.y + ")",
      tabindex: "0",
      role: "button",
      "data-stage": stage.id,
      "aria-label": stage.name + ", " + KIND_LABEL[stage.kind] + " stage, " + info.count + " issues"
    });

    if (info.running > 0) g.appendChild(svg("rect", { x: -14, y: -14, width: r.w + 28, height: r.h + 28, rx: 26, class: "fx-node-halo" }));
    g.appendChild(svg("rect", { width: r.w, height: r.h, rx: 16, class: "fx-node-box" }));

    // Top-right: the kind glyph, and the approval badge (✋ 3/10, ✋, ✓ trusted).
    var glyph = stage.kind === "done" ? "✓" : stage.kind === "parked" ? "⏸" : stage.kind === "human" ? "◐" : stage.kind === "queue" ? "≡" : "";
    var gate = approvalState(this.definition(), stage);
    var maxName = gate ? 11 : 18;

    var label = svg("text", { x: 14, y: 24, class: "fx-node-label" });
    label.textContent = stage.name.length > maxName ? stage.name.slice(0, maxName - 1) + "…" : stage.name;
    g.appendChild(label);

    var kind = svg("text", { x: r.w - 14, y: 24, "text-anchor": "end", class: "fx-node-kind fx-node-kind-" + stage.kind });
    kind.textContent = glyph;
    g.appendChild(kind);

    if (gate) {
      var right = r.w - (glyph ? 30 : 10);
      var badge = svg("g", { class: "fx-gate" + (gate.indexOf("trusted") !== -1 ? " is-trusted" : "") });
      var badgeText = svg("text", { x: right - 7, y: 24, "text-anchor": "end", class: "fx-gate-text" });
      badgeText.textContent = gate;
      var width = 14 + gate.length * 6.2;
      badge.appendChild(svg("rect", { x: right - width, y: 11, width: width, height: 18, rx: 9, class: "fx-gate-pill" }));
      badge.appendChild(badgeText);
      var tip = svg("title", {});
      tip.textContent =
        gate.indexOf("trusted") !== -1
          ? "Earned autonomy: this stage no longer needs approval"
          : stage.approval
            ? "A person approves every move out of this stage"
            : "Needs a person's approval until it has " + autopilotOf(this.definition()).streak + " approvals in a row";
      badge.appendChild(tip);
      g.appendChild(badge);
    }

    var count = svg("text", { x: 14, y: 58, class: "fx-node-count" });
    count.textContent = String(info.count);
    g.appendChild(count);

    var running = info.issues.filter(function (i) {
      return i.backend;
    });
    running.slice(0, 6).forEach(function (issue, i) {
      g.appendChild(svg("circle", { cx: r.w - 16 - i * 12, cy: 53, r: 4.5, class: "fx-agent-dot h-" + issue.backend }));
    });

    // Caption under the box: the stage label and its run settings. Only
    // "dispatch paused" is highlighted; it means no new agents start here.
    var config = [];
    if (stage.label) config.push(stage.label);
    if (stage.harness) config.push(HARNESS_LABELS[stage.harness] || stage.harness);
    if (stage.effort) config.push(stage.effort);
    if (stage.max_agents) config.push("≤" + stage.max_agents);
    if (config.length || stage.paused) {
      var line = svg("text", { x: 14, y: r.h + 14, class: "fx-node-config" });
      if (stage.paused) {
        var pausedSpan = svg("tspan", { class: "fx-node-paused" });
        pausedSpan.textContent = "⏸ dispatch paused" + (config.length ? " · " : "");
        line.appendChild(pausedSpan);
      }
      var rest = svg("tspan", {});
      rest.textContent = config.join(" · ");
      line.appendChild(rest);
      g.appendChild(line);
    }

    if (this.mode === "edit") {
      var port = svg("g", { class: "fx-port", transform: "translate(" + r.w + "," + r.h / 2 + ")" });
      port.appendChild(svg("circle", { r: 9 }));
      var plus = svg("text", { "text-anchor": "middle", y: "4" });
      plus.textContent = "+";
      port.appendChild(plus);
      port.addEventListener("pointerdown", function (e) {
        e.stopPropagation();
        self.startConnect(e, stage.id);
      });
      g.appendChild(port);
    }

    g.addEventListener("pointerdown", function (e) {
      if (self.mode === "edit" && e.button === 0) self.startDrag(e, stage.id);
    });
    g.addEventListener("contextmenu", function (e) {
      e.preventDefault();
      e.stopPropagation();
      self.openStageMenu(e, stage.id);
    });
    g.addEventListener("click", function (e) {
      e.stopPropagation();
      if (self.dragged) return;
      self.select(selected ? null : { type: "stage", id: stage.id });
    });
    g.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        self.select({ type: "stage", id: stage.id });
      }
    });
    g.addEventListener("pointerenter", function (e) {
      if (self.drag || self.connect) return;
      self.opts.tip.show(e, function (tip) {
        tip.appendChild(el("strong", "fx-tip-value", stage.name));
        tip.appendChild(el("div", "fx-tip-row", KIND_LABEL[stage.kind] + " · " + stage.linear_state + (stage.label ? " + label " + stage.label : "")));
        info.issues.slice(0, 6).forEach(function (issue) {
          tip.appendChild(el("div", "fx-tip-row", issue.issue + "  " + (issue.title || "")));
        });
        if (info.count > 6) tip.appendChild(el("div", "fx-tip-row", "+" + (info.count - 6) + " more"));
      });
    });
    g.addEventListener("pointermove", function (e) {
      self.opts.tip.move(e);
    });
    g.addEventListener("pointerleave", function () {
      self.opts.tip.hide();
    });
    return g;
  };

  Flow.prototype.stageById = function (id) {
    var d = this.definition();
    if (!d) return null;
    for (var i = 0; i < d.stages.length; i++) if (d.stages[i].id === id) return d.stages[i];
    return null;
  };

  Flow.prototype.select = function (selection) {
    this.selected = selection;
    this.opts.tip.hide();
    this.lastKey = null;
    this.renderDiagram();
    this.renderDrawer();
    this.syncHash();
  };

  // ------------------------------------------------------------------ stage menu (right-click)

  Flow.prototype.closeStageMenu = function () {
    if (this.menu) this.menu.remove();
    this.menu = null;
    if (this._menuOff) this._menuOff();
  };

  Flow.prototype.openStageMenu = function (e, stageId) {
    var self = this;
    this.closeStageMenu();
    var stage = this.stageById(stageId);
    if (!stage) return;
    var editing = this.mode === "edit";
    var allowed = editing || this.canControl();
    var agentStage = !!DISPATCHABLE[stage.kind];

    var menu = el("div", "fx-menu");
    menu.setAttribute("role", "menu");
    menu.appendChild(el("div", "fx-menu-title", stage.name));

    var item = function (label, checked, enabled, hint, onPick) {
      var b = el("button", "fx-menu-item" + (checked ? " is-checked" : ""));
      b.type = "button";
      b.setAttribute("role", checked === null ? "menuitem" : "menuitemcheckbox");
      if (checked !== null) b.setAttribute("aria-checked", checked ? "true" : "false");
      b.appendChild(el("span", "fx-menu-check", checked ? "✓" : ""));
      b.appendChild(el("span", "fx-menu-label", label));
      if (hint) b.title = hint;
      b.disabled = !enabled;
      b.addEventListener("click", function () {
        self.closeStageMenu();
        onPick();
      });
      menu.appendChild(b);
      return b;
    };

    item("✋ Requires human approval", !!stage.approval, allowed && agentStage, agentStage ? "A person approves before issues leave this stage" : "Only agent stages can need approval", function () {
      self.setStageControl(stage, "approval", !stage.approval, function () {
        self.opts.toast(stage.name + (stage.approval ? " now needs a person's approval" : " no longer needs approval"), "ok");
      });
    });
    item("Pause dispatch", !!stage.paused, allowed && agentStage, "No new agents start in this stage", function () {
      self.setStageControl(stage, "paused", !stage.paused);
    });

    // Harness (and so model) and thinking level, one click each. Issue labels still win.
    var models = this.data.harness_models || {};
    var chips = function (title, options, current, field) {
      var row = el("div", "fx-menu-row");
      row.appendChild(el("span", "fx-menu-row-title", title));
      var group = el("div", "fx-menu-chips");
      options.forEach(function (o) {
        var b = el("button", "fx-menu-chip" + ((current || null) === o[0] ? " is-on" : ""), o[1]);
        b.type = "button";
        b.disabled = !(allowed && agentStage);
        if (o[2]) b.title = o[2];
        b.addEventListener("click", function () {
          self.closeStageMenu();
          if ((current || null) !== o[0]) self.setStageControl(stage, field, o[0]);
        });
        group.appendChild(b);
      });
      row.appendChild(group);
      menu.appendChild(row);
    };
    if (agentStage) {
      chips(
        "Harness",
        harnessOptions(this.data.harnesses).map(function (o) {
          return [o[0], o[1], o[0] ? "Model: " + (models[o[0]] || "default") : "The flow's default harness"];
        }),
        stage.harness,
        "harness"
      );
      var model = stage.harness && models[stage.harness];
      if (model && model !== "default") menu.appendChild(el("p", "fx-menu-note", "Runs " + model));
      chips("Thinking", effortOptions(), stage.effort, "effort");
    }
    item(editing ? "Edit stage" : "Open stage", null, true, null, function () {
      self.select({ type: "stage", id: stage.id });
    });
    if (!allowed) menu.appendChild(el("p", "fx-menu-note", "Only this flow's team members and admins can change it."));

    // Place at the pointer, inside the canvas.
    var box = this.canvas.getBoundingClientRect();
    this.canvas.appendChild(menu);
    var x = Math.min(e.clientX - box.left, box.width - menu.offsetWidth - 6);
    var y = Math.min(e.clientY - box.top, box.height - menu.offsetHeight - 6);
    menu.style.left = Math.max(6, x) + "px";
    menu.style.top = Math.max(6, y) + "px";
    this.menu = menu;
    var first = menu.querySelector("button:not([disabled])");
    if (first) first.focus();

    var onDown = function (ev) {
      if (!menu.contains(ev.target)) self.closeStageMenu();
    };
    var onKey = function (ev) {
      if (ev.key === "Escape") self.closeStageMenu();
    };
    document.addEventListener("pointerdown", onDown, true);
    document.addEventListener("keydown", onKey);
    window.addEventListener("blur", onDown);
    this._menuOff = function () {
      document.removeEventListener("pointerdown", onDown, true);
      document.removeEventListener("keydown", onKey);
      window.removeEventListener("blur", onDown);
      self._menuOff = null;
    };
  };

  // ------------------------------------------------------------------ zoom and pan

  var MIN_ZOOM = 0.4;
  var MAX_ZOOM = 4;

  Flow.prototype.buildZoomControls = function () {
    var self = this;
    var bar = el("div", "fx-zoom");
    bar.appendChild(button("−", "fx-zoom-btn", function () {
      self.zoomAt(null, 1.25);
    }));
    this.zoomLabel = button("100%", "fx-zoom-btn fx-zoom-level", function () {
      self.resetView();
    });
    this.zoomLabel.title = "Fit the whole flow";
    bar.appendChild(this.zoomLabel);
    bar.appendChild(button("+", "fx-zoom-btn", function () {
      self.zoomAt(null, 0.8);
    }));
    bar.querySelectorAll("button")[0].setAttribute("aria-label", "Zoom out");
    bar.querySelectorAll("button")[2].setAttribute("aria-label", "Zoom in");
    this.cinemaButton = button("⤢", "fx-zoom-btn", function () {
      self.toggleCinema();
    });
    bar.appendChild(this.cinemaButton);
    this.toggleCinema(readCinema());
    return bar;
  };

  // Cinema mode: the flow takes the full width and Needs you moves below it,
  // like a video player's theatre mode. The class lives on <html> so LiveView
  // re-renders never drop it. Remembered per browser; T toggles it.
  function readCinema() {
    try {
      return window.localStorage.getItem("symphony.cinema") === "1";
    } catch (_e) {
      return false;
    }
  }

  Flow.prototype.toggleCinema = function (on) {
    var root = document.documentElement;
    on = on === undefined ? !root.classList.contains("fx-cinema") : on;
    root.classList.toggle("fx-cinema", on);
    // The canvas changed shape: start again from the whole flow.
    this.view = null;
    if (this.canvas && this.fit) this.applyView();
    if (this.cinemaButton) {
      this.cinemaButton.textContent = on ? "⤡" : "⤢";
      this.cinemaButton.setAttribute("aria-label", on ? "Exit cinema mode (T)" : "Cinema mode (T)");
      this.cinemaButton.title = on ? "Exit cinema mode (T)" : "Cinema mode: make the flow full width (T)";
      this.cinemaButton.setAttribute("aria-pressed", on ? "true" : "false");
    }
    try {
      window.localStorage.setItem("symphony.cinema", on ? "1" : "0");
    } catch (_e) {}
  };

  Flow.prototype.currentView = function () {
    return this.view || this.fitView();
  };

  // The whole flow. In cinema mode the canvas has its own height, so the fit
  // widens or heightens (centred) to the canvas's shape: the diagram fills it
  // and every corner can be panned into.
  Flow.prototype.fitView = function () {
    var f = this.fit || { x: 0, y: 0, w: 1000, h: 400 };
    if (!document.documentElement.classList.contains("fx-cinema")) return f;
    var box = this.canvas.getBoundingClientRect();
    if (!box.width || !box.height) return f;
    var aspect = box.width / box.height;
    if (f.w / f.h < aspect) {
      var w = f.h * aspect;
      return { x: f.x - (w - f.w) / 2, y: f.y, w: w, h: f.h };
    }
    var h = f.w / aspect;
    return { x: f.x, y: f.y - (h - f.h) / 2, w: f.w, h: h };
  };

  // The view keeps the fit's aspect ratio, so the diagram's height never jumps.
  Flow.prototype.applyView = function () {
    var v = this.currentView();
    this.svg.setAttribute("viewBox", v.x + " " + v.y + " " + v.w + " " + v.h);
    var zoom = this.fit ? Math.round((this.fitView().w / v.w) * 100) : 100;
    if (this.zoomLabel) this.zoomLabel.textContent = this.view ? zoom + "%" : "Fit";
    this.canvas.classList.toggle("is-zoomed", !!this.view);
  };

  // factor < 1 zooms in. `at` is a diagram point that stays under the pointer.
  Flow.prototype.zoomAt = function (at, factor) {
    if (!this.fit) return;
    var v = this.currentView();
    var base = this.fitView();
    var w = Math.min(Math.max(v.w * factor, base.w / MAX_ZOOM), base.w / MIN_ZOOM);
    var k = w / v.w;
    var p = at || { x: v.x + v.w / 2, y: v.y + v.h / 2 };
    this.view = { x: p.x - (p.x - v.x) * k, y: p.y - (p.y - v.y) * k, w: w, h: v.h * k };
    this.applyView();
  };

  Flow.prototype.panBy = function (dx, dy) {
    var v = this.currentView();
    this.view = { x: v.x + dx, y: v.y + dy, w: v.w, h: v.h };
    this.applyView();
  };

  Flow.prototype.resetView = function () {
    this.view = null;
    this.applyView();
  };

  // ------------------------------------------------------------------ editing: pointer

  Flow.prototype.svgPoint = function (e) {
    var pt = this.svg.createSVGPoint();
    pt.x = e.clientX;
    pt.y = e.clientY;
    var ctm = this.svg.getScreenCTM();
    return ctm ? pt.matrixTransform(ctm.inverse()) : { x: 0, y: 0 };
  };

  Flow.prototype.startDrag = function (e, id) {
    var stage = this.stageById(id);
    var p = this.svgPoint(e);
    this.drag = { id: id, dx: p.x - stage.position.x, dy: p.y - stage.position.y, sx: e.clientX, sy: e.clientY };
    this.dragged = false;
    this.svg.setPointerCapture(e.pointerId);
  };

  Flow.prototype.startConnect = function (e, from) {
    this.connect = { from: from };
    this.svg.setPointerCapture(e.pointerId);
    this.opts.tip.hide();
  };

  Flow.prototype.onPointerMove = function (e) {
    if (this.pan) {
      var dx = e.clientX - this.pan.x;
      var dy = e.clientY - this.pan.y;
      if (!this.pan.moved && Math.abs(dx) + Math.abs(dy) < 4) return;
      this.pan.moved = true;
      this.dragged = true;
      var scale = this.currentView().w / (this.svg.getBoundingClientRect().width || 1);
      this.panBy(-dx * scale, -dy * scale);
      this.pan.x = e.clientX;
      this.pan.y = e.clientY;
    } else if (this.drag) {
      if (Math.abs(e.clientX - this.drag.sx) + Math.abs(e.clientY - this.drag.sy) > 4) this.dragged = true;
      if (!this.dragged) return;
      var p = this.svgPoint(e);
      var stage = this.stageById(this.drag.id);
      stage.position = { x: snap(p.x - this.drag.dx), y: snap(p.y - this.drag.dy) };
      this.renderDiagram();
    } else if (this.connect) {
      var from = rectOf(this.stageById(this.connect.from));
      var q = this.svgPoint(e);
      var start = { x: from.x + from.w, y: from.cy };
      var midX = (start.x + q.x) / 2;
      this.connector.setAttribute("d", roundedPath([start, { x: midX, y: start.y }, { x: midX, y: q.y }, { x: q.x, y: q.y }]));
    }
  };

  Flow.prototype.onPointerUp = function (e) {
    var self = this;
    if (this.pan) {
      var moved = this.pan.moved;
      this.pan = null;
      // A pan isn't a click on the background (which clears the selection).
      if (moved) {
        setTimeout(function () {
          self.dragged = false;
        }, 0);
      }
    } else if (this.drag) {
      this.drag = null;
      // Let the click handler see whether this was a drag.
      setTimeout(function () {
        self.dragged = false;
      }, 0);
      if (this.dragged) this.lastKey = null;
    } else if (this.connect) {
      var target = document.elementFromPoint(e.clientX, e.clientY);
      var node = target && target.closest ? target.closest("[data-stage]") : null;
      var from = this.connect.from;
      this.connect = null;
      this.connector.setAttribute("d", "");
      if (node && node.getAttribute("data-stage") !== from) this.addTransition(from, node.getAttribute("data-stage"));
    }
  };

  // ------------------------------------------------------------------ editing: model

  Flow.prototype.enterEdit = function () {
    this.mode = "edit";
    this.draft = clone(this.data.definitions[this.team]);
    this.baseVersion = this.draft.version;
    this.errors = [];
    this.lastKey = null;
    this.opts.onFilter(null);
    this.render();
  };

  Flow.prototype.exitEdit = function () {
    this.mode = "view";
    this.draft = null;
    this.errors = [];
    this.saving = false;
    this.selected = null;
    this.lastKey = null;
    this.render();
  };

  Flow.prototype.addStage = function () {
    var d = this.draft;
    var maxX = d.stages.reduce(function (m, s) {
      return Math.max(m, s.position.x);
    }, 0);
    var minY = d.stages.reduce(function (m, s) {
      return Math.min(m, s.position.y);
    }, 160);
    var base = "new-stage";
    var id = base;
    var n = 1;
    while (this.stageById(id)) id = base + "-" + ++n;
    d.stages.push({
      id: id,
      name: "New stage",
      kind: "agent",
      linear_state: "In Progress",
      label: id,
      default: false,
      instructions: "",
      harness: null,
      effort: null,
      max_agents: null,
      paused: false,
      approval: false,
      position: { x: snap(maxX + 200), y: snap(minY) },
      _new: true
    });
    this.select({ type: "stage", id: id });
  };

  Flow.prototype.addTransition = function (from, to) {
    var d = this.draft;
    var exists = d.transitions.some(function (t) {
      return t.from === from && t.to === to;
    });
    if (!exists) d.transitions.push({ from: from, to: to, by: "agent", criteria: "" });
    this.select({ type: "edge", id: from + ">" + to });
  };

  Flow.prototype.deleteSelected = function () {
    var d = this.draft;
    var sel = this.selected;
    if (!d || !sel) return;
    if (sel.type === "stage") {
      d.stages = d.stages.filter(function (s) {
        return s.id !== sel.id;
      });
      d.transitions = d.transitions.filter(function (t) {
        return t.from !== sel.id && t.to !== sel.id;
      });
    } else {
      d.transitions = d.transitions.filter(function (t) {
        return t.from + ">" + t.to !== sel.id;
      });
    }
    this.select(null);
  };

  Flow.prototype.renameStage = function (stage, name) {
    stage.name = name;
    // New stages follow their name until saved; saved ids stay stable.
    if (stage._new) {
      var oldId = stage.id;
      var id = slugify(name);
      var self = this;
      var n = 1;
      var candidate = id;
      while (candidate !== oldId && this.stageById(candidate)) candidate = id + "-" + ++n;
      stage.id = candidate;
      if (stage.label === oldId) stage.label = candidate;
      this.draft.transitions.forEach(function (t) {
        if (t.from === oldId) t.from = candidate;
        if (t.to === oldId) t.to = candidate;
      });
      if (self.selected && self.selected.id === oldId) self.selected.id = candidate;
    }
  };

  Flow.prototype.save = function () {
    var self = this;
    var definition = clone(this.draft);
    delete definition._flowRequest;
    definition.stages.forEach(function (s) {
      delete s._new;
    });
    this.saving = true;
    this.renderToolbar();
    this.opts.push("factory_save", { team: this.team, version: this.baseVersion, definition: definition }, function (reply) {
      self.saving = false;
      if (reply && reply.ok) {
        self.data.definitions[self.team] = reply.definition;
        self.opts.toast("Saved the " + self.scopeLabel() + " flow (v" + reply.definition.version + ")", "ok");
        self.exitEdit();
      } else if (reply && reply.conflict) {
        self.errors = [
          (reply.conflict.updated_by || "Someone") + " saved a newer version while you were editing. Discard to load theirs, then redo your changes."
        ];
        self.render();
      } else {
        self.errors = (reply && reply.errors) || [(reply && reply.error) || "Save failed"];
        self.render();
      }
    });
  };

  // ------------------------------------------------------------------ drawer

  Flow.prototype.renderDrawer = function () {
    var drawer = this.drawer;
    var sel = this.selected;
    var definition = this.definition();
    if (!sel || !definition) {
      drawer.hidden = true;
      return;
    }
    drawer.hidden = false;
    drawer.textContent = "";
    if (sel.type === "stage") {
      var stage = this.stageById(sel.id);
      if (!stage) return void (drawer.hidden = true);
      if (this.mode === "edit") this.stageForm(drawer, stage);
      else this.stageView(drawer, stage);
    } else {
      var parts = sel.id.split(">");
      var t = definition.transitions.filter(function (x) {
        return x.from === parts[0] && x.to === parts[1];
      })[0];
      if (!t) return void (drawer.hidden = true);
      this.edgeView(drawer, t);
    }
  };

  Flow.prototype.drawerHead = function (drawer, title, subtitle) {
    var self = this;
    var head = el("div", "fx-drawer-head");
    var text = el("div");
    text.appendChild(el("h3", "fx-drawer-title", title));
    if (subtitle) text.appendChild(el("p", "fx-drawer-copy", subtitle));
    head.appendChild(text);
    var close = button("✕", "fx-icon-btn", function () {
      self.select(null);
    });
    close.setAttribute("aria-label", "Close");
    head.appendChild(close);
    drawer.appendChild(head);
  };

  Flow.prototype.stageView = function (drawer, stage) {
    var self = this;
    var info = this.flow().nodes[stage.id] || { issues: [], count: 0 };
    this.drawerHead(drawer, stage.name, KIND_LABEL[stage.kind] + " · " + stage.linear_state + (stage.label ? " + " + stage.label : ""));
    if (stage.instructions) drawer.appendChild(el("p", "fx-drawer-copy fx-instructions", stage.instructions));
    else drawer.appendChild(el("p", "fx-drawer-copy", KIND_HELP[stage.kind]));

    if (DISPATCHABLE[stage.kind]) this.controls(drawer, stage);

    var listHead = el("div", "fx-drawer-subhead");
    listHead.appendChild(el("span", null, info.count + (info.count === 1 ? " issue" : " issues")));
    listHead.appendChild(
      button("Show its spend", "fx-link-btn", function () {
        self.opts.onFilter(stage.id, stage.name, info.issues);
      })
    );
    drawer.appendChild(listHead);

    // Moves come from the flow: every human-moved connection out of here. An
    // issue held for approval gets Approve / Send back instead.
    var out = this.definition().transitions.filter(function (t) {
      return t.from === stage.id;
    });
    var humanMoves = out.filter(function (t) {
      return t.by === "human";
    });
    var movesFor = function () {
      return humanMoves;
    };
    var movable = this.data.movable_teams;
    var movableProjects = this.data.movable_projects || [];
    // Project flows hold issues from several teams: moving needs the issue's
    // team, or access to its project.
    var canMove = function (issue) {
      if (movable === "all" || (Array.isArray(movable) && movable.indexOf(issue.team) !== -1)) return true;
      return !!issue.project && movableProjects.indexOf(issue.project) !== -1;
    };

    var list = el("div", "fx-drawer-list");
    info.issues.forEach(function (issue) {
      var row = el("div", "fx-issue-row");
      var line = el("div", "fx-issue-info");
      var url = safeUrl(issue.url);
      var idEl = url ? el("a", "fx-issue-id", issue.issue) : el("span", "fx-issue-id", issue.issue);
      if (url) {
        idEl.href = url;
        idEl.target = "_blank";
        idEl.rel = "noopener";
      }
      line.appendChild(idEl);
      if (issue.backend) line.appendChild(el("span", "fx-dot h-" + issue.backend));
      line.appendChild(el("span", "fx-issue-title", issue.title || ""));
      if (issue.awaiting) {
        var next = issue.to && self.stageById(issue.to);
        line.appendChild(el("span", "fx-awaiting", "✋ approve" + (next ? " → " + next.name : "")));
      }
      line.appendChild(el("span", "fx-issue-age", since(issue.since_ms)));
      row.appendChild(line);

      // Held for approval: the agent already moved it here.
      if (issue.awaiting && issue.id && canMove(issue)) {
        var verdict = el("div", "fx-issue-actions");
        verdict.appendChild(button("✓ Approve", "fx-action is-primary", function () {
          self.opts.push("approve_issue", { id: issue.id }, function () {});
          self.opts.toast("Approved " + issue.issue, "ok");
        }));
        if (issue.from) {
          var origin = self.stageById(issue.from);
          verdict.appendChild(button("↩ Keep in " + (origin ? origin.name : issue.from), "fx-action", function () {
            self.opts.push("send_back_issue", { id: issue.id }, function () {});
            self.opts.toast("Sent " + issue.issue + " back", "ok");
          }));
        }
        row.appendChild(verdict);
      }

      var moves = issue.awaiting ? [] : movesFor(issue);
      if (moves.length && issue.id && canMove(issue)) {
        var actions = el("div", "fx-issue-actions");
        if (self.pending[issue.issue]) {
          actions.appendChild(el("span", "fx-pending", "Moving to " + self.pending[issue.issue] + "…"));
        } else {
          moves.forEach(function (t, i) {
            var target = self.stageById(t.to);
            var b = button("→ " + target.name, "fx-action" + (i === 0 ? " is-primary" : ""), function () {
              self.move(issue, target);
            });
            if (t.criteria) b.title = t.criteria;
            actions.appendChild(b);
          });
        }
        row.appendChild(actions);
      }
      list.appendChild(row);
    });
    if (!info.issues.length) list.appendChild(el("p", "fx-empty", "Nothing here right now."));
    drawer.appendChild(list);
  };

  Flow.prototype.move = function (issue, target) {
    var self = this;
    this.pending[issue.issue] = target.name;
    this.renderDrawer();
    this.opts.push("factory_move", { id: issue.id, to: target.id, team: this.team }, function (reply) {
      delete self.pending[issue.issue];
      if (reply && reply.ok) self.opts.toast(issue.issue + " → " + target.name, "ok");
      else self.opts.toast((reply && reply.error) || "Move failed", "error");
      self.renderDrawer();
    });
  };

  // One live stage control (view mode), applied immediately and rolled back if
  // the server refuses it. In edit mode it only changes the draft.
  Flow.prototype.setStageControl = function (stage, field, value, done) {
    var self = this;
    var previous = stage[field];
    stage[field] = value;
    this.lastKey = null;
    this.renderDiagram();
    this.renderDrawer();
    if (this.mode === "edit") return;
    var key = { harness: "backend" }[field] || field;
    this.opts.push("factory_control", { team: this.team, stage: stage.id, field: key, value: value }, function (reply) {
      if (reply && reply.ok) {
        if (done) done();
        return;
      }
      stage[field] = previous;
      self.lastKey = null;
      self.renderDiagram();
      self.renderDrawer();
      self.opts.toast((reply && reply.error) || "Change failed", "error");
    });
  };

  // Live stage controls (view mode): one field at a time, applied immediately.
  Flow.prototype.controls = function (drawer, stage) {
    var self = this;
    var enabled = this.canControl();
    var form = el("div", "fx-form");
    var set = function (field, value) {
      self.setStageControl(stage, field, value);
    };

    form.appendChild(
      row("Dispatch", "Start new agents here", toggle(!stage.paused, enabled, "Running", "Paused", function (on) {
        set("paused", !on);
      }))
    );
    form.appendChild(row("Max agents", "At once", stepper(stage.max_agents, enabled, this.data.capacity || 10, function (v) {
      set("max_agents", v);
    })));
    form.appendChild(row("Harness", "Issue labels still win", choice(harnessOptions(this.data.harnesses), stage.harness, enabled, function (v) {
      set("harness", v);
    })));
    form.appendChild(row("Thinking", "Issue labels still win", choice(effortOptions(), stage.effort, enabled, function (v) {
      set("effort", v);
    })));
    drawer.appendChild(form);
    if (!enabled) drawer.appendChild(el("p", "fx-drawer-note", "You can change this team's stage controls if you're a Linear admin or a member of the team."));
  };

  Flow.prototype.stageForm = function (drawer, stage) {
    var self = this;
    this.drawerHead(drawer, stage.name || "Stage", stage._new ? "New stage · id " + stage.id : "id " + stage.id);
    var form = el("div", "fx-form fx-form-edit");
    var rerender = function () {
      self.lastKey = null;
      self.renderDiagram();
    };

    form.appendChild(
      field("Name", input(stage.name, function (v) {
        self.renameStage(stage, v);
        rerender();
      }))
    );
    form.appendChild(
      field("Kind", choice(KINDS.map(function (k) {
        return [k, KIND_LABEL[k]];
      }), stage.kind, true, function (v) {
        stage.kind = v;
        rerender();
        self.renderDrawer();
      }), KIND_HELP[stage.kind])
    );

    var states = el("datalist");
    states.id = "fx-linear-states";
    (this.data.linear_states || []).forEach(function (s) {
      var o = el("option");
      o.value = s;
      states.appendChild(o);
    });
    form.appendChild(states);
    var stateInput = input(stage.linear_state, function (v) {
      stage.linear_state = v;
      rerender();
    });
    stateInput.setAttribute("list", "fx-linear-states");
    form.appendChild(field("Linear state", stateInput, "The workflow state issues in this stage are in."));

    var labelInput = input(stage.label || "", function (v) {
      stage.label = v.trim() ? v.trim().toLowerCase() : null;
      rerender();
    });
    labelInput.placeholder = "none";
    form.appendChild(
      field("Stage label", labelInput, "Shown in Linear as " + ((this.data.label_prefix || "factory") + "/" + (stage.label || "…")) + ". Leave empty if the state alone identifies the stage.")
    );

    var def = el("label", "fx-check");
    var box = el("input");
    box.type = "checkbox";
    box.checked = !!stage.default;
    box.addEventListener("change", function () {
      stage.default = box.checked;
    });
    def.appendChild(box);
    def.appendChild(document.createTextNode(" Default stage for issues in this state with no stage label"));
    form.appendChild(def);

    if (DISPATCHABLE[stage.kind]) {
      var gate = el("label", "fx-check");
      var gateBox = el("input");
      gateBox.type = "checkbox";
      gateBox.checked = !!stage.approval;
      gateBox.addEventListener("change", function () {
        stage.approval = gateBox.checked;
        rerender();
      });
      gate.appendChild(gateBox);
      gate.appendChild(document.createTextNode(" ✋ A person approves before the issue moves on"));
      form.appendChild(gate);
      form.appendChild(
        el(
          "p",
          "fx-field-hint",
          "The agent posts its work on the Linear ticket, recommends a move and adds the `" +
            (this.data.approval_label || "needs-approval") +
            "` label. The issue waits in Needs you until someone approves a move."
        )
      );
    }

    var instructions = el("textarea", "fx-textarea");
    instructions.rows = 6;
    instructions.value = stage.instructions || "";
    instructions.placeholder = "What should the agent do in this stage, and what does done look like?";
    instructions.addEventListener("input", function () {
      stage.instructions = instructions.value;
    });
    var instructionsField = field("Agent instructions", instructions, "Added to the agent's prompt while an issue is in this stage.");
    if (this.opts.assist) {
      instructionsField.appendChild(
        button("✦ Draft with AI", "fx-chip fx-assist-btn", function () {
          self.opts.assist(self.team, self.draft, stage, function (suggestion) {
            if (suggestion.instructions) stage.instructions = suggestion.instructions;
            if (suggestion.skill && suggestion.skill.content) stage.skill = suggestion.skill;
            if (suggestion.transitions) self.applySuggestedTransitions(stage, suggestion.transitions);
            rerender();
            self.renderDrawer();
          });
        })
      );
    }
    form.appendChild(instructionsField);

    if (DISPATCHABLE[stage.kind]) {
      var checks = el("textarea", "fx-textarea fx-mono");
      checks.rows = 3;
      checks.value = (stage.checks || []).join("\n");
      checks.placeholder = "services/test.sh -new-from origin/main";
      checks.addEventListener("input", function () {
        stage.checks = checks.value
          .split("\n")
          .map(function (line) {
            return line.trim();
          })
          .filter(Boolean);
      });
      form.appendChild(
        field("Checks before moving on", checks, "One shell command per line. Symphony runs them in the issue's workspace when the agent finishes; if any fails, the agent is told why and keeps working.")
      );
    }

    if (stage.skill && stage.skill.content) {
      var skillField = el("div", "fx-field");
      skillField.appendChild(el("span", "fx-field-label", "Skill · " + (stage.skill.path || "skill")));
      skillField.appendChild(el("pre", "fx-assist-text fx-skill-preview", stage.skill.content));
      skillField.appendChild(
        button("Remove skill", "fx-link-btn", function () {
          stage.skill = null;
          self.renderDrawer();
        })
      );
      form.appendChild(skillField);
    }

    if (DISPATCHABLE[stage.kind]) {
      form.appendChild(field("Harness", choice(harnessOptions(this.data.harnesses), stage.harness, true, function (v) {
        stage.harness = v;
        rerender();
      })));
      form.appendChild(field("Thinking", choice(effortOptions(), stage.effort, true, function (v) {
        stage.effort = v;
        rerender();
      })));
      form.appendChild(field("Max agents", stepper(stage.max_agents, true, this.data.capacity || 10, function (v) {
        stage.max_agents = v;
        rerender();
        self.renderDrawer();
      })));
    }

    drawer.appendChild(form);
    drawer.appendChild(button("Delete stage", "fx-action fx-danger", function () {
      self.deleteSelected();
    }));
  };

  Flow.prototype.applySuggestedTransitions = function (stage, suggested) {
    var d = this.draft;
    var self = this;
    suggested.forEach(function (t) {
      if (!self.stageById(t.from) || !self.stageById(t.to)) return;
      var existing = d.transitions.filter(function (x) {
        return x.from === t.from && x.to === t.to;
      })[0];
      if (existing) {
        existing.criteria = existing.criteria || t.criteria;
      } else {
        d.transitions.push({ from: t.from, to: t.to, by: t.by === "human" ? "human" : "agent", criteria: t.criteria || "" });
      }
    });
  };

  Flow.prototype.edgeView = function (drawer, t) {
    var self = this;
    var from = this.stageById(t.from);
    var to = this.stageById(t.to);
    this.drawerHead(drawer, (from ? from.name : t.from) + " → " + (to ? to.name : t.to), "Connection");
    var count = (this.flow().edges || {})[t.from + ">" + t.to] || 0;
    drawer.appendChild(el("p", "fx-drawer-copy", count + (count === 1 ? " issue has" : " issues have") + " taken this path."));

    if (this.mode !== "edit") {
      drawer.appendChild(el("p", "fx-drawer-copy", (t.by === "human" ? "A person moves issues along this connection" : "Agents move issues along this connection") + (t.criteria ? " when: " + t.criteria : ".")));
      return;
    }

    var form = el("div", "fx-form fx-form-edit");
    form.appendChild(
      field("Moved by", choice([["agent", "Agent"], ["human", "Person"]], t.by, true, function (v) {
        t.by = v;
        self.lastKey = null;
        self.renderDiagram();
      }), "Agents are told about agent moves; people get a button for person moves.")
    );
    var criteria = el("textarea", "fx-textarea");
    criteria.rows = 3;
    criteria.value = t.criteria || "";
    criteria.placeholder = "When should an issue take this path?";
    criteria.addEventListener("input", function () {
      t.criteria = criteria.value;
    });
    form.appendChild(field("When", criteria));
    drawer.appendChild(form);
    drawer.appendChild(button("Delete connection", "fx-action fx-danger", function () {
      self.deleteSelected();
    }));
  };

  // ------------------------------------------------------------------ form widgets

  function row(label, hint, control) {
    var r = el("div", "fx-form-row");
    var text = el("div", "fx-form-label");
    text.appendChild(el("span", null, label));
    if (hint) text.appendChild(el("small", null, hint));
    r.appendChild(text);
    r.appendChild(control);
    return r;
  }

  function field(label, control, hint) {
    var f = el("label", "fx-field");
    f.appendChild(el("span", "fx-field-label", label));
    f.appendChild(control);
    if (hint) f.appendChild(el("small", "fx-field-hint", hint));
    return f;
  }

  function input(value, onInput) {
    var i = el("input", "fx-input");
    i.value = value || "";
    i.addEventListener("input", function () {
      onInput(i.value);
    });
    return i;
  }

  function toggle(on, enabled, onLabel, offLabel, onChange) {
    var b = el("button", "fx-switch" + (on ? " is-on" : ""));
    b.type = "button";
    b.setAttribute("role", "switch");
    b.setAttribute("aria-checked", on ? "true" : "false");
    b.disabled = !enabled;
    b.appendChild(el("span", "fx-switch-knob"));
    b.appendChild(el("span", "fx-switch-label", on ? onLabel : offLabel));
    b.addEventListener("click", function () {
      onChange(!on);
    });
    return b;
  }

  function stepper(value, enabled, capacity, onChange) {
    var wrap = el("div", "fx-stepper");
    var minus = button("−", "fx-step");
    var plus = button("+", "fx-step");
    minus.disabled = !enabled;
    plus.disabled = !enabled || !value;
    minus.setAttribute("aria-label", "Fewer agents");
    plus.setAttribute("aria-label", "More agents");
    minus.addEventListener("click", function () {
      onChange(value ? Math.max(1, value - 1) : Math.max(1, capacity - 1));
    });
    plus.addEventListener("click", function () {
      if (value) onChange(value + 1 >= capacity ? null : value + 1);
    });
    wrap.appendChild(minus);
    wrap.appendChild(el("span", "fx-step-value", value ? String(value) : "No cap"));
    wrap.appendChild(plus);
    return wrap;
  }

  function choice(options, current, enabled, onPick) {
    var wrap = el("div", "fx-seg fx-seg-small");
    options.forEach(function (option) {
      var active = option[0] === (current === undefined ? null : current);
      var b = el("button", "fx-seg-btn" + (active ? " is-active" : ""));
      b.type = "button";
      b.disabled = !enabled;
      if (option[2]) b.appendChild(el("span", "fx-dot h-" + option[2]));
      b.appendChild(document.createTextNode(option[1]));
      b.addEventListener("click", function () {
        onPick(option[0]);
      });
      wrap.appendChild(b);
    });
    return wrap;
  }

  // Mirrors Definition.requires_approval?: "✋ always", "✋ 3/10"
  // (earning autonomy), "✓ trusted" (earned it), or "" when no approval applies.
  function autopilotOf(definition) {
    var a = (definition && definition.autopilot) || {};
    return { enabled: a.enabled === true, streak: a.streak || 10 };
  }

  function approvalState(definition, stage) {
    if (stage.approval) return "✋ always";
    if (stage.kind !== "agent") return "";
    var a = autopilotOf(definition);
    if (!a.enabled) return "";
    var n = stage.approval_streak || 0;
    return n >= a.streak ? "✓ trusted" : "✋ " + n + "/" + a.streak;
  }

  function harnessOptions(harnesses) {
    return [[null, "Default"]].concat(
      (harnesses || []).map(function (h) {
        return [h, HARNESS_LABELS[h] || h, h];
      })
    );
  }

  function effortOptions() {
    return [[null, "Default"]].concat(
      EFFORTS.map(function (e) {
        return [e, e.charAt(0).toUpperCase() + e.slice(1)];
      })
    );
  }

  window.SymphonyFlow = {
    create: function (opts) {
      return new Flow(opts);
    },
    // Exposed for tests.
    _routeAll: routeAll
  };
})();
