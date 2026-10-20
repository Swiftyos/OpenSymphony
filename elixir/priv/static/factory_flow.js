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

    this.svg = svg("svg", { class: "fx-diagram", role: "img", "aria-label": "Agent factory process diagram" });
    slot.appendChild(this.svg);

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
      if (self.mode !== "edit" || !self.selected) return;
      var tag = (e.target && e.target.tagName) || "";
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
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
      this.team = [hash && hash[1], saved, data.team, teams[0]].filter(function (t) {
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
    root.setAttribute("viewBox", box.x + " " + box.y + " " + box.w + " " + box.h);
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

    var label = svg("text", { x: 14, y: 24, class: "fx-node-label" });
    label.textContent = stage.name.length > 18 ? stage.name.slice(0, 17) + "…" : stage.name;
    g.appendChild(label);

    var kind = svg("text", { x: r.w - 14, y: 24, "text-anchor": "end", class: "fx-node-kind fx-node-kind-" + stage.kind });
    kind.textContent = stage.kind === "done" ? "✓" : stage.kind === "parked" ? "⏸" : stage.kind === "human" ? "◐" : stage.kind === "queue" ? "≡" : "";
    g.appendChild(kind);

    var count = svg("text", { x: 14, y: 58, class: "fx-node-count" });
    count.textContent = String(info.count);
    g.appendChild(count);

    var running = info.issues.filter(function (i) {
      return i.backend;
    });
    running.slice(0, 6).forEach(function (issue, i) {
      g.appendChild(svg("circle", { cx: r.w - 16 - i * 12, cy: 53, r: 4.5, class: "fx-agent-dot h-" + issue.backend }));
    });

    var config = [];
    if (stage.paused) config.push("paused");
    if (stage.harness) config.push(HARNESS_LABELS[stage.harness] || stage.harness);
    if (stage.effort) config.push(stage.effort);
    if (stage.max_agents) config.push("≤" + stage.max_agents);
    if (stage.label) config.unshift(stage.label);
    if (config.length) {
      var line = svg("text", { x: 14, y: r.h + 14, class: "fx-node-config" + (stage.paused ? " is-paused" : "") });
      line.textContent = config.join(" · ");
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
      if (self.mode === "edit") self.startDrag(e, stage.id);
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
    if (this.drag) {
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
    if (this.drag) {
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

    // Moves come from the team's flow: every human-moved connection out of here.
    var moves = this.definition().transitions.filter(function (t) {
      return t.from === stage.id && t.by === "human";
    });
    var movable = this.data.movable_teams;
    // Project flows hold issues from several teams: moving needs the issue's team.
    var canMove = function (issue) {
      return movable === "all" || (Array.isArray(movable) && movable.indexOf(issue.team) !== -1);
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
      line.appendChild(el("span", "fx-issue-age", since(issue.since_ms)));
      row.appendChild(line);

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

  // Live stage controls (view mode): one field at a time, applied immediately.
  Flow.prototype.controls = function (drawer, stage) {
    var self = this;
    var enabled = this.canControl();
    var form = el("div", "fx-form");
    var set = function (field, value) {
      var key = { harness: "backend" }[field] || field;
      var previous = stage[field];
      stage[field] = value;
      self.lastKey = null;
      self.renderDiagram();
      self.renderDrawer();
      self.opts.push("factory_control", { team: self.team, stage: stage.id, field: key, value: value }, function (reply) {
        if (reply && reply.ok) return;
        stage[field] = previous;
        self.lastKey = null;
        self.renderDiagram();
        self.renderDrawer();
        self.opts.toast((reply && reply.error) || "Change failed", "error");
      });
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
