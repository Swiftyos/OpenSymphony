// Agent Factory panel: live process diagram + cost explorer.
//
// The server pushes one JSON payload per orchestrator update (data-json on
// #factory-data). Everything interactive - grouping, metric switch, harness
// toggles, search, node filters, hover - runs here against that payload, so
// interactions never wait on a LiveView round-trip.
(function () {
  "use strict";

  var SVG_NS = "http://www.w3.org/2000/svg";
  var HARNESS_LABELS = { codex: "Codex", claude: "Claude Code", opencode: "OpenCode" };
  var GROUP_LABELS = { project: "Project", team: "Team", issue: "Task" };
  var AGENT_STAGES = { todo: 1, implement: 1, rework: 1, merge: 1 };
  var EFFORTS = ["low", "medium", "high", "max"];
  var STAGE_COPY = {
    todo: "Queued. An agent picks it up and moves it to In Progress.",
    implement: "Agents build, validate, and open a PR, then hand off to review.",
    review: "Waiting on a human. Approve to merge, or send back for rework.",
    rework: "A reviewer asked for a reset. Agents redo the approach.",
    merge: "Approved. Agents land the PR and mark the issue Done.",
    blocked: "Parked. Symphony will not dispatch it until it is unblocked.",
    done: "Shipped."
  };
  // Issue moves per stage: [action, label, primary?]
  var STAGE_ACTIONS = {
    review: [["approve", "Approve & merge", true], ["rework", "Send to rework"]],
    blocked: [["unblock", "Unblock"], ["to_review", "Back to review"]],
    implement: [["to_review", "Move to review"], ["block", "Block"]],
    rework: [["block", "Block"]],
    merge: [["to_review", "Back to review"], ["block", "Block"]],
    todo: [["block", "Block"]]
  };
  var MOVE_TARGET = { approve: "merge", rework: "rework", block: "blocked", unblock: "implement", to_review: "review" };
  var MAX_ROWS = 12;

  var VIEW_W = 1000;
  var VIEW_H = 318;
  var NODE_W = 142;
  var NODE_H = 72;
  var NODE_POS = {
    todo: [78, 165],
    implement: [290, 165],
    review: [500, 165],
    merge: [710, 165],
    done: [918, 165],
    rework: [395, 280],
    blocked: [500, 44]
  };
  // Edges that run "backwards" through the factory get a deeper arc.
  var LOOP_EDGES = { "review>implement": 1, "review>rework": 1, "rework>implement": 1, "rework>review": 1, "merge>review": 1 };

  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------------------------------------------------------------- helpers

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function svg(tag, attrs) {
    var node = document.createElementNS(SVG_NS, tag);
    for (var key in attrs) node.setAttribute(key, attrs[key]);
    return node;
  }

  function compact(n) {
    n = n || 0;
    if (n >= 1e9) return (n / 1e9).toFixed(n >= 1e10 ? 0 : 1) + "B";
    if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + "M";
    if (n >= 1e3) return (n / 1e3).toFixed(n >= 1e4 ? 0 : 1) + "k";
    return String(Math.round(n));
  }

  function money(n) {
    if (n === null || n === undefined) return "—";
    if (n >= 1000) return "$" + Math.round(n).toLocaleString();
    if (n >= 100) return "$" + n.toFixed(0);
    if (n >= 1) return "$" + n.toFixed(2);
    return "$" + n.toFixed(3);
  }

  // Only https links are rendered; anything else (javascript:, data:) is dropped.
  function safeUrl(url) {
    return typeof url === "string" && /^https:\/\//i.test(url) ? url : null;
  }

  function since(ms) {
    if (!ms) return "";
    var s = Math.max(0, (Date.now() - ms) / 1000);
    if (s < 90) return Math.round(s) + "s";
    if (s < 5400) return Math.round(s / 60) + "m";
    if (s < 129600) return Math.round(s / 3600) + "h";
    return Math.round(s / 86400) + "d";
  }

  // ---------------------------------------------------------------- panel

  function Panel(root) {
    this.root = root;
    this.data = null;
    this.flowKey = null;
    this.state = { group: "project", metric: null, hidden: {}, query: "", node: null, drawer: null, pending: {}, table: false };
    try {
      var saved = JSON.parse(window.localStorage.getItem("symphony.factory") || "{}");
      if (saved.group) this.state.group = saved.group;
      if (saved.metric) this.state.metric = saved.metric;
      if (saved.table) this.state.table = true;
    } catch (_e) {}
    this.build();
  }

  Panel.prototype.persist = function () {
    try {
      window.localStorage.setItem(
        "symphony.factory",
        JSON.stringify({ group: this.state.group, metric: this.state.metric, table: this.state.table })
      );
    } catch (_e) {}
  };

  Panel.prototype.build = function () {
    var self = this;
    var root = this.root;
    var slot = function (name) {
      // Slots live in different page sections, so look them up document-wide.
      var node = document.querySelector('[data-fx="' + name + '"]');
      node.textContent = "";
      return node;
    };

    this.stats = slot("stats");

    this.diagram = svg("svg", {
      viewBox: "0 0 " + VIEW_W + " " + VIEW_H,
      class: "fx-diagram",
      role: "img",
      "aria-label": "Agent factory process diagram"
    });
    var diagramSlot = slot("diagram");
    diagramSlot.classList.add("fx-diagram-slot");
    diagramSlot.appendChild(this.diagram);
    // The stage drawer overlays the "Needs you" rail so the whole diagram stays visible.
    var drawerSlot = slot("drawer");
    this.drawer = el("div", "fx-drawer");
    this.drawer.hidden = true;
    drawerSlot.appendChild(this.drawer);

    var explorer = slot("explorer");
    var controls = el("div", "fx-controls");
    this.groupSeg = this.segmented(["project", "team", "issue"], GROUP_LABELS, function (value) {
      self.state.group = value;
      self.persist();
      self.renderExplorer();
    });
    controls.appendChild(this.groupSeg);
    this.metricSeg = this.segmented(["cost", "tokens"], { cost: "Cost", tokens: "Tokens" }, function (value) {
      self.state.metric = value;
      self.persist();
      self.renderExplorer();
    });
    controls.appendChild(this.metricSeg);

    this.search = el("input", "fx-search");
    this.search.type = "search";
    this.search.placeholder = "Filter…";
    this.search.setAttribute("aria-label", "Filter projects, teams, tasks, harnesses");
    this.search.addEventListener("input", function () {
      self.state.query = self.search.value.trim().toLowerCase();
      self.renderExplorer();
    });
    controls.appendChild(this.search);

    this.nodeChip = el("button", "fx-chip fx-node-chip");
    this.nodeChip.type = "button";
    this.nodeChip.hidden = true;
    this.nodeChip.addEventListener("click", function () {
      self.state.node = null;
      self.renderDrawer();
      self.renderExplorer();
    });
    controls.appendChild(this.nodeChip);

    this.legend = el("div", "fx-legend");
    controls.appendChild(this.legend);

    this.tableToggle = el("button", "fx-chip fx-table-toggle", "Table");
    this.tableToggle.type = "button";
    this.tableToggle.addEventListener("click", function () {
      self.state.table = !self.state.table;
      self.persist();
      self.renderExplorer();
    });
    controls.appendChild(this.tableToggle);
    explorer.appendChild(controls);

    this.exCopy = el("p", "fx-explorer-note");
    explorer.appendChild(this.exCopy);
    this.bars = el("div", "fx-bars");
    explorer.appendChild(this.bars);
    this.table = el("div", "fx-table-wrap");
    explorer.appendChild(this.table);

    // One fixed-position tooltip for every slot.
    this.tooltip = document.getElementById("fx-tooltip") || el("div", "fx-tooltip");
    this.tooltip.id = "fx-tooltip";
    this.tooltip.setAttribute("role", "tooltip");
    document.body.appendChild(this.tooltip);
  };

  Panel.prototype.segmented = function (values, labels, onPick) {
    var wrap = el("div", "fx-seg");
    wrap.setAttribute("role", "radiogroup");
    values.forEach(function (value) {
      var button = el("button", "fx-seg-btn", labels[value]);
      button.type = "button";
      button.dataset.value = value;
      button.setAttribute("role", "radio");
      button.addEventListener("click", function () {
        onPick(value);
      });
      wrap.appendChild(button);
    });
    return wrap;
  };

  Panel.prototype.syncSegmented = function (wrap, active) {
    Array.prototype.forEach.call(wrap.children, function (button) {
      var on = button.dataset.value === active;
      button.classList.toggle("is-active", on);
      button.setAttribute("aria-checked", on ? "true" : "false");
    });
  };

  Panel.prototype.setData = function (data) {
    if (!this.data) {
      // Deep link: #stage=review opens that stage's drawer.
      var match = /stage=([a-z]+)/.exec(window.location.hash || "");
      if (match) this.state.drawer = match[1];
    }
    this.data = data;
    if (!this.state.metric) this.state.metric = data.priced ? "cost" : "tokens";
    var flowKey = JSON.stringify([data.flow, data.controls]);
    if (flowKey !== this.flowKey) {
      this.flowKey = flowKey;
      this.renderDiagram();
      this.renderDrawer();
    }
    this.renderExplorer();
  };

  // ---------------------------------------------------------------- tooltip

  Panel.prototype.showTooltip = function (event, build) {
    var tip = this.tooltip;
    tip.textContent = "";
    build(tip);
    tip.classList.add("is-visible");
    this.moveTooltip(event);
  };

  Panel.prototype.moveTooltip = function (event) {
    var tip = this.tooltip;
    var x = event.clientX + 16;
    var y = event.clientY + 16;
    if (x + tip.offsetWidth > window.innerWidth - 8) x = event.clientX - tip.offsetWidth - 16;
    if (y + tip.offsetHeight > window.innerHeight - 8) y = event.clientY - tip.offsetHeight - 16;
    tip.style.transform = "translate(" + Math.max(8, x) + "px," + Math.max(8, y) + "px)";
  };

  Panel.prototype.hideTooltip = function () {
    this.tooltip.classList.remove("is-visible");
  };

  function tipValue(parent, value, label) {
    var row = el("div", "fx-tip-head");
    row.appendChild(el("strong", "fx-tip-value", value));
    if (label) row.appendChild(el("span", "fx-tip-label", label));
    parent.appendChild(row);
  }

  function tipLine(parent, keyClass, label, value) {
    var row = el("div", "fx-tip-row");
    if (keyClass) row.appendChild(el("span", "fx-tip-key " + keyClass));
    row.appendChild(el("span", "fx-tip-row-label", label));
    row.appendChild(el("span", "fx-tip-row-value", value));
    parent.appendChild(row);
  }

  // ---------------------------------------------------------------- diagram

  function nodeRect(id) {
    var p = NODE_POS[id];
    var w = id === "done" || id === "todo" ? NODE_W - 24 : NODE_W;
    return { x: p[0] - w / 2, y: p[1] - NODE_H / 2, w: w, h: NODE_H, cx: p[0], cy: p[1] };
  }

  function inside(rect, x, y, pad) {
    return x > rect.x - pad && x < rect.x + rect.w + pad && y > rect.y - pad && y < rect.y + rect.h + pad;
  }

  function quad(a, c, b, t) {
    var u = 1 - t;
    return [u * u * a[0] + 2 * u * t * c[0] + t * t * b[0], u * u * a[1] + 2 * u * t * c[1] + t * t * b[1]];
  }

  // First/last t where the curve leaves the source / enters the target rect.
  function clip(a, c, b, rect, fromStart) {
    var lo = fromStart ? 0 : 0.5;
    var hi = fromStart ? 0.5 : 1;
    for (var i = 0; i < 18; i++) {
      var mid = (lo + hi) / 2;
      var p = quad(a, c, b, mid);
      var inRect = inside(rect, p[0], p[1], 6);
      if (fromStart ? inRect : !inRect) lo = mid;
      else hi = mid;
    }
    return fromStart ? hi : lo;
  }

  function edgeGeometry(edge, pairs) {
    var from = nodeRect(edge.from);
    var to = nodeRect(edge.to);
    var a = [from.cx, from.cy];
    var b = [to.cx, to.cy];
    var dx = b[0] - a[0];
    var dy = b[1] - a[1];
    var len = Math.sqrt(dx * dx + dy * dy) || 1;
    var nx = -dy / len;
    var ny = dx / len;
    var key = edge.from + ">" + edge.to;
    var bend = LOOP_EDGES[key] ? 70 : pairs[edge.to + ">" + edge.from] ? 26 : 0;
    var c = [(a[0] + b[0]) / 2 + nx * bend, (a[1] + b[1]) / 2 + ny * bend];
    var t0 = clip(a, c, b, from, true);
    var t1 = clip(a, c, b, to, false);
    // Re-express the clipped sub-curve as its own quadratic (de Casteljau).
    var p0 = quad(a, c, b, t0);
    var p2 = quad(a, c, b, t1);
    var cx = (1 - t0) * ((1 - t1) * a[0] + t1 * c[0]) + t0 * ((1 - t1) * c[0] + t1 * b[0]);
    var cy = (1 - t0) * ((1 - t1) * a[1] + t1 * c[1]) + t0 * ((1 - t1) * c[1] + t1 * b[1]);
    var mid = quad(p0, [cx, cy], p2, 0.5);
    return { d: "M" + p0[0] + "," + p0[1] + " Q" + cx + "," + cy + " " + p2[0] + "," + p2[1], mid: mid };
  }

  Panel.prototype.renderDiagram = function () {
    var self = this;
    var flow = this.data.flow;
    var root = this.diagram;
    root.textContent = "";

    var defs = svg("defs", {});
    ["idle", "live", "loop"].forEach(function (kind) {
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
    var glow = svg("radialGradient", { id: "fx-node-glow" });
    glow.appendChild(svg("stop", { offset: "0%", class: "fx-glow-stop-a" }));
    glow.appendChild(svg("stop", { offset: "100%", class: "fx-glow-stop-b" }));
    defs.appendChild(glow);
    root.appendChild(defs);

    var pairs = {};
    flow.edges.forEach(function (edge) {
      pairs[edge.from + ">" + edge.to] = true;
    });
    var maxCount = flow.edges.reduce(function (m, e) {
      return Math.max(m, e.count);
    }, 1);

    var edgeLayer = svg("g", { class: "fx-edges" });
    var labelLayer = svg("g", { class: "fx-edge-labels" });
    var particleLayer = svg("g", { class: "fx-particles" });
    root.appendChild(edgeLayer);
    root.appendChild(particleLayer);

    flow.edges.forEach(function (edge, index) {
      var geo = edgeGeometry(edge, pairs);
      var key = edge.from + ">" + edge.to;
      var loop = !!LOOP_EDGES[key];
      var live = edge.count > 0;
      var kind = !edge.expected ? "loop" : live ? (loop ? "loop" : "live") : "idle";
      var width = live ? 1.5 + 4.5 * Math.sqrt(edge.count / maxCount) : 1.25;
      var id = "fx-edge-" + index;

      var path = svg("path", {
        id: id,
        d: geo.d,
        class: "fx-edge fx-edge-" + kind + (loop ? " fx-edge-is-loop" : ""),
        "stroke-width": width.toFixed(2),
        "marker-end": "url(#fx-arrow-" + kind + ")"
      });
      edgeLayer.appendChild(path);

      // Wide transparent hit target so the edge is easy to hover.
      var hit = svg("path", { d: geo.d, class: "fx-edge-hit" });
      hit.addEventListener("pointerenter", function (event) {
        path.classList.add("is-hover");
        self.showTooltip(event, function (tip) {
          tipValue(tip, edge.count.toLocaleString(), edge.count === 1 ? "transition" : "transitions");
          tipLine(tip, null, labelFor(flow, edge.from) + " → " + labelFor(flow, edge.to), "");
          if (loop) tipLine(tip, null, "Loop back through the factory", "");
          if (!edge.expected) tipLine(tip, null, "Outside the designed flow", "");
        });
      });
      hit.addEventListener("pointermove", function (event) {
        self.moveTooltip(event);
      });
      hit.addEventListener("pointerleave", function () {
        path.classList.remove("is-hover");
        self.hideTooltip();
      });
      edgeLayer.appendChild(hit);

      if (live) {
        var chip = svg("g", { class: "fx-edge-chip" + (loop ? " fx-edge-chip-loop" : ""), transform: "translate(" + geo.mid[0] + "," + geo.mid[1] + ")" });
        var text = compact(edge.count);
        var w = 12 + text.length * 7;
        chip.appendChild(svg("rect", { x: -w / 2, y: -10, width: w, height: 20, rx: 10 }));
        var t = svg("text", { "text-anchor": "middle", y: "4" });
        t.textContent = text;
        chip.appendChild(t);
        labelLayer.appendChild(chip);

        if (!reduceMotion) {
          var particles = Math.min(4, 1 + Math.floor(Math.log(edge.count) / Math.LN2));
          var dur = (loop ? 3.2 : 2.4) + (index % 3) * 0.3;
          for (var i = 0; i < particles; i++) {
            var dot = svg("circle", { r: loop ? "2.6" : "2.2", class: "fx-particle" + (loop ? " fx-particle-loop" : "") });
            var motion = svg("animateMotion", {
              dur: dur + "s",
              repeatCount: "indefinite",
              begin: ((dur / particles) * i).toFixed(2) + "s",
              rotate: "auto"
            });
            var mpath = svg("mpath", {});
            mpath.setAttribute("href", "#" + id);
            motion.appendChild(mpath);
            dot.appendChild(motion);
            particleLayer.appendChild(dot);
          }
        }
      }
    });

    var nodeLayer = svg("g", { class: "fx-nodes" });
    root.appendChild(nodeLayer);
    root.appendChild(labelLayer);
    this.nodeEls = {};

    flow.nodes.forEach(function (node) {
      var r = nodeRect(node.id);
      var g = svg("g", {
        class: "fx-node fx-node-" + node.id + (node.running > 0 ? " is-running" : "") + (node.count === 0 ? " is-empty" : ""),
        transform: "translate(" + r.x + "," + r.y + ")",
        tabindex: "0",
        role: "button",
        "aria-label": node.label + ": " + node.count + " issues, " + node.running + " agents running"
      });
      if (node.running > 0) g.appendChild(svg("rect", { x: -18, y: -18, width: r.w + 36, height: r.h + 36, rx: 30, class: "fx-node-halo", fill: "url(#fx-node-glow)" }));
      g.appendChild(svg("rect", { width: r.w, height: r.h, rx: 16, class: "fx-node-box" }));

      var label = svg("text", { x: 16, y: 26, class: "fx-node-label" });
      label.textContent = node.label;
      g.appendChild(label);

      if (node.id === "blocked" || node.id === "done") {
        var icon = svg("text", { x: r.w - 16, y: 26, "text-anchor": "end", class: "fx-node-icon fx-node-icon-" + node.id });
        icon.textContent = node.id === "done" ? "✓" : "⏸";
        g.appendChild(icon);
      }

      var controls = self.data.controls && self.data.controls[node.id];
      if (controls) {
        if (controls.paused) g.classList.add("is-paused");
        var parts = [];
        if (controls.paused) parts.push("paused");
        if (controls.backend) parts.push(HARNESS_LABELS[controls.backend] || controls.backend);
        if (controls.effort) parts.push(controls.effort);
        if (controls.max_agents) parts.push("≤" + controls.max_agents);
        if (parts.length) {
          var config = svg("text", { x: 16, y: r.h + 15, class: "fx-node-config" + (controls.paused ? " is-paused" : "") });
          config.textContent = parts.join(" · ");
          g.appendChild(config);
        }
      }

      var count = svg("text", { x: 16, y: 60, class: "fx-node-count" });
      count.textContent = compact(node.count);
      g.appendChild(count);

      var state = svg("text", { x: r.w - 16, y: 60, "text-anchor": "end", class: "fx-node-state" });
      state.textContent = node.id === "rework" || node.id === "merge" || node.id === "blocked" || node.id === "implement" ? "In Progress" : "";
      if (node.running === 0) g.appendChild(state);

      // Running agents: one dot per agent, colored by its harness.
      var running = node.issues.filter(function (issue) {
        return issue.backend;
      });
      running.slice(0, 6).forEach(function (issue, i) {
        g.appendChild(svg("circle", { cx: r.w - 18 - i * 13, cy: 55, r: 4.5, class: "fx-agent-dot h-" + issue.backend }));
      });

      var select = function () {
        self.state.drawer = self.state.drawer === node.id ? null : node.id;
        self.hideTooltip();
        self.renderDiagramSelection();
        self.renderDrawer();
      };
      g.addEventListener("click", select);
      g.addEventListener("keydown", function (event) {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          select();
        }
      });
      g.addEventListener("pointerenter", function (event) {
        self.showTooltip(event, function (tip) {
          tipValue(tip, node.count.toLocaleString(), node.count === 1 ? "issue in " + node.label : "issues in " + node.label);
          if (node.running) tipLine(tip, null, "Agents running", String(node.running));
          node.issues.slice(0, 8).forEach(function (issue) {
            tipLine(tip, issue.backend ? "h-" + issue.backend : null, issue.issue + "  " + (issue.title || ""), since(issue.since_ms));
          });
          if (node.issues.length > 8) tipLine(tip, null, "+" + (node.issues.length - 8) + " more", "");
          tipLine(tip, null, "Click to manage this stage", "");
        });
      });
      g.addEventListener("pointermove", function (event) {
        self.moveTooltip(event);
      });
      g.addEventListener("pointerleave", function () {
        self.hideTooltip();
      });
      nodeLayer.appendChild(g);
      self.nodeEls[node.id] = g;
    });

    this.renderDiagramSelection();
  };

  function labelFor(flow, id) {
    for (var i = 0; i < flow.nodes.length; i++) if (flow.nodes[i].id === id) return flow.nodes[i].label;
    return id;
  }

  Panel.prototype.renderDiagramSelection = function () {
    var active = this.state.drawer;
    try {
      var hash = active ? "#stage=" + active : "";
      if (window.location.hash !== hash)
        window.history.replaceState(null, "", window.location.pathname + window.location.search + hash);
    } catch (_e) {}
    for (var id in this.nodeEls || {}) this.nodeEls[id].classList.toggle("is-selected", id === active);
    this.diagram.classList.toggle("has-selection", !!active);
  };

  // ---------------------------------------------------------------- drawer (stage controls)

  Panel.prototype.push = function (event, payload, onReply) {
    if (!this.hook) {
      onReply({ ok: false, error: "Not connected to the server" });
      return;
    }
    this.hook.pushEvent(event, payload, onReply);
  };

  Panel.prototype.toast = function (message, tone) {
    var toast = this.toastEl || (this.toastEl = el("div", "fx-toast"));
    if (!toast.parentNode) document.body.appendChild(toast);
    toast.textContent = message;
    toast.className = "fx-toast is-visible" + (tone ? " fx-toast-" + tone : "");
    clearTimeout(this._toastTimer);
    this._toastTimer = setTimeout(function () {
      toast.className = "fx-toast";
    }, 3200);
  };

  Panel.prototype.setControl = function (stage, field, value) {
    var self = this;
    var controls = this.data.controls[stage];
    var previous = controls[field];
    if (previous === value) return;
    controls[field] = value; // optimistic: repaint now, reconcile on reply
    this.flowKey = null;
    this.renderDiagram();
    this.renderDrawer();
    this.push("factory_control", { stage: stage, field: field, value: value }, function (reply) {
      if (reply && reply.ok) return;
      controls[field] = previous;
      self.flowKey = null;
      self.renderDiagram();
      self.renderDrawer();
      self.toast((reply && reply.error) || "Change failed", "error");
    });
  };

  Panel.prototype.moveIssue = function (issue, action, label) {
    var self = this;
    var key = issue.issue;
    this.state.pending[key] = label;
    this.renderDrawer();
    this.push(
      "factory_move",
      { id: issue.id, action: action },
      function (reply) {
        delete self.state.pending[key];
        if (reply && reply.ok) {
          self.toast(key + " → " + labelFor(self.data.flow, MOVE_TARGET[action]), "ok");
        } else {
          self.toast((reply && reply.error) || "Move failed", "error");
        }
        self.renderDrawer();
      }
    );
  };

  Panel.prototype.renderDrawer = function () {
    var self = this;
    var drawer = this.drawer;
    var id = this.state.drawer;
    if (!drawer) return;
    var node = null;
    if (id && this.data)
      this.data.flow.nodes.forEach(function (n) {
        if (n.id === id) node = n;
      });
    if (!node) {
      drawer.hidden = true;
      return;
    }
    var enabled = !!this.data.controls_enabled;
    drawer.hidden = false;
    drawer.textContent = "";

    var head = el("div", "fx-drawer-head");
    var title = el("div");
    title.appendChild(el("h3", "fx-drawer-title", node.label));
    title.appendChild(el("p", "fx-drawer-copy", STAGE_COPY[id] || ""));
    head.appendChild(title);
    var close = el("button", "fx-icon-btn", "✕");
    close.type = "button";
    close.setAttribute("aria-label", "Close stage panel");
    close.addEventListener("click", function () {
      self.state.drawer = null;
      self.renderDiagramSelection();
      self.renderDrawer();
    });
    head.appendChild(close);
    drawer.appendChild(head);

    var controls = this.data.controls && this.data.controls[id];
    if (AGENT_STAGES[id] && controls) {
      var form = el("div", "fx-form");

      var dispatchRow = this.formRow("Dispatch", "Start new agents in this stage");
      var toggle = el("button", "fx-switch" + (controls.paused ? "" : " is-on"));
      toggle.type = "button";
      toggle.setAttribute("role", "switch");
      toggle.setAttribute("aria-checked", controls.paused ? "false" : "true");
      toggle.disabled = !enabled;
      toggle.appendChild(el("span", "fx-switch-knob"));
      toggle.appendChild(el("span", "fx-switch-label", controls.paused ? "Paused" : "Running"));
      toggle.addEventListener("click", function () {
        self.setControl(id, "paused", !controls.paused);
      });
      dispatchRow.appendChild(toggle);
      form.appendChild(dispatchRow);

      var capRow = this.formRow("Max agents", "At once, in this stage");
      var stepper = el("div", "fx-stepper");
      var minus = el("button", "fx-step", "−");
      var plus = el("button", "fx-step", "+");
      minus.type = "button";
      plus.type = "button";
      minus.disabled = !enabled;
      plus.disabled = !enabled;
      minus.setAttribute("aria-label", "Fewer agents");
      plus.setAttribute("aria-label", "More agents");
      var cap = controls.max_agents;
      var capacity = this.data.capacity || 10;
      minus.addEventListener("click", function () {
        self.setControl(id, "max_agents", cap ? Math.max(1, cap - 1) : Math.max(1, capacity - 1));
      });
      plus.addEventListener("click", function () {
        if (!cap) return;
        self.setControl(id, "max_agents", cap + 1 >= capacity ? null : cap + 1);
      });
      stepper.appendChild(minus);
      stepper.appendChild(el("span", "fx-step-value", cap ? String(cap) : "No cap"));
      stepper.appendChild(plus);
      capRow.appendChild(stepper);
      form.appendChild(capRow);

      var harnessRow = this.formRow("Harness", "Issue labels still win");
      harnessRow.appendChild(
        this.choice(
          [[null, "Default"]].concat(
            this.data.harnesses.map(function (h) {
              return [h, HARNESS_LABELS[h] || h];
            })
          ),
          controls.backend,
          enabled,
          function (value) {
            self.setControl(id, "backend", value);
          },
          true
        )
      );
      form.appendChild(harnessRow);

      var effortRow = this.formRow("Thinking", "Issue labels still win");
      effortRow.appendChild(
        this.choice(
          [[null, "Default"]].concat(
            EFFORTS.map(function (e) {
              return [e, e.charAt(0).toUpperCase() + e.slice(1)];
            })
          ),
          controls.effort,
          enabled,
          function (value) {
            self.setControl(id, "effort", value);
          }
        )
      );
      form.appendChild(effortRow);
      drawer.appendChild(form);
    }

    if (!enabled && AGENT_STAGES[id]) drawer.appendChild(el("p", "fx-drawer-note", "Only Linear admins can change stage controls."));

    var listHead = el("div", "fx-drawer-subhead");
    listHead.appendChild(el("span", null, node.count + (node.count === 1 ? " issue" : " issues")));
    var filter = el("button", "fx-link-btn", this.state.node === id ? "Clear spend filter" : "Show its spend");
    filter.type = "button";
    filter.addEventListener("click", function () {
      self.state.node = self.state.node === id ? null : id;
      self.renderDrawer();
      self.renderExplorer();
    });
    listHead.appendChild(filter);
    drawer.appendChild(listHead);

    var list = el("div", "fx-drawer-list");
    var actions = STAGE_ACTIONS[id] || [];
    var movable = this.data.movable_teams;
    var canMove = function (issue) {
      if (movable === "all") return true;
      var team = (issue.issue || "").split("-")[0];
      return Array.isArray(movable) && movable.indexOf(team) !== -1;
    };
    node.issues.forEach(function (issue) {
      var row = el("div", "fx-issue-row");
      var info = el("div", "fx-issue-info");
      var issueUrl = safeUrl(issue.url);
      var idEl = issueUrl ? el("a", "fx-issue-id", issue.issue) : el("span", "fx-issue-id", issue.issue);
      if (issueUrl) {
        idEl.href = issueUrl;
        idEl.target = "_blank";
        idEl.rel = "noopener";
      }
      info.appendChild(idEl);
      if (issue.backend) info.appendChild(el("span", "fx-dot h-" + issue.backend));
      info.appendChild(el("span", "fx-issue-title", issue.title || ""));
      info.appendChild(el("span", "fx-issue-age", since(issue.since_ms)));
      row.appendChild(info);

      var pending = self.state.pending[issue.issue];
      if (actions.length && issue.id && canMove(issue)) {
        var buttons = el("div", "fx-issue-actions");
        if (pending) {
          buttons.appendChild(el("span", "fx-pending", pending + "…"));
        } else {
          actions.forEach(function (action) {
            var b = el("button", "fx-action" + (action[2] ? " is-primary" : ""), action[1]);
            b.type = "button";
            b.addEventListener("click", function () {
              self.moveIssue(issue, action[0], action[1]);
            });
            buttons.appendChild(b);
          });
        }
        row.appendChild(buttons);
      }
      list.appendChild(row);
    });
    if (!node.issues.length) list.appendChild(el("p", "fx-empty", "Nothing here right now."));
    drawer.appendChild(list);
  };

  Panel.prototype.formRow = function (label, hint) {
    var row = el("div", "fx-form-row");
    var text = el("div", "fx-form-label");
    text.appendChild(el("span", null, label));
    text.appendChild(el("small", null, hint));
    row.appendChild(text);
    return row;
  };

  Panel.prototype.choice = function (options, current, enabled, onPick, harness) {
    var wrap = el("div", "fx-seg fx-seg-small");
    options.forEach(function (option) {
      var active = option[0] === (current === undefined ? null : current);
      var b = el("button", "fx-seg-btn" + (active ? " is-active" : ""));
      b.type = "button";
      b.disabled = !enabled;
      if (harness && option[0]) b.appendChild(el("span", "fx-dot h-" + option[0]));
      b.appendChild(document.createTextNode(option[1]));
      b.addEventListener("click", function () {
        onPick(option[0]);
      });
      wrap.appendChild(b);
    });
    return wrap;
  };

  // ---------------------------------------------------------------- explorer

  Panel.prototype.filteredRows = function () {
    var data = this.data;
    var rows = data.usage;
    var state = this.state;

    if (state.node) {
      var members = {};
      data.flow.nodes.forEach(function (node) {
        if (node.id === state.node)
          node.issues.forEach(function (issue) {
            members[issue.issue] = true;
          });
      });
      rows = rows.filter(function (row) {
        return members[row.issue];
      });
    }

    if (state.query) {
      var q = state.query;
      rows = rows.filter(function (row) {
        return [row.project, row.project_name, row.team, row.issue, row.title, row.backend, row.model].some(function (value) {
          return value && String(value).toLowerCase().indexOf(q) !== -1;
        });
      });
    }

    return rows;
  };

  function groupKey(row, group) {
    if (group === "team") return row.team || "—";
    if (group === "issue") return row.issue || "—";
    return row.project || "unassigned";
  }

  function groupLabel(row, group) {
    if (group === "team") return { label: row.team || "No team", sub: "" };
    if (group === "issue") return { label: row.issue || "Unknown", sub: row.title || "" };
    return { label: row.project_name || row.project || "Unassigned", sub: row.project_name ? row.project : "" };
  }

  Panel.prototype.groups = function (rows) {
    var group = this.state.group;
    var harnesses = this.data.harnesses;
    var map = {};
    var list = [];

    rows.forEach(function (row) {
      var key = groupKey(row, group);
      var entry = map[key];
      if (!entry) {
        var names = groupLabel(row, group);
        entry = { key: key, label: names.label, sub: names.sub, url: row.url, h: {}, models: {} };
        harnesses.forEach(function (h) {
          entry.h[h] = { input: 0, output: 0, cost: 0, unpriced: 0 };
        });
        map[key] = entry;
        list.push(entry);
      }
      var bucket = entry.h[row.backend] || (entry.h[row.backend] = { input: 0, output: 0, cost: 0, unpriced: 0 });
      bucket.input += row.input_tokens;
      bucket.output += row.output_tokens;
      if (row.cost_usd === null || row.cost_usd === undefined) bucket.unpriced += row.input_tokens + row.output_tokens;
      else bucket.cost += row.cost_usd;
      entry.models[row.backend + " · " + row.model] = true;
    });

    return list;
  };

  Panel.prototype.value = function (bucket) {
    return this.state.metric === "cost" ? bucket.cost : bucket.input + bucket.output;
  };

  Panel.prototype.format = function (n) {
    return this.state.metric === "cost" ? money(n) : compact(n);
  };

  Panel.prototype.renderExplorer = function () {
    if (!this.data) return;
    var self = this;
    var state = this.state;
    var harnesses = this.data.harnesses;
    var visible = harnesses.filter(function (h) {
      return !state.hidden[h];
    });

    this.syncSegmented(this.groupSeg, state.group);
    this.syncSegmented(this.metricSeg, state.metric);
    this.tableToggle.classList.toggle("is-active", state.table);
    this.tableToggle.setAttribute("aria-pressed", state.table ? "true" : "false");

    if (state.node) {
      this.nodeChip.hidden = false;
      this.nodeChip.textContent = "Stage: " + labelFor(this.data.flow, state.node) + "  ✕";
    } else {
      this.nodeChip.hidden = true;
    }

    var rows = this.filteredRows();
    var groups = this.groups(rows);
    groups.forEach(function (g) {
      g.total = visible.reduce(function (sum, h) {
        return sum + self.value(g.h[h]);
      }, 0);
    });
    groups.sort(function (a, b) {
      return b.total - a.total;
    });

    if (groups.length > MAX_ROWS) {
      var rest = groups.splice(MAX_ROWS - 1);
      var other = { key: "__other", label: "Other", sub: rest.length + " more", h: {}, models: {}, total: 0 };
      harnesses.forEach(function (h) {
        other.h[h] = { input: 0, output: 0, cost: 0, unpriced: 0 };
        rest.forEach(function (g) {
          other.h[h].input += g.h[h].input;
          other.h[h].output += g.h[h].output;
          other.h[h].cost += g.h[h].cost;
          other.h[h].unpriced += g.h[h].unpriced;
        });
      });
      other.total = rest.reduce(function (s, g) {
        return s + g.total;
      }, 0);
      groups.push(other);
    }

    this.renderStats(rows);
    this.renderLegend(harnesses, visible);

    var unpriced = !this.data.priced && state.metric === "cost";
    this.exCopy.textContent = unpriced ? "No pricing configured — add `pricing` to symphony.yml to see cost." : "";
    this.exCopy.hidden = !unpriced;

    this.bars.hidden = state.table;
    this.table.hidden = !state.table;
    if (state.table) this.renderTable(groups, visible);
    else this.renderBars(groups, visible);
  };

  Panel.prototype.renderStats = function (rows) {
    var flow = this.data.flow;
    var input = 0;
    var output = 0;
    var cost = 0;
    var priced = false;
    rows.forEach(function (row) {
      input += row.input_tokens;
      output += row.output_tokens;
      if (row.cost_usd !== null && row.cost_usd !== undefined) {
        cost += row.cost_usd;
        priced = true;
      }
    });
    var shipped = 0;
    var loops = 0;
    var running = 0;
    flow.edges.forEach(function (edge) {
      if (edge.to === "done") shipped += edge.count;
      if (LOOP_EDGES[edge.from + ">" + edge.to] && edge.from === "review") loops += edge.count;
    });
    flow.nodes.forEach(function (node) {
      running += node.running;
    });

    var tiles = [
      { label: "Spend", value: priced ? money(cost) : "—", detail: priced ? "all time" : "pricing not set" },
      { label: "Tokens", value: compact(input + output), detail: "in " + compact(input) + " · out " + compact(output) },
      { label: "Agents", value: running + (this.data.capacity ? " / " + this.data.capacity : ""), detail: "running now", live: running > 0 },
      { label: "Shipped", value: String(shipped), detail: "merged → done" },
      { label: "Review loops", value: String(loops), detail: shipped ? Math.round((loops / Math.max(1, shipped + loops)) * 100) + "% of reviews" : "sent back" }
    ];

    var stats = this.stats;
    stats.textContent = "";
    tiles.forEach(function (tile) {
      var cell = el("div", "fx-stat" + (tile.live ? " is-live" : ""));
      cell.appendChild(el("span", "fx-stat-label", tile.label));
      cell.appendChild(el("strong", "fx-stat-value", tile.value));
      cell.appendChild(el("span", "fx-stat-detail", tile.detail));
      stats.appendChild(cell);
    });
  };

  Panel.prototype.renderLegend = function (harnesses, visible) {
    var self = this;
    var legend = this.legend;
    legend.textContent = "";
    harnesses.forEach(function (h) {
      var on = visible.indexOf(h) !== -1;
      var item = el("button", "fx-legend-item" + (on ? "" : " is-off"));
      item.type = "button";
      item.setAttribute("aria-pressed", on ? "true" : "false");
      item.appendChild(el("span", "fx-legend-key h-" + h));
      item.appendChild(el("span", null, HARNESS_LABELS[h] || h));
      item.addEventListener("click", function () {
        if (on && visible.length === 1) return; // keep at least one series
        self.state.hidden[h] = on;
        self.renderExplorer();
      });
      legend.appendChild(item);
    });
  };

  Panel.prototype.renderBars = function (groups, visible) {
    var self = this;
    var bars = this.bars;
    bars.textContent = "";

    if (groups.length === 0) {
      bars.appendChild(el("p", "fx-empty", "No usage recorded for this slice yet."));
      return;
    }

    var max = groups.reduce(function (m, g) {
      return Math.max(m, g.total);
    }, 0) || 1;

    groups.forEach(function (g) {
      var row = el("div", "fx-bar-row");
      var labelCell = el("div", "fx-bar-label");
      var groupUrl = safeUrl(g.url);
      var name = groupUrl && self.state.group === "issue" ? el("a", "fx-bar-name", g.label) : el("span", "fx-bar-name", g.label);
      if (name.tagName === "A") {
        name.href = groupUrl;
        name.target = "_blank";
        name.rel = "noopener";
      }
      labelCell.appendChild(name);
      if (g.sub) labelCell.appendChild(el("span", "fx-bar-sub", g.sub));
      row.appendChild(labelCell);

      var track = el("div", "fx-bar-track");
      var fill = el("div", "fx-bar-fill");
      fill.style.width = ((g.total / max) * 100).toFixed(3) + "%";
      var segments = visible.filter(function (h) {
        return self.value(g.h[h]) > 0;
      });
      segments.forEach(function (h, i) {
        var bucket = g.h[h];
        var seg = el("div", "fx-seg-fill h-" + h + (i === segments.length - 1 ? " is-end" : ""));
        seg.style.flexGrow = String(self.value(bucket));
        seg.tabIndex = 0;
        var show = function (event) {
          self.showTooltip(event, function (tip) {
            tipValue(tip, self.format(self.value(bucket)), HARNESS_LABELS[h] || h);
            tipLine(tip, "h-" + h, "Input tokens", compact(bucket.input));
            tipLine(tip, "h-" + h, "Output tokens", compact(bucket.output));
            tipLine(tip, null, "Cost", bucket.unpriced && !bucket.cost ? "unpriced" : money(bucket.cost));
            tipLine(tip, null, g.label, Math.round((self.value(bucket) / (g.total || 1)) * 100) + "% of row");
          });
        };
        seg.addEventListener("pointerenter", show);
        seg.addEventListener("focus", function () {
          var box = seg.getBoundingClientRect();
          show({ clientX: box.left + box.width / 2, clientY: box.top });
        });
        seg.addEventListener("pointermove", function (event) {
          self.moveTooltip(event);
        });
        seg.addEventListener("pointerleave", function () {
          self.hideTooltip();
        });
        seg.addEventListener("blur", function () {
          self.hideTooltip();
        });
        fill.appendChild(seg);
      });
      track.appendChild(fill);
      row.appendChild(track);
      row.appendChild(el("span", "fx-bar-value", self.format(g.total)));
      bars.appendChild(row);
    });
  };

  Panel.prototype.renderTable = function (groups, visible) {
    var wrap = this.table;
    wrap.textContent = "";
    var table = el("table", "fx-table");
    var head = el("tr");
    [GROUP_LABELS[this.state.group], "Harness", "Input", "Output", "Cost"].forEach(function (label, i) {
      head.appendChild(el("th", i > 1 ? "is-num" : null, label));
    });
    var thead = el("thead");
    thead.appendChild(head);
    table.appendChild(thead);
    var tbody = el("tbody");
    groups.forEach(function (g) {
      visible.forEach(function (h) {
        var b = g.h[h];
        if (!b.input && !b.output) return;
        var tr = el("tr");
        tr.appendChild(el("td", null, g.label));
        var harness = el("td");
        harness.appendChild(el("span", "fx-legend-key h-" + h));
        harness.appendChild(document.createTextNode(HARNESS_LABELS[h] || h));
        tr.appendChild(harness);
        tr.appendChild(el("td", "is-num", b.input.toLocaleString()));
        tr.appendChild(el("td", "is-num", b.output.toLocaleString()));
        tr.appendChild(el("td", "is-num", b.unpriced && !b.cost ? "unpriced" : money(b.cost)));
        tbody.appendChild(tr);
      });
    });
    table.appendChild(tbody);
    wrap.appendChild(table);
    if (!tbody.children.length) wrap.appendChild(el("p", "fx-empty", "No usage recorded for this slice yet."));
  };

  // ---------------------------------------------------------------- hook

  var panels = {};

  function sync(hookEl, hook) {
    var targetId = hookEl.dataset.target;
    var target = document.getElementById(targetId);
    if (!target) return;
    var raw = hookEl.dataset.json;
    if (hook && panels[targetId]) panels[targetId].hook = hook;
    if (!raw || raw === hookEl._lastRaw) return;
    hookEl._lastRaw = raw;
    var data;
    try {
      data = JSON.parse(raw);
    } catch (_e) {
      return;
    }
    var panel = panels[targetId] || (panels[targetId] = new Panel(target));
    if (hook) panel.hook = hook;
    // Coalesce bursts of server updates into one paint.
    if (panel._frame) cancelAnimationFrame(panel._frame);
    panel._frame = requestAnimationFrame(function () {
      panel._frame = null;
      panel.setData(data);
    });
  }

  window.SymphonyHooks = window.SymphonyHooks || {};
  window.SymphonyHooks.FactoryData = {
    mounted: function () {
      sync(this.el, this);
    },
    updated: function () {
      sync(this.el, this);
    }
  };

  // Static render (no LiveView socket, e.g. screenshots or JS disabled socket).
  document.addEventListener("DOMContentLoaded", function () {
    var hookEl = document.getElementById("factory-data");
    if (hookEl) sync(hookEl);
  });
})();
