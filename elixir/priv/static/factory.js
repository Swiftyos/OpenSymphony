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
  var MAX_ROWS = 12;

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

    // The flow diagram, stage drawer, and editor live in factory_flow.js.
    this.flow = window.SymphonyFlow.create({
      slot: slot("diagram"),
      drawerSlot: slot("drawer"),
      tip: {
        show: function (e, build) {
          self.showTooltip(e, build);
        },
        move: function (e) {
          self.moveTooltip(e);
        },
        hide: function () {
          self.hideTooltip();
        }
      },
      push: function (event, payload, cb) {
        self.push(event, payload, cb);
      },
      toast: function (message, tone) {
        self.toast(message, tone);
      },
      onFilter: function (stageId, label, issues) {
        self.state.node = stageId ? { label: label, issues: (issues || []).map(function (i) {
                return i.issue;
              }) } : null;
        self.renderExplorer();
      },
      assist: window.SymphonyAssist ? window.SymphonyAssist.forPanel(self) : null,
      assistFlow: window.SymphonyAssist ? window.SymphonyAssist.flowForPanel(self) : null
    });

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
    this.data = data;
    if (!this.state.metric) this.state.metric = data.priced ? "cost" : "tokens";
    this.flow.setData(data);
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

  // ---------------------------------------------------------------- server

  Panel.prototype.push = function (event, payload, onReply) {
    if (!this.hook) {
      onReply({ ok: false, error: "Not connected to the server" });
      return;
    }
    this.hook.pushEvent(event, payload, onReply);
  };

  // Results the server pushes later (e.g. AI drafts), matched by ref.
  Panel.prototype.waitFor = function (event, ref, cb) {
    this.waiters = this.waiters || {};
    this.waiters[event + ":" + ref] = cb;
  };

  Panel.prototype.deliver = function (event, payload) {
    var key = event + ":" + (payload && payload.ref);
    var cb = this.waiters && this.waiters[key];
    if (cb) {
      delete this.waiters[key];
      cb(payload);
    }
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

  // ---------------------------------------------------------------- explorer

  Panel.prototype.filteredRows = function () {
    var data = this.data;
    var rows = data.usage;
    var state = this.state;

    if (state.node) {
      var members = {};
      state.node.issues.forEach(function (identifier) {
        members[identifier] = true;
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
      this.nodeChip.textContent = "Stage: " + state.node.label + "  ✕";
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
    // Across every team visible to this person. A project that inherits its
    // team's flow repeats the team's issues, so only projects with their own
    // flow (whose issues teams leave out) are added.
    var shipped = 0;
    var loops = 0;
    var running = 0;
    var data = this.data;
    var projectKeys = {};
    (data.teams || []).forEach(function (t) {
      if (t.kind === "project" && !t.custom) projectKeys[t.key] = true;
    });
    Object.keys(data.flows || {}).forEach(function (team) {
      if (projectKeys[team]) return;
      var flow = data.flows[team];
      var definition = (data.definitions || {})[team] || { stages: [] };
      var byId = {};
      definition.stages.forEach(function (st) {
        byId[st.id] = st;
      });
      Object.keys(flow.edges || {}).forEach(function (key) {
        var parts = key.split(">");
        var from = byId[parts[0]];
        var to = byId[parts[1]];
        if (to && to.kind === "done") shipped += flow.edges[key];
        // A loop is any move back toward the start of the flow.
        if (from && to && to.position.x < from.position.x) loops += flow.edges[key];
      });
      Object.keys(flow.nodes || {}).forEach(function (id) {
        running += flow.nodes[id].running || 0;
      });
    });

    var tiles = [
      { label: "Spend", value: priced ? money(cost) : "—", detail: priced ? "all time" : "pricing not set" },
      { label: "Tokens", value: compact(input + output), detail: "in " + compact(input) + " · out " + compact(output) },
      { label: "Agents", value: running + (this.data.capacity ? " / " + this.data.capacity : ""), detail: "running now", live: running > 0 },
      { label: "Shipped", value: String(shipped), detail: "reached done" },
      { label: "Loops", value: String(loops), detail: "sent back a stage" }
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
    if (hook && panel.hook !== hook) {
      panel.hook = hook;
      if (typeof hook.handleEvent === "function")
        hook.handleEvent("factory_assist_result", function (payload) {
        panel.deliver("factory_assist_result", payload);
      });
    }
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

  // Top-bar team picker: remembers the last team per browser and restores it
  // when the dashboard opens without one in the URL.
  var TEAM_KEY = "symphony.team";
  window.SymphonyHooks.TeamPicker = {
    mounted: function () {
      var select = this.el.querySelector("select");
      var hook = this;
      select.addEventListener("change", function () {
        try {
          window.localStorage.setItem(TEAM_KEY, select.value);
        } catch (_e) {}
      });
      if (/[?&]team=/.test(window.location.search)) return;
      var saved = null;
      try {
        saved = window.localStorage.getItem(TEAM_KEY);
      } catch (_e) {}
      if (saved && saved !== "all" && select.querySelector('option[value="' + saved.replace(/[^A-Za-z0-9_-]/g, "") + '"]')) {
        hook.pushEvent("pick_team", { team: saved });
      }
    }
  };

  // Static render (no LiveView socket, e.g. screenshots or JS disabled socket).
  document.addEventListener("DOMContentLoaded", function () {
    var hookEl = document.getElementById("factory-data");
    if (hookEl) sync(hookEl);
  });
})();
