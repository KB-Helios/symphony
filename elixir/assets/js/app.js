// Symphony observability front end.
// LiveView client + SaladUI server-event bridge + small local hooks.

import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

// Copy arbitrary text to the clipboard and reflect success on the trigger.
const ClipboardCopy = {
  mounted() {
    this.handle = () => {
      const text = this.el.dataset.copy || "";
      const label = this.el.dataset.label || this.el.textContent;
      const show = (msg) => {
        this.el.textContent = msg;
        clearTimeout(this._t);
        this._t = setTimeout(() => (this.el.textContent = label), 1200);
      };
      const fallbackCopy = (value) => {
        const ta = document.createElement("textarea");
        ta.value = value;
        ta.setAttribute("readonly", "");
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        let ok = false;
        try {
          ok = document.execCommand("copy");
        } catch (_) {
          ok = false;
        }
        document.body.removeChild(ta);
        return ok;
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard
          .writeText(text)
          .then(() => show("Copied"))
          .catch(() => {
            if (fallbackCopy(text)) show("Copied");
            else show("Failed");
          });
      } else {
        if (fallbackCopy(text)) show("Copied");
        else show("Failed");
      }
    };
    this.el.addEventListener("click", this.handle);
  },
  destroyed() {
    this.el.removeEventListener("click", this.handle);
  },
};

// Persisted light/dark theme toggle.
const ThemeToggle = {
  mounted() {
    this.handle = () => {
      const dark = document.documentElement.classList.toggle("dark");
      try {
        localStorage.setItem("symphony-theme", dark ? "dark" : "light");
      } catch (_) {}
    };
    this.el.addEventListener("click", this.handle);
  },
  destroyed() {
    this.el.removeEventListener("click", this.handle);
  },
};

// Client-side runtime clock — computes elapsed from data-started-at ISO8601.
const RuntimeClock = {
  mounted() {
    this.tick();
    this._interval = setInterval(() => this.tick(), 1000);
  },
  updated() {
    this.tick();
  },
  destroyed() {
    clearInterval(this._interval);
  },
  tick() {
    const el = this.el;
    const startedAt = el.dataset.startedAt;
    const startedAtsRaw = el.dataset.startedAts;
    const completed = parseInt(el.dataset.completedSeconds || "0", 10);
    const turnCountAttr = el.dataset.turnCount;
    const turnCount = turnCountAttr ? parseInt(turnCountAttr, 10) : null;

    const format = (secs) => {
      secs = Math.max(0, Math.floor(secs));
      const m = Math.floor(secs / 60);
      const s = secs % 60;
      return `${m}m ${s}s`;
    };

    if (startedAt) {
      const start = new Date(startedAt);
      let diff = (Date.now() - start.getTime()) / 1000;
      if (isNaN(diff) || diff < 0) diff = 0;
      let text = format(diff);
      if (turnCount && turnCount > 0) {
        text += ` \u00B7 ${turnCount} ${turnCount === 1 ? "turn" : "turns"}`;
      }
      el.textContent = text;
    } else if (startedAtsRaw) {
      try {
        const arr = JSON.parse(startedAtsRaw);
        let total = isNaN(completed) ? 0 : completed;
        const now = Date.now();
        for (const s of arr) {
          if (!s) continue;
          let diff = (now - new Date(s).getTime()) / 1000;
          if (!isNaN(diff) && diff > 0) total += diff;
        }
        el.textContent = format(total);
      } catch (_e) {}
    }
  },
};

const Hooks = { ClipboardCopy, ThemeToggle, RuntimeClock };

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

// SaladUI server-event bridge: lets components run JS commands pushed from the server.
window.addEventListener("phx:js-exec", ({ detail }) => {
  document.querySelectorAll(detail.to).forEach((el) => {
    liveSocket.execJS(el, el.getAttribute(detail.attr));
  });
});

liveSocket.connect();
window.liveSocket = liveSocket;
