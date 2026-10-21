// Agent Factory panel: the live process diagram, plus the dashboard's hooks.
//
// The server pushes one JSON payload per orchestrator update (data-json on
// #factory-data). Everything interactive in the diagram - selection, hover,
// zoom, editing - runs here against that payload, so interactions never wait
// on a LiveView round-trip.
(function () {
  "use strict";

  var SVG_NS = "http://www.w3.org/2000/svg";

  // ---------------------------------------------------------------- helpers

  // Dot-matrix numbers, like the n8n site's hero: each character is a 5×7
  // grid of rounded squares over a field of small dots.
  var DM_GLYPHS = {
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    "$": ["00100", "01111", "10100", "01110", "00101", "11110", "00100"],
    ".": ["0", "0", "0", "0", "0", "0", "1"],
    ",": ["0", "0", "0", "0", "0", "1", "1"],
    "/": ["00001", "00010", "00010", "00100", "01000", "01000", "10000"],
    "%": ["11001", "11010", "00010", "00100", "01000", "01011", "10011"],
    "-": ["000", "000", "000", "111", "000", "000", "000"],
    "—": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    " ": ["00", "00", "00", "00", "00", "00", "00"],
    K: ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    M: ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    B: ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    T: ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    s: ["00000", "00000", "01111", "10000", "01110", "00001", "11110"],
    m: ["00000", "00000", "11010", "10101", "10101", "10101", "10101"],
    h: ["10000", "10000", "10110", "11001", "10001", "10001", "10001"],
    k: ["10000", "10000", "10010", "10100", "11000", "10100", "10010"]
  };

  function dotMatrix(text) {
    var NS = "http://www.w3.org/2000/svg";
    var cell = 5;
    var x = 0;
    var svg = document.createElementNS(NS, "svg");
    svg.setAttribute("class", "dot-matrix");
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", text);
    String(text).split("").forEach(function (ch) {
      var glyph = DM_GLYPHS[ch] || DM_GLYPHS[ch.toUpperCase()];
      if (!glyph) return;
      var width = glyph[0].length;
      glyph.forEach(function (row, y) {
        for (var i = 0; i < width; i++) {
          var on = row[i] === "1";
          var r = document.createElementNS(NS, on ? "rect" : "circle");
          if (on) {
            r.setAttribute("x", (x + i) * cell + 0.7);
            r.setAttribute("y", y * cell + 0.7);
            r.setAttribute("width", cell - 1.4);
            r.setAttribute("height", cell - 1.4);
            r.setAttribute("rx", 0.9);
          } else {
            r.setAttribute("cx", (x + i) * cell + cell / 2);
            r.setAttribute("cy", y * cell + cell / 2);
            r.setAttribute("r", 0.6);
          }
          r.setAttribute("class", on ? "dm-on" : "dm-off");
          svg.appendChild(r);
        }
      });
      x += width + 1;
    });
    var w = Math.max(x - 1, 1) * cell;
    svg.setAttribute("viewBox", "0 0 " + w + " " + 7 * cell);
    svg.style.aspectRatio = w + " / " + 7 * cell;
    return svg;
  }

  window.SymphonyDotMatrix = dotMatrix;

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  // ---------------------------------------------------------------- panel

  function Panel(root) {
    this.root = root;
    this.data = null;
    this.build();
  }

  Panel.prototype.build = function () {
    var self = this;
    var slot = function (name) {
      // Slots live in different page sections, so look them up document-wide.
      var node = document.querySelector('[data-fx="' + name + '"]');
      node.textContent = "";
      return node;
    };

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
      assist: window.SymphonyAssist ? window.SymphonyAssist.forPanel(self) : null,
      assistFlow: window.SymphonyAssist ? window.SymphonyAssist.flowForPanel(self) : null
    });

    // One fixed-position tooltip for every slot.
    this.tooltip = document.getElementById("fx-tooltip") || el("div", "fx-tooltip");
    this.tooltip.id = "fx-tooltip";
    this.tooltip.setAttribute("role", "tooltip");
    document.body.appendChild(this.tooltip);
  };

  Panel.prototype.setData = function (data) {
    this.data = data;
    this.flow.setData(data);
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

  // Agent transcript: stay pinned to the newest entry unless the reader has
  // scrolled up to read something older.
  window.SymphonyHooks.ChatScroll = {
    mounted: function () {
      this.el.scrollTop = this.el.scrollHeight;
    },
    beforeUpdate: function () {
      this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 40;
    },
    updated: function () {
      if (this.pinned) this.el.scrollTop = this.el.scrollHeight;
    }
  };

  // A dot-matrix number from data-value (traces and metrics KPIs).
  window.SymphonyHooks.DotMatrix = {
    mounted: function () {
      this.draw();
    },
    updated: function () {
      this.draw();
    },
    draw: function () {
      this.el.textContent = "";
      this.el.appendChild(dotMatrix(this.el.dataset.value || ""));
    }
  };

  // Chat composer: Enter sends, Shift+Enter is a new line, the box grows with
  // what is typed and empties once the message is accepted.
  window.SymphonyHooks.ChatComposer = {
    mounted: function () {
      var form = this.el;
      var box = form.querySelector("textarea");
      var grow = function () {
        box.style.height = "auto";
        box.style.height = Math.min(box.scrollHeight, 220) + "px";
      };
      box.addEventListener("input", grow);
      box.addEventListener("keydown", function (e) {
        if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
          e.preventDefault();
          if (box.value.trim() !== "") form.requestSubmit();
        }
      });
      this.handleEvent("chat_sent", function () {
        box.value = "";
        grow();
        box.focus();
      });
      box.focus();
    }
  };

  // Top-bar team and project pickers: remember the last choice per browser
  // and restore it when the dashboard opens without one in the URL.
  var TEAM_KEY = "symphony.team";
  var PROJECT_KEY = "symphony.project";
  window.SymphonyHooks.TeamPicker = {
    mounted: function () {
      var form = this.el;
      var hook = this;
      var pick = function (name) {
        var select = form.querySelector('select[name="' + name + '"]');
        return select ? select.value : "all";
      };
      form.addEventListener("change", function () {
        try {
          window.localStorage.setItem(TEAM_KEY, pick("team"));
          window.localStorage.setItem(PROJECT_KEY, pick("project"));
        } catch (_e) {}
      });
      if (/[?&](team|project)=/.test(window.location.search)) return;
      var team = null;
      var project = null;
      try {
        team = window.localStorage.getItem(TEAM_KEY);
        project = window.localStorage.getItem(PROJECT_KEY);
      } catch (_e) {}
      team = team && team !== "all" ? team : null;
      project = project && project !== "all" ? project : null;
      // The server drops a team or project this person can no longer see.
      if (team || project) hook.pushEvent("pick_team", { team: team || "all", project: project || "all" });
    }
  };

  // Static render (no LiveView socket, e.g. screenshots or JS disabled socket).
  document.addEventListener("DOMContentLoaded", function () {
    var hookEl = document.getElementById("factory-data");
    if (hookEl) sync(hookEl);
  });
})();
