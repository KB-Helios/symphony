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
      navigator.clipboard?.writeText(text).then(() => {
        this.el.textContent = "Copied";
        clearTimeout(this._t);
        this._t = setTimeout(() => (this.el.textContent = label), 1200);
      }).catch(() => {
        this.el.textContent = "Failed";
        clearTimeout(this._t);
        this._t = setTimeout(() => (this.el.textContent = label), 1200);
      });
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

const Hooks = { ClipboardCopy, ThemeToggle };

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
