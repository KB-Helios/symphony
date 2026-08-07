defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use SymphonyElixirWeb, :component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:favicon_url, SymphonyElixirWeb.StaticAssets.favicon_url())

    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <meta name="color-scheme" content="light dark" />
        <title>Symphony — Observability</title>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Geist+Mono:wght@400;500&display=swap"
          rel="stylesheet"
        />
        <link rel="icon" type="image/png" sizes="128x128" href={@favicon_url} />
        <link rel="stylesheet" href={~p"/assets/app.css"} />
        <script>
          // Apply persisted theme before first paint to avoid a flash.
          (function () {
            try {
              var theme = localStorage.getItem("symphony-theme");
              var dark =
                theme === "dark" ||
                (!theme && window.matchMedia("(prefers-color-scheme: dark)").matches);
              if (dark) document.documentElement.classList.add("dark");
            } catch (e) {}
          })();
        </script>
        <script defer phx-track-static src={~p"/assets/app.js"}></script>
      </head>
      <body class="h-full bg-background text-foreground antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    current = assigns[:current_path] || "/"
    assigns = assign(assigns, :current, current)

    ~H"""
    <div class="flex min-h-screen">
      <aside class="hidden w-[272px] shrink-0 flex-col border-r border-border/70 bg-card/95 backdrop-blur supports-[backdrop-filter]:bg-card/80 md:flex">
        <div class="flex h-[64px] items-center gap-3 border-b border-border/70 px-5">
          <span class="flex h-9 w-9 items-center justify-center rounded-xl bg-primary text-[13px] font-bold tracking-tight text-primary-foreground shadow-sm ring-1 ring-primary/20">
            S
          </span>
          <div class="min-w-0 leading-tight">
            <p class="text-[13px] font-semibold tracking-tight">Symphony</p>
            <p class="text-[11px] font-medium tracking-wide text-muted-foreground">OBSERVABILITY</p>
          </div>
        </div>

        <nav class="flex-1 space-y-1 px-3 py-5">
          <p class="px-3 pb-2 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground/80">
            Navigate
          </p>
          <.nav_link href="/" current={@current} icon="hero-squares-2x2">Overview</.nav_link>
          <.nav_link href="/sessions" current={@current} icon="hero-bolt">Sessions</.nav_link>
        </nav>

        <div class="space-y-3 border-t border-border/70 p-3">
          <div class="rounded-xl border border-border/70 bg-muted/40 px-3 py-3">
            <p class="text-xs font-semibold">Orchestrator</p>
            <p class="mt-1 text-xs leading-relaxed text-muted-foreground">
              Live snapshot via OTP + Linear polling.
            </p>
          </div>
          <button
            type="button"
            id="theme-toggle"
            phx-hook="ThemeToggle"
            class="flex w-full items-center justify-between rounded-xl border border-border/70 bg-card px-3 py-2.5 text-sm font-medium text-muted-foreground shadow-sm transition-colors hover:bg-accent hover:text-accent-foreground"
          >
            <span class="inline-flex items-center gap-2">
              <.icon name="hero-sun" class="h-4 w-4 dark:hidden" />
              <.icon name="hero-moon" class="hidden h-4 w-4 dark:block" />
              <span class="dark:hidden">Light</span>
              <span class="hidden dark:inline">Dark</span>
            </span>
            <span class="rounded-full bg-muted px-2 py-0.5 text-[11px] font-medium text-muted-foreground">
              <span class="dark:hidden">◐</span><span class="hidden dark:inline">◑</span>
            </span>
          </button>
        </div>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <div class="sticky top-0 z-20 flex h-[64px] items-center justify-between gap-4 border-b border-border/70 bg-background/80 px-4 backdrop-blur supports-[backdrop-filter]:bg-background/60 sm:px-6 lg:px-8">
          <div class="flex items-center gap-3 md:hidden">
            <span class="flex h-8 w-8 items-center justify-center rounded-lg bg-primary text-xs font-bold text-primary-foreground">
              S
            </span>
            <span class="text-sm font-semibold tracking-tight">Symphony</span>
            <div class="relative ml-2 inline-flex md:hidden">
              <select
                onchange="window.location.href = this.value"
                class="h-8 appearance-none rounded-lg border border-border bg-card px-3 pr-7 text-xs font-medium shadow-sm hover:bg-accent hover:text-accent-foreground focus:outline-none focus:ring-2 focus:ring-ring"
              >
                <option value="/" selected={@current == "/"}>Overview</option>
                <option value="/sessions" selected={String.starts_with?(@current, "/sessions")}>Sessions</option>
              </select>
              <span class="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground">▼</span>
            </div>
          </div>
          <nav class="hidden items-center gap-1 md:flex">
            <.top_nav_link href="/" current={@current}>Overview</.top_nav_link>
            <.top_nav_link href="/sessions" current={@current}>Sessions</.top_nav_link>
          </nav>
          <div class="flex items-center gap-2">
            <span class="hidden items-center gap-2 rounded-full border border-border/70 bg-card px-3 py-1.5 text-xs font-medium shadow-sm sm:inline-flex">
              <span class="relative flex h-2 w-2">
                <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-60 [data-phx-main:not(.phx-connected)_&]:hidden">
                </span>
                <span class="relative inline-flex h-2 w-2 rounded-full bg-emerald-500 [data-phx-main:not(.phx-connected)_&]:bg-muted-foreground">
                </span>
              </span>
              <span class="[data-phx-main:not(.phx-connected)_&]:hidden">Live</span>
              <span class="hidden [data-phx-main:not(.phx-connected)_&]:inline">Offline</span>
            </span>
            <button
              type="button"
              id="theme-toggle-mobile"
              phx-hook="ThemeToggle"
              aria-label="Toggle theme"
              class="inline-flex h-9 w-9 items-center justify-center rounded-full border border-border/70 bg-card text-muted-foreground shadow-sm hover:bg-accent hover:text-accent-foreground md:hidden"
            >
              <.icon name="hero-sun" class="h-4 w-4 dark:hidden" />
              <.icon name="hero-moon" class="hidden h-4 w-4 dark:block" />
            </button>
          </div>
        </div>

        <div class="symphony-mesh border-b border-border/60 bg-gradient-to-b from-card to-background">
          <div class="mx-auto w-full max-w-7xl px-4 py-6 sm:px-6 sm:py-8 lg:px-8">
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div class="min-w-0">
                <p class="text-[11px] font-semibold uppercase tracking-[0.14em] text-primary">Symphony Elixir</p>
                <h1 class="mt-1 text-[22px] font-semibold tracking-tight sm:text-[26px]">Observability</h1>
                <p class="mt-2 max-w-2xl text-sm leading-relaxed text-muted-foreground">
                  Track agent sessions, retry pressure, and harness health — one coherent cockpit for the active runtime.
                </p>
              </div>
              <div class="flex flex-wrap items-center gap-2">
                <.link
                  navigate="/sessions"
                  class="inline-flex h-9 items-center justify-center rounded-full bg-primary px-4 text-sm font-medium text-primary-foreground shadow-sm transition-colors hover:bg-primary/90"
                >
                  View sessions
                </.link>
                <span class="inline-flex items-center gap-2 rounded-full border border-border/70 bg-card px-3 py-1.5 text-xs text-muted-foreground shadow-sm">
                  <span class="h-2 w-2 rounded-full bg-violet-500"></span> Violet theme
                </span>
              </div>
            </div>
          </div>
        </div>

        <main class="mx-auto w-full max-w-7xl flex-1 px-4 py-6 sm:px-6 sm:py-8 lg:px-8">
          {@inner_content}
        </main>

        <footer class="border-t border-border/60 px-4 py-6 text-xs text-muted-foreground sm:px-6 lg:px-8">
          <div class="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3">
            <span>Symphony Elixir · Observability dashboard</span>
            <span class="mono text-[11px]">SaladUI · Tailwind v4 · LiveView</span>
          </div>
        </footer>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr(:href, :string, required: true)
  attr(:current, :string, required: true)
  slot(:inner_block, required: true)

  defp top_nav_link(assigns) do
    href = assigns.href
    current = assigns.current
    active = current == href || (href == "/sessions" && String.starts_with?(current, "/sessions"))
    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@href}
      class={[
        "rounded-full px-3.5 py-1.5 text-sm font-medium transition-colors",
        @active && "bg-accent text-accent-foreground",
        !@active && "text-muted-foreground hover:bg-accent/60 hover:text-accent-foreground"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr(:href, :string, required: true)
  attr(:current, :string, required: true)
  attr(:icon, :string, required: true)
  slot(:inner_block, required: true)

  defp nav_link(assigns) do
    href = assigns.href
    current = assigns.current
    active = current == href || (href == "/sessions" && String.starts_with?(current, "/sessions"))
    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@href}
      class={[
        "group flex items-center gap-3 rounded-xl px-3 py-2.5 text-[13px] font-medium transition-colors",
        @active && "bg-primary text-primary-foreground shadow-sm ring-1 ring-primary/15",
        !@active && "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
      ]}
    >
      <.icon
        name={@icon}
        class={if(@active, do: "h-4 w-4 shrink-0 opacity-100", else: "h-4 w-4 shrink-0 opacity-70 group-hover:opacity-100")}
      />
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
