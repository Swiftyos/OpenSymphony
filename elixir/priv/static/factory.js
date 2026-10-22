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
      }
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
    if (hook && panel.hook !== hook) panel.hook = hook;
    // Coalesce bursts of server updates into one paint.
    if (panel._frame) cancelAnimationFrame(panel._frame);
    panel._frame = requestAnimationFrame(function () {
      panel._frame = null;
      panel.setData(data);
    });
  }

  // ---------------------------------------------------------------- dropdowns

  // The dashboard's dropdowns: a native <select> stays in the page (forms,
  // labels and LiveView's phx-change keep working off it) and is drawn as a
  // button and a listbox in the dashboard's own style. Keyboard: arrows,
  // Home/End, Enter, Esc; typing jumps to a match, or filters when the list
  // has a search field (long lists, or data-dropdown-search). Choosing sets
  // the select's value and fires its input and change events.
  var ddOpen = null;

  function closeOpenDropdown() {
    if (ddOpen) ddOpen.close();
  }

  document.addEventListener("pointerdown", function (e) {
    if (ddOpen && !ddOpen.root.contains(e.target)) ddOpen.close();
  }, true);

  function Dropdown(select, slot) {
    this.select = select;
    this.root = slot || el("span");
    if (!slot) select.parentNode.insertBefore(this.root, select.nextSibling);
    this.root.classList.add("dd");
    this.root.textContent = "";
    select.classList.add("dd-native");
    select.tabIndex = -1;
    select.setAttribute("aria-hidden", "true");
    this.id = (select.id || "dd" + Math.random().toString(36).slice(2)) + "-list";
    this.button = el("button", "dd-button");
    this.button.type = "button";
    this.button.setAttribute("aria-haspopup", "listbox");
    this.button.setAttribute("aria-expanded", "false");
    this.button.setAttribute("aria-controls", this.id);
    var label = select.getAttribute("aria-label") || (select.id && document.querySelector('label[for="' + select.id + '"]') ? document.querySelector('label[for="' + select.id + '"]').textContent : null);
    if (label) this.button.setAttribute("aria-label", label.trim());
    this.value = el("span", "dd-value");
    this.button.appendChild(this.value);
    this.button.appendChild(el("span", "dd-caret", "▾"));
    this.pop = el("div", "dd-pop");
    this.pop.hidden = true;
    this.list = el("ul", "dd-list");
    this.list.id = this.id;
    this.list.setAttribute("role", "listbox");
    this.list.tabIndex = -1;
    this.root.appendChild(this.button);
    this.root.appendChild(this.pop);
    this.bind();
    this.sync();
    select._dropdown = this;
  }

  Dropdown.prototype.items = function () {
    return Array.prototype.slice.call(this.list.querySelectorAll('[role="option"]:not([hidden])'));
  };

  // Mirrors the select: its options (and optgroups), value and disabled state.
  Dropdown.prototype.sync = function () {
    var self = this;
    var select = this.select;
    var options = select.querySelectorAll("option");
    var current = select.options[select.selectedIndex];
    this.value.textContent = current ? current.textContent.trim() : "";
    this.button.disabled = select.disabled;
    if (select.title) this.button.title = select.title;
    this.list.textContent = "";
    this.pop.textContent = "";
    this.search = null;
    if (options.length > 8 || select.hasAttribute("data-dropdown-search")) {
      this.search = el("input", "dd-search");
      this.search.type = "search";
      this.search.placeholder = "Filter…";
      this.search.setAttribute("aria-label", "Filter");
      this.search.setAttribute("aria-controls", this.id);
      this.search.addEventListener("input", function () {
        self.filter(self.search.value);
      });
      this.search.addEventListener("keydown", function (e) {
        self.onKey(e, true);
      });
      this.pop.appendChild(this.search);
    }
    this.pop.appendChild(this.list);
    Array.prototype.forEach.call(select.children, function (child) {
      if (child.tagName === "OPTGROUP") {
        var group = el("li", "dd-group", child.label);
        group.setAttribute("role", "presentation");
        self.list.appendChild(group);
        Array.prototype.forEach.call(child.children, function (o) {
          self.addOption(o);
        });
      } else if (child.tagName === "OPTION") {
        self.addOption(child);
      }
    });
  };

  Dropdown.prototype.addOption = function (option) {
    var self = this;
    var item = el("li", "dd-option", option.textContent.trim());
    item.setAttribute("role", "option");
    item.id = this.id + "-" + this.list.children.length;
    item.dataset.value = option.value;
    item.setAttribute("aria-selected", option.selected ? "true" : "false");
    if (option.disabled) item.setAttribute("aria-disabled", "true");
    item.addEventListener("pointerdown", function (e) {
      e.preventDefault();
    });
    item.addEventListener("click", function () {
      if (!option.disabled) self.choose(option.value);
    });
    this.list.appendChild(item);
  };

  Dropdown.prototype.bind = function () {
    var self = this;
    this.button.addEventListener("click", function () {
      if (self.pop.hidden) self.open();
      else self.close();
    });
    this.button.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        self.open();
      }
    });
    this.list.addEventListener("keydown", function (e) {
      self.onKey(e, false);
    });
  };

  Dropdown.prototype.open = function () {
    if (this.button.disabled) return;
    closeOpenDropdown();
    this.pop.hidden = false;
    this.button.setAttribute("aria-expanded", "true");
    this.root.classList.add("is-open");
    ddOpen = this;
    var selected = this.list.querySelector('[aria-selected="true"]') || this.items()[0];
    this.activate(selected);
    if (this.search) {
      this.search.value = "";
      this.filter("");
      this.search.focus();
    } else {
      this.list.focus();
    }
  };

  Dropdown.prototype.close = function (refocus) {
    this.pop.hidden = true;
    this.button.setAttribute("aria-expanded", "false");
    this.root.classList.remove("is-open");
    if (ddOpen === this) ddOpen = null;
    if (refocus) this.button.focus();
  };

  Dropdown.prototype.activate = function (item) {
    var current = this.list.querySelector(".is-active");
    if (current) current.classList.remove("is-active");
    if (!item) return;
    item.classList.add("is-active");
    this.list.setAttribute("aria-activedescendant", item.id);
    if (this.search) this.search.setAttribute("aria-activedescendant", item.id);
    if (item.scrollIntoView) item.scrollIntoView({ block: "nearest" });
  };

  Dropdown.prototype.filter = function (text) {
    var q = text.trim().toLowerCase();
    Array.prototype.forEach.call(this.list.querySelectorAll('[role="option"]'), function (item) {
      item.hidden = q !== "" && item.textContent.toLowerCase().indexOf(q) === -1;
    });
    this.activate(this.items()[0]);
  };

  Dropdown.prototype.onKey = function (e, inSearch) {
    var items = this.items();
    var active = this.list.querySelector(".is-active");
    var i = items.indexOf(active);
    if (e.key === "ArrowDown") {
      e.preventDefault();
      this.activate(items[Math.min(i + 1, items.length - 1)]);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      this.activate(items[Math.max(i - 1, 0)]);
    } else if (e.key === "Home" && !inSearch) {
      e.preventDefault();
      this.activate(items[0]);
    } else if (e.key === "End" && !inSearch) {
      e.preventDefault();
      this.activate(items[items.length - 1]);
    } else if (e.key === "Enter" || (e.key === " " && !inSearch)) {
      e.preventDefault();
      if (active && active.getAttribute("aria-disabled") !== "true") this.choose(active.dataset.value);
    } else if (e.key === "Escape") {
      e.preventDefault();
      this.close(true);
    } else if (e.key === "Tab") {
      this.close(false);
    } else if (!inSearch && e.key.length === 1 && !e.metaKey && !e.ctrlKey) {
      // Type to jump: the next option starting with what was typed.
      var now = Date.now();
      this.typed = now - (this.typedAt || 0) < 700 ? (this.typed || "") + e.key.toLowerCase() : e.key.toLowerCase();
      this.typedAt = now;
      var typed = this.typed;
      var match = items.filter(function (item) {
        return item.textContent.toLowerCase().indexOf(typed) === 0;
      })[0];
      if (match) this.activate(match);
    }
  };

  Dropdown.prototype.choose = function (value) {
    var select = this.select;
    var changed = select.value !== value;
    select.value = value;
    this.close(true);
    this.sync();
    if (changed) {
      select.dispatchEvent(new Event("input", { bubbles: true }));
      select.dispatchEvent(new Event("change", { bubbles: true }));
    }
  };

  // Draws `select` as a dropdown (in `slot` when given), or refreshes one
  // already drawn.
  window.SymphonyDropdown = {
    enhance: function (select, slot) {
      if (select._dropdown && (!slot || select._dropdown.root === slot) && select._dropdown.root.isConnected) {
        select._dropdown.sync();
        return select._dropdown;
      }
      return new Dropdown(select, slot);
    }
  };

  window.SymphonyHooks = window.SymphonyHooks || {};
  // A server-rendered <select phx-hook="Dropdown" data-dropdown-slot="id">:
  // drawn in the phx-update="ignore" element with that id, so LiveView's
  // patches change the select and never the drawn dropdown.
  window.SymphonyHooks.Dropdown = {
    mounted: function () {
      this.draw();
    },
    updated: function () {
      this.draw();
    },
    draw: function () {
      var slot = document.getElementById(this.el.dataset.dropdownSlot);
      window.SymphonyDropdown.enhance(this.el, slot);
    }
  };

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
