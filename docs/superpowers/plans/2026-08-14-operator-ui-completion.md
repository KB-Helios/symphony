# Operator UI Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Symphony's responsive operator UI across the overview, session directory, session detail, and browser not-found routes.

**Architecture:** Keep Phoenix LiveView and `SymphonyElixirWeb.Presenter` as the only UI state boundary. Reuse SaladUI and the existing app-specific components, derive desktop and mobile views from the same socket assigns, and add one small HTML controller/component fallback for browser not-found pages while preserving `/api/*` JSON behavior.

**Tech Stack:** Elixir 1.19.5 / OTP 28, Phoenix 1.8, Phoenix LiveView 1.1, SaladUI 0.14, Tailwind CSS 4, ExUnit, Phoenix.LiveViewTest.

## Global Constraints

- Add no runtime or frontend dependency.
- Preserve refresh, next-dispatch harness selection, theme, clipboard, navigation, and PubSub update behavior.
- Keep `SymphonyElixirWeb.Presenter` as the only UI data boundary; do not add client-side state or caching.
- Keep JSON responses for `/api/*`, including unknown API routes and unsupported methods.
- Render external text as escaped content and allow tracker links only for valid `http` and `https` URLs.
- Desktop and mobile presentations must consume the same normalized rows and expose equivalent content and actions.
- Use explicit loading, populated, idle, filtered-empty, unavailable, disconnected, and not-found states.
- Local Windows verification uses focused web tests and asset compilation; hosted Linux CI is the authoritative `make -C elixir all` gate.
- Keep the original `production/vps-readiness` checkout and its uncommitted deployment documents untouched.
- On this Windows host, initialize each PowerShell test shell with `$env:MISE_PWSH_CHPWD_WARNING = "0"; (& mise activate pwsh) | Out-String | Invoke-Expression`; subsequent plan commands use `mix` directly.

## File Map

- `elixir/lib/symphony_elixir_web/components/layouts.ex`: root document, skip link, shared navigation, connection state, content landmark, dynamic title.
- `elixir/lib/symphony_elixir_web/components/core_components.ex`: only shared Symphony-specific status, empty-state, and link/button primitives.
- `elixir/lib/symphony_elixir_web/controllers/browser_fallback_controller.ex`: status-preserving HTML fallback action.
- `elixir/lib/symphony_elixir_web/controllers/browser_fallback_html.ex`: in-app fallback content rendered inside the shared shell.
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`: operational status summary and responsive overview collections.
- `elixir/lib/symphony_elixir_web/live/sessions_live.ex`: normalized directory rows, semantic filters, desktop table, mobile cards, pagination.
- `elixir/lib/symphony_elixir_web/live/issue_detail_live.ex`: accessible session summary, workspace, context, token, and event sections.
- `elixir/lib/symphony_elixir_web/router.ex`: exact API routing, `/api/*` JSON fallback, browser HTML fallback.
- `elixir/assets/css/app.css`: system font stack and existing design tokens only; no new CSS component layer.
- `elixir/test/symphony_elixir/extensions_test.exs`: route and LiveView interaction coverage using the existing endpoint/orchestrator fixtures.
- `elixir/README.md`: completed browser route and responsive/error behavior documentation.

---

### Task 1: Accessible application shell and browser fallback

**Files:**
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Modify: `elixir/lib/symphony_elixir_web/components/layouts.ex`
- Create: `elixir/lib/symphony_elixir_web/controllers/browser_fallback_controller.ex`
- Create: `elixir/lib/symphony_elixir_web/controllers/browser_fallback_html.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`

**Interfaces:**
- Consumes: `SymphonyElixirWeb.Layouts.app/1`, `SymphonyElixirWeb.Router`, existing `StaticOrchestrator`, `start_test_endpoint/1`, and `static_snapshot/0` test helpers.
- Produces: a status-preserving browser fallback rendered inside `Layouts.app/1`, `main#main-content`, `#skip-to-content`, primary navigation with `aria-current`, and a browser-only catch-all after `/api/*` routes.

- [ ] **Step 1: Write failing shell and route-boundary tests**

Add these tests beside the existing dashboard LiveView tests:

```elixir
test "shared shell exposes keyboard navigation and route state" do
  orchestrator_name = Module.concat(__MODULE__, :ShellOrchestrator)

  {:ok, _pid} =
    StaticOrchestrator.start_link(
      name: orchestrator_name,
      snapshot: static_snapshot(),
      health: %{ready?: true}
    )

  start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

  {:ok, overview, _html} = live(build_conn(), "/")
  assert has_element?(overview, "#skip-to-content[href='#main-content']", "Skip to content")
  assert has_element?(overview, "main#main-content[tabindex='-1']")
  assert has_element?(overview, "nav[aria-label='Primary'] a[aria-current='page'][href='/']")

  {:ok, sessions, _html} = live(build_conn(), "/sessions")
  assert has_element?(sessions, "nav[aria-label='Primary'] a[aria-current='page'][href='/sessions']")
end

test "browser fallback is HTML while unknown API routes stay JSON" do
  orchestrator_name = Module.concat(__MODULE__, :FallbackOrchestrator)

  {:ok, _pid} =
    StaticOrchestrator.start_link(
      name: orchestrator_name,
      snapshot: static_snapshot(),
      health: %{ready?: true}
    )

  start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

  conn = get(build_conn(), "/missing-page")
  html = html_response(conn, 404)
  assert html =~ "Page not found"
  assert html =~ ~s(id="skip-to-content")
  assert html =~ ~s(href="/sessions")
  assert html =~ "View sessions"

  assert json_response(get(build_conn(), "/api/v1/missing"), 404) ==
           %{"error" => %{"code" => "not_found", "message" => "Route not found"}}
end
```

The first test catches removal of the keyboard entry point or active-route semantics. The second catches a browser fallback that accidentally converts `/api/*` failures to HTML.

- [ ] **Step 2: Run the focused tests and verify RED**

Run from `elixir/`:

```bash
mix test test/symphony_elixir/extensions_test.exs
```

Expected: FAIL because `#skip-to-content` and `main#main-content` do not exist, and `/missing-page` returns the JSON catch-all.

- [ ] **Step 3: Implement the minimal shared shell**

In `Layouts.root/1`, replace the static title with LiveView's title component, remove the external Google Fonts requests, and add a skip link before `@inner_content`:

```heex
<Phoenix.Component.live_title default="Observability" suffix=" · Symphony">
  {@page_title}
</Phoenix.Component.live_title>
```

Default `:page_title` to `nil` in the root assigns. Tasks 2-4 normalize the route values to `"Sessions"`, `"Operations"`, and the issue identifier so the suffix is not duplicated.

```heex
<a
  id="skip-to-content"
  href="#main-content"
  class="sr-only fixed left-4 top-4 z-[100] rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground focus:not-sr-only"
>
  Skip to content
</a>
{@inner_content}
```

In `Layouts.app/1`:

- give both desktop and mobile navigation `aria-label="Primary"`;
- keep the existing active-route calculation and `aria-current="page"`;
- change the content element to `<main id="main-content" tabindex="-1" ...>`;
- change the connection pulse to `motion-safe:animate-ping` so reduced-motion users receive a static indicator;
- retain both theme controls and the version footer.

- [ ] **Step 4: Add the status-preserving browser fallback and route ordering**

Create `browser_fallback_controller.ex`:

```elixir
defmodule SymphonyElixirWeb.BrowserFallbackController do
  @moduledoc "HTML fallback for unknown browser routes."

  use Phoenix.Controller, formats: [:html]

  alias Plug.Conn

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(html: SymphonyElixirWeb.BrowserFallbackHTML)
    |> render(:not_found, page_title: "Page not found")
  end
end
```

Create `browser_fallback_html.ex`:

```elixir
defmodule SymphonyElixirWeb.BrowserFallbackHTML do
  @moduledoc "Shared-shell HTML for unknown browser routes."

  use SymphonyElixirWeb, :component

  alias SymphonyElixirWeb.Layouts

  @spec not_found(map()) :: Phoenix.LiveView.Rendered.t()
  def not_found(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={nil}>
      <div class="mx-auto max-w-xl py-12 text-center sm:py-20">
        <.card class="card-elevated overflow-hidden">
          <.card_content class="flex flex-col items-center p-8 sm:p-12">
            <span class="mono text-xs font-semibold uppercase tracking-[0.16em] text-primary">404</span>
            <h1 class="mt-3 text-2xl font-semibold tracking-tight">Page not found</h1>
            <p class="mt-2 max-w-md text-sm leading-relaxed text-muted-foreground">
              This route is not part of the Symphony operator interface.
            </p>
            <div class="mt-6 flex flex-wrap justify-center gap-2">
              <.pill_link href="/" icon_left="hero-squares-2x2">Open overview</.pill_link>
              <.pill_link href="/sessions" icon_left="hero-bolt">View sessions</.pill_link>
            </div>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
```

Order router fallbacks as follows:

```elixir
scope "/", SymphonyElixirWeb do
  # Existing exact API routes and method-not-allowed routes remain first.
  match(:*, "/api/*path", ObservabilityApiController, :not_found)
end

scope "/", SymphonyElixirWeb do
  pipe_through(:browser)
  get("/*path", BrowserFallbackController, :not_found)
end

scope "/", SymphonyElixirWeb do
  match(:*, "/*path", ObservabilityApiController, :not_found)
end
```

Keep the exact `/`, `/sessions`, and `/sessions/:identifier` routes before these fallbacks. Remove the old general GET catch-all from the API block so unknown browser GETs reach `BrowserFallbackController` with a real 404 status.

- [ ] **Step 5: Update the existing missing-asset assertions**

The existing asset-pipeline test currently uses `json_response/2` for `/dashboard.css` and `/vendor/phoenix/phoenix.js`. Replace those assertions with:

```elixir
assert html_response(get(build_conn(), "/dashboard.css"), 404) =~ "Page not found"
assert html_response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 404) =~ "Page not found"
```

This preserves the essential behavior: the obsolete assets are not served, the HTTP status is 404, and the response is browser-readable HTML.

- [ ] **Step 6: Run tests, format, and verify GREEN**

```bash
mix format lib/symphony_elixir_web/components/layouts.ex lib/symphony_elixir_web/controllers/browser_fallback_controller.ex lib/symphony_elixir_web/controllers/browser_fallback_html.ex lib/symphony_elixir_web/router.ex test/symphony_elixir/extensions_test.exs
mix test test/symphony_elixir/extensions_test.exs
mix specs.check
```

Expected: the focused test file passes with zero failures and the specs check reports no missing public-function specs.

- [ ] **Step 7: Commit the shell and fallback**

```bash
git add elixir/lib/symphony_elixir_web/components/layouts.ex elixir/lib/symphony_elixir_web/controllers/browser_fallback_controller.ex elixir/lib/symphony_elixir_web/controllers/browser_fallback_html.ex elixir/lib/symphony_elixir_web/router.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "feat(ui): complete operator shell and browser fallback"
```

---

### Task 2: Responsive session directory

**Files:**
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Modify: `elixir/lib/symphony_elixir_web/live/sessions_live.ex`

**Interfaces:**
- Consumes: `SessionsLive.rows/1`-equivalent normalized maps, current `filtered_rows/3`, `sorted_rows/3`, `paginated_rows/3`, status badges, harness badges, and LiveView navigation.
- Produces: `#sessions-desktop`, `#sessions-mobile`, semantic tab IDs, and one paginated row list shared by both presentations.

- [ ] **Step 1: Write failing responsive-directory tests**

Add a route test:

```elixir
test "sessions exposes equivalent desktop and mobile collections" do
  orchestrator_name = Module.concat(__MODULE__, :SessionsOrchestrator)

  {:ok, _pid} =
    StaticOrchestrator.start_link(
      name: orchestrator_name,
      snapshot: static_snapshot(),
      health: %{ready?: true}
    )

  start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

  {:ok, view, _html} = live(build_conn(), "/sessions")

  assert has_element?(view, "#sessions-desktop table", "MT-HTTP")
  assert has_element?(view, "#sessions-mobile article", "MT-HTTP")
  assert has_element?(view, "#sessions-mobile article", "MT-BLOCKED")
  assert has_element?(view, "#sessions-mobile article", "MT-RETRY")

  view |> form("form[phx-change='search']", %{q: "MT-BLOCKED"}) |> render_change()
  assert has_element?(view, "#sessions-mobile article", "MT-BLOCKED")
  refute has_element?(view, "#sessions-mobile article", "MT-HTTP")
end
```

Add a state-control test:

```elixir
test "sessions filters and sorts through accessible controls" do
  orchestrator_name = Module.concat(__MODULE__, :SessionsControlsOrchestrator)

  {:ok, _pid} =
    StaticOrchestrator.start_link(
      name: orchestrator_name,
      snapshot: static_snapshot(),
      health: %{ready?: true}
    )

  start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

  {:ok, view, _html} = live(build_conn(), "/sessions")
  view |> element("#sessions-tab-blocked") |> render_click()

  assert has_element?(view, "#sessions-panel[aria-labelledby='sessions-tab-blocked']")
  assert has_element?(view, "#sessions-mobile article", "MT-BLOCKED")
  refute has_element?(view, "#sessions-mobile article", "MT-HTTP")

  view |> element("button[phx-value-sort='status']") |> render_click()
  assert has_element?(view, "th[aria-sort='ascending'] button[phx-value-sort='status']")
end
```

Add pagination and state coverage:

```elixir
test "sessions paginates the same rows on mobile" do
  orchestrator_name = Module.concat(__MODULE__, :SessionsPaginationOrchestrator)
  snapshot = static_snapshot()
  template = hd(snapshot.running)

  running =
    for number <- 1..11 do
      suffix = number |> Integer.to_string() |> String.pad_leading(2, "0")

      %{template |
        issue_id: "issue-#{suffix}",
        identifier: "MT-#{suffix}",
        session_id: "thread-#{suffix}"
      }
    end

  snapshot = %{snapshot | running: running, blocked: [], retrying: []}

  {:ok, _pid} =
    StaticOrchestrator.start_link(
      name: orchestrator_name,
      snapshot: snapshot,
      health: %{ready?: true}
    )

  start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

  {:ok, view, _html} = live(build_conn(), "/sessions")
  assert has_element?(view, "#sessions-mobile article", "MT-01")
  refute has_element?(view, "#sessions-mobile article", "MT-11")

  view |> element("button[aria-label='Next page']") |> render_click()
  assert has_element?(view, "#sessions-mobile article", "MT-11")
  refute has_element?(view, "#sessions-mobile article", "MT-01")
end

test "sessions distinguishes idle and unavailable snapshots" do
  empty_name = Module.concat(__MODULE__, :EmptySessionsOrchestrator)
  empty = %{static_snapshot() | running: [], blocked: [], retrying: []}
  {:ok, _pid} = StaticOrchestrator.start_link(name: empty_name, snapshot: empty, health: %{ready?: true})
  start_test_endpoint(orchestrator: empty_name, snapshot_timeout_ms: 50)

  {:ok, _view, empty_html} = live(build_conn(), "/sessions")
  assert empty_html =~ "No sessions yet"

  stop_supervised!(SymphonyElixirWeb.Endpoint)
  missing_name = Module.concat(__MODULE__, :MissingSessionsOrchestrator)
  start_test_endpoint(orchestrator: missing_name, snapshot_timeout_ms: 5)

  {:ok, _view, unavailable_html} = live(build_conn(), "/sessions")
  assert unavailable_html =~ "Snapshot unavailable"
end
```

The first test catches desktop-only regressions. The second catches filters that look selected but do not identify their active panel and sorting controls that do not expose direction. The pagination test catches independently sliced mobile data. The final test characterizes the retained idle and unavailable states before restructuring.

- [ ] **Step 2: Run the new tests and verify RED**

```bash
mix test test/symphony_elixir/extensions_test.exs
```

Expected: FAIL because `#sessions-desktop`, `#sessions-mobile`, tab IDs, and the labelled panel are missing.

- [ ] **Step 3: Render both views from the same paginated rows**

Inside the existing successful-payload branch, keep this derivation exactly once:

```elixir
filtered = filtered_rows(@payload, @tab, @q)
sorted = sorted_rows(filtered, @sort_by, @sort_dir)
total_filtered = length(sorted)
total_pages = total_pages(total_filtered, @per_page)
current_page = clamp_page(@page, total_pages)
paginated = paginated_rows(sorted, current_page, @per_page)
```

Change the existing table wrapper from `<div class="overflow-x-auto">` to `<div id="sessions-desktop" class="hidden overflow-x-auto md:block">`; leave the semantic table inside it unchanged.

Add a narrow-width collection immediately after it:

```heex
<div id="sessions-mobile" class="divide-y divide-border/60 md:hidden">
  <article :for={row <- paginated} class="space-y-3 p-4">
    <div class="flex items-start justify-between gap-3">
      <.link navigate={~p"/sessions/#{row.identifier}"} class="font-semibold tracking-tight">
        {row.identifier}
      </.link>
      <.status_badge status={row.status} />
    </div>
    <dl class="grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
      <div><dt class="text-xs text-muted-foreground">State</dt><dd class="mt-1">{row.state || "—"}</dd></div>
      <div><dt class="text-xs text-muted-foreground">Harness</dt><dd class="mt-1">{row.harness || "—"}</dd></div>
      <div><dt class="text-xs text-muted-foreground">Host</dt><dd class="mono mt-1 text-xs">{row.worker_host || "local"}</dd></div>
      <div class="col-span-2"><dt class="text-xs text-muted-foreground">Latest activity</dt><dd class="mt-1 break-words text-muted-foreground">{row.detail}</dd></div>
    </dl>
  </article>
</div>
```

Do not create a second filter, sort, or pagination helper for mobile.

- [ ] **Step 4: Complete tab and pagination semantics**

Give each tab trigger `id={"sessions-tab-#{@value}"}`. Set the panel to:

```heex
<.card_content
  class="p-0"
  role="tabpanel"
  id="sessions-panel"
  aria-labelledby={"sessions-tab-#{@tab}"}
>
```

Keep pagination below both presentations, and keep its disabled boundaries based on the clamped page.

Set the route title assign to `"Sessions"`; the root layout adds the shared Symphony suffix.

- [ ] **Step 5: Run tests, format, and verify GREEN**

```bash
mix format lib/symphony_elixir_web/live/sessions_live.ex test/symphony_elixir/extensions_test.exs
mix test test/symphony_elixir/extensions_test.exs
mix specs.check
```

Expected: all focused tests pass and there are no public-spec failures.

- [ ] **Step 6: Commit the directory**

```bash
git add elixir/lib/symphony_elixir_web/live/sessions_live.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "feat(ui): complete responsive session directory"
```

---

### Task 3: Operational overview states and interactions

**Files:**
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`

**Interfaces:**
- Consumes: presenter payload counts, polling, rate limits, current refresh and harness-selection events, and existing filtered collections.
- Produces: `#operations-status`, labelled overview sections, responsive running/blocked/retrying collections, and covered refresh/harness outcomes.

- [ ] **Step 1: Write a failing operational-state test**

```elixir
test "overview summarizes health and exposes responsive session collections" do
  orchestrator_name = Module.concat(__MODULE__, :OverviewStatesOrchestrator)
  snapshot = static_snapshot()
  [blocked] = snapshot.blocked
  snapshot = %{snapshot | blocked: [Map.put(blocked, :harness, "prime")]}

  {:ok, _pid} =
    StaticOrchestrator.start_link(
      name: orchestrator_name,
      snapshot: snapshot,
      refresh: %{
        queued: true,
        coalesced: false,
        requested_at: DateTime.utc_now(),
        operations: ["poll"]
      },
      health: %{ready?: true}
    )

  start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

  {:ok, view, _html} = live(build_conn(), "/")

  assert has_element?(view, "#operations-status[role='status']", "Attention required")
  assert has_element?(view, "section[aria-labelledby='running-sessions-heading']")
  assert has_element?(view, "#running-sessions-mobile article", "MT-HTTP")
  assert has_element?(view, "#blocked-sessions-mobile article", "MT-BLOCKED")
  assert has_element?(view, "#retrying-sessions-mobile article", "MT-RETRY")

  view |> form("form[phx-change='search']", %{q: "MT-BLOCKED"}) |> render_change()
  assert has_element?(view, "#blocked-sessions-mobile article", "MT-BLOCKED")
  refute has_element?(view, "#running-sessions-mobile article", "MT-HTTP")

  view |> form("form[phx-change='search']", %{q: ""}) |> render_change()
  view |> form("form[phx-change='filter']", %{harness: "prime"}) |> render_change()
  assert has_element?(view, "#blocked-sessions-mobile article", "MT-BLOCKED")
  refute has_element?(view, "#running-sessions-mobile article", "MT-HTTP")
end
```

Add the idle summary test:

```elixir
test "overview identifies an idle runtime" do
  orchestrator_name = Module.concat(__MODULE__, :IdleOverviewOrchestrator)
  snapshot = %{static_snapshot() | running: [], blocked: [], retrying: []}

  {:ok, _pid} =
    StaticOrchestrator.start_link(
      name: orchestrator_name,
      snapshot: snapshot,
      health: %{ready?: true}
    )

  start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

  {:ok, view, _html} = live(build_conn(), "/")
  assert has_element?(view, "#operations-status[role='status']", "Runtime idle")
end
```

Use `"Attention required"` when blocked or retrying entries exist, `"Operational"` when work is running without blocked/retrying entries, and `"Runtime idle"` when all three collections are empty. This is derived display state, not a new backend health API.

- [ ] **Step 2: Write refresh and harness-selection coverage**

```elixir
test "overview reports refresh and rejects unsupported harness selection" do
  orchestrator_name = Module.concat(__MODULE__, :OverviewControlsOrchestrator)

  {:ok, _pid} =
    StaticOrchestrator.start_link(
      name: orchestrator_name,
      snapshot: static_snapshot(),
      refresh: %{
        queued: true,
        coalesced: false,
        requested_at: DateTime.utc_now(),
        operations: ["poll"]
      },
      health: %{ready?: true}
    )

  start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

  {:ok, view, _html} = live(build_conn(), "/")
  assert render_click(view, "refresh", %{}) =~ "Refresh requested"
  assert render_change(view, "select_harness", %{"harness" => "prime"}) =~
           "Harness set to prime"

  assert Config.settings!().harness.kind == "prime"
  assert render_change(view, "select_harness", %{"harness" => "unsupported"}) =~ "Unknown harness"
end
```

These are characterization checks for retained actions. They must pass before the view is restructured and after the restructuring; if they fail before edits, fix the fixture rather than production code.

- [ ] **Step 3: Run tests and verify the new state test is RED**

```bash
mix test test/symphony_elixir/extensions_test.exs
```

Expected: the action characterization test passes, while the operational-state test fails because the status summary and mobile collection IDs do not exist.

- [ ] **Step 4: Add the derived operations summary**

Add one private `operations_state/1` helper:

```elixir
defp operations_state(payload) do
  cond do
    payload[:error] -> {"Unavailable", "Snapshot data cannot be loaded.", "rose"}
    payload.counts.blocked > 0 or payload.counts.retrying > 0 ->
      {"Attention required", "Blocked or retrying work needs review.", "amber"}
    payload.counts.running > 0 -> {"Operational", "Sessions are actively running.", "emerald"}
    true -> {"Runtime idle", "No sessions are currently active.", "zinc"}
  end
end
```

Render a compact `#operations-status` banner after the page header. Use an icon, label, and explanatory text so color is not the only signal. Do not duplicate `Presenter` health logic.

Set the route title assign to `"Operations"`; the root layout adds the shared Symphony suffix.

- [ ] **Step 5: Complete overview section and mobile semantics**

For each running, blocked, and retrying card:

- add a stable heading ID and wrap the card in `section[aria-labelledby]`;
- retain the existing desktop table at `md` and wider;
- render a compact `article` list below `md` from the same `@entries` assign;
- expose identifier, status/state, harness or attempt, host when present, and latest detail;
- keep the current tracker and detail navigation behavior;
- keep empty messages distinct for idle data and active filters.

Use private components inside `DashboardLive`; do not add a generic data-table abstraction.

- [ ] **Step 6: Run tests, format, and verify GREEN**

```bash
mix format lib/symphony_elixir_web/live/dashboard_live.ex test/symphony_elixir/extensions_test.exs
mix test test/symphony_elixir/extensions_test.exs
mix specs.check
```

Expected: focused tests pass, including the existing PubSub update and unsafe-link assertions.

- [ ] **Step 7: Commit the overview**

```bash
git add elixir/lib/symphony_elixir_web/live/dashboard_live.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "feat(ui): complete operational overview states"
```

---

### Task 4: Complete session detail hierarchy and edge states

**Files:**
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Modify: `elixir/lib/symphony_elixir_web/live/issue_detail_live.ex`

**Interfaces:**
- Consumes: `Presenter.issue_payload/3`, existing safe URL handling, clipboard hook, and PubSub subscription.
- Produces: labelled detail sections, wrapped external text, consistent not-found recovery, and direct detail-route coverage.

- [ ] **Step 1: Write failing detail hierarchy tests**

```elixir
test "session detail exposes labelled operational sections" do
  orchestrator_name = Module.concat(__MODULE__, :DetailOrchestrator)
  snapshot = static_snapshot()
  [running] = snapshot.running
  snapshot = %{snapshot | running: [Map.put(running, :workspace_path, "/workspaces/MT-HTTP")]}

  {:ok, _pid} =
    StaticOrchestrator.start_link(
      name: orchestrator_name,
      snapshot: snapshot,
      health: %{ready?: true}
    )

  start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

  {:ok, view, _html} = live(build_conn(), "/sessions/MT-HTTP")

  assert has_element?(view, "section[aria-labelledby='session-summary-heading']", "MT-HTTP")
  assert has_element?(view, "section[aria-labelledby='workspace-heading']", "/workspaces/MT-HTTP")
  assert has_element?(view, "section[aria-labelledby='running-session-heading']", "thread-http")
  assert has_element?(view, "section[aria-labelledby='recent-events-heading']")
  assert has_element?(view, "button[phx-hook='ClipboardCopy'][data-copy='/workspaces/MT-HTTP']")
  assert has_element?(view, "a[href='https://example.org/issues/MT-HTTP']")
end

test "session detail handles unknown and unsafe issue targets" do
  orchestrator_name = Module.concat(__MODULE__, :DetailSafetyOrchestrator)
  snapshot = put_in(static_snapshot().running, [
    %{hd(static_snapshot().running) | issue_url: "javascript:alert('nope')"}
  ])

  {:ok, _pid} =
    StaticOrchestrator.start_link(
      name: orchestrator_name,
      snapshot: snapshot,
      health: %{ready?: true}
    )

  start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

  {:ok, unsafe_view, _html} = live(build_conn(), "/sessions/MT-HTTP")
  refute has_element?(unsafe_view, "a[href^='javascript:']")

  {:ok, missing_view, html} = live(build_conn(), "/sessions/MT-MISSING")
  assert html =~ "Issue not found"
  assert has_element?(missing_view, "a[href='/sessions']", "View all sessions")
end
```

The first test catches flattened detail markup that loses section relationships. The second catches unsafe external navigation and missing recovery paths.

- [ ] **Step 2: Run tests and verify RED**

```bash
mix test test/symphony_elixir/extensions_test.exs
```

Expected: the labelled-section assertions fail; existing unsafe URL handling should already pass and remains as a regression guard.

- [ ] **Step 3: Add labelled sections without changing presenter data**

Wrap the current detail groups in semantic sections:

```heex
<section aria-labelledby="session-summary-heading">
  <.header>
    <span id="session-summary-heading" class="mono text-[22px] tracking-tight">{@identifier}</span>
    <:subtitle>
      <span class="inline-flex flex-wrap items-center gap-2">
        <.status_badge status={@issue.status} />
        <span class="break-all text-xs text-muted-foreground">Workspace · {@issue.workspace.path}</span>
      </span>
    </:subtitle>
    <:actions><.harness_badge harness={harness(@issue)} /></:actions>
  </.header>
</section>
```

Place the current three-card Status, Attempts, and Harness grid inside this section immediately after the header. Keep the safe tracker action in the header's actions slot beside the harness badge.

Apply stable IDs to Workspace, Blocked context, Retry context, Running session, and Recent events headings. Keep conditional sections conditional. Add `break-words` or `break-all` only at external-text boundaries such as paths, IDs, errors, and messages; do not make every paragraph break arbitrarily.

Keep the not-found card inside the app shell and use `<.pill_link navigate="/sessions">View all sessions</.pill_link>` so the recovery control has normal link semantics.

Set the successful detail route title assign to `identifier`; the root layout adds the shared Symphony suffix.

- [ ] **Step 4: Run tests, format, and verify GREEN**

```bash
mix format lib/symphony_elixir_web/live/issue_detail_live.ex test/symphony_elixir/extensions_test.exs
mix test test/symphony_elixir/extensions_test.exs
mix specs.check
```

Expected: focused tests pass with safe links, the unknown-session state, and all labelled sections covered.

- [ ] **Step 5: Commit the detail page**

```bash
git add elixir/lib/symphony_elixir_web/live/issue_detail_live.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "feat(ui): complete session detail states"
```

---

### Task 5: Documentation, production assets, and real browser acceptance

**Files:**
- Modify: `elixir/assets/css/app.css`
- Modify: `elixir/README.md`
- Verify: `elixir/priv/static/assets/app.css`
- Verify: `elixir/priv/static/assets/app.js`

**Interfaces:**
- Consumes: the completed HEEx views, existing Tailwind/esbuild aliases, and the documented browser routes.
- Produces: an offline-safe system font stack, accurate operator-UI documentation, compiled production assets, and desktop/mobile acceptance evidence.

- [ ] **Step 1: Remove the unused remote-font dependency**

Confirm `Layouts.root/1` no longer links to `fonts.googleapis.com` or `fonts.gstatic.com`. Keep the existing CSS system stacks:

```css
body {
  font-family: Inter, "SF Pro Text", "Helvetica Neue", "Segoe UI", system-ui, sans-serif;
}

code,
pre,
.mono {
  font-family: "Geist Mono", "SFMono-Regular", "SF Mono", Consolas, "Liberation Mono", monospace;
}
```

Do not add local font files. The named fonts remain optional preferences and fall through to installed system fonts.

- [ ] **Step 2: Document the completed UI contract**

Update `elixir/README.md` under `## Web dashboard` to state:

```markdown
- The shared operator shell provides responsive desktop/mobile navigation, theme controls, and connection state.
- Overview and session collections use tables on wider screens and equivalent cards on narrow screens.
- Loading, idle, filtered-empty, unavailable, unknown-session, and unknown-browser-route states remain inside the operator UI.
- Unknown `/api/*` routes continue to return JSON errors.
```

- [ ] **Step 3: Run focused quality and production asset gates**

From `elixir/`:

```bash
mix format --check-formatted
mix specs.check
mix credo --strict
mix test test/symphony_elixir/extensions_test.exs
mix assets.deploy
```

Expected: all commands exit zero; the focused test reports zero failures; `priv/static/assets/app.css` and `app.js` are regenerated successfully. Do not commit generated digest files unless the repository already tracks them.

- [ ] **Step 4: Launch a deterministic local preview**

Create this untracked `.codex-local/ui_preview.exs` helper using `apply_patch`:

```elixir
defmodule SymphonyElixir.UiPreviewOrchestrator do
  use GenServer

  def start_link(snapshot) do
    GenServer.start_link(__MODULE__, snapshot, name: __MODULE__)
  end

  @impl true
  def init(snapshot), do: {:ok, snapshot}

  @impl true
  def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}

  def handle_call(:request_refresh, _from, snapshot) do
    reply = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    {:reply, reply, snapshot}
  end
end

now = DateTime.utc_now()

snapshot = %{
  running: [
    %{
      issue_id: "preview-running",
      identifier: "UI-101",
      issue_url: "https://example.org/issues/UI-101",
      state: "In Progress",
      harness: "codex",
      worker_host: "local",
      workspace_path: "/workspaces/UI-101",
      session_id: "preview-thread",
      turn_count: 4,
      last_codex_message: "Implementing the operator interface",
      last_codex_timestamp: now,
      last_codex_event: :notification,
      codex_input_tokens: 1_200,
      codex_output_tokens: 480,
      codex_total_tokens: 1_680,
      started_at: DateTime.add(now, -420, :second)
    }
  ],
  blocked: [
    %{
      issue_id: "preview-blocked",
      identifier: "UI-102",
      issue_url: "https://example.org/issues/UI-102",
      state: "In Progress",
      harness: "prime",
      worker_host: "worker-02",
      workspace_path: "/workspaces/UI-102",
      session_id: "blocked-thread",
      blocked_at: now,
      error: "Waiting for operator approval",
      last_codex_event: :turn_input_required,
      last_codex_message: "Approval required",
      last_codex_timestamp: now
    }
  ],
  retrying: [
    %{
      issue_id: "preview-retry",
      identifier: "UI-103",
      issue_url: "https://example.org/issues/UI-103",
      attempt: 2,
      due_in_ms: 25_000,
      error: "Temporary provider outage",
      worker_host: "local",
      workspace_path: "/workspaces/UI-103"
    }
  ],
  codex_totals: %{
    input_tokens: 1_200,
    output_tokens: 480,
    total_tokens: 1_680,
    seconds_running: 420.0
  },
  rate_limits: %{
    "primary" => %{"remaining" => 82},
    "secondary" => %{"remaining" => 96},
    "credits" => %{"remaining" => 18.5}
  },
  polling: %{checking?: false, next_poll_in_ms: 12_000, poll_interval_ms: 30_000}
}

{:ok, _apps} = Application.ensure_all_started(:symphony_elixir)
{:ok, _preview} = SymphonyElixir.UiPreviewOrchestrator.start_link(snapshot)

endpoint_config =
  :symphony_elixir
  |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
  |> Keyword.merge(
    server: true,
    http: [ip: {127, 0, 0, 1}, port: 4011],
    orchestrator: SymphonyElixir.UiPreviewOrchestrator,
    snapshot_timeout_ms: 1_000
  )

Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
{:ok, _endpoint} = SymphonyElixirWeb.Endpoint.start_link()
IO.puts("Symphony UI preview: http://127.0.0.1:4011")
Process.sleep(:infinity)
```

Start it with:

```bash
$env:MIX_ENV = "test"
mix run --no-start --no-halt .codex-local/ui_preview.exs
```

Keep this helper and its PID file untracked. Do not point the preview at a real tracker or production orchestrator.

- [ ] **Step 5: Inspect real browser states**

At desktop width (1440×1000) and mobile width (390×844), inspect:

- `/` populated, filtered, light, and dark states;
- `/sessions` table/card parity, status tabs, search, sorting, and pagination boundaries;
- `/sessions/MT-HTTP` and `/sessions/MT-BLOCKED` detail layouts;
- `/sessions/MT-MISSING` recovery state;
- `/missing-page` browser fallback;
- keyboard skip-link entry, visible focus, theme toggle, clipboard feedback, and LiveView connection status.

Capture screenshots under `.codex-local/` and leave the preview running for user inspection. If a layout defect appears, add a failing LiveView assertion when behavior is testable, apply the smallest correction, and rerun Step 3.

- [ ] **Step 6: Commit docs and source-only polish**

```bash
git add elixir/assets/css/app.css elixir/README.md
git commit -m "docs(ui): document completed operator experience"
```

If `app.css` has no source change after confirming the system stack, stage only `elixir/README.md`.

---

### Task 6: Final verification, review, and pull request

**Files:**
- Review: every file changed since `origin/main`
- Create untracked: `.codex-local/pr-body.md`

**Interfaces:**
- Consumes: all prior task commits and `.github/pull_request_template.md`.
- Produces: verified branch `codex/complete-operator-ui`, a focused push to `origin`, a PR against `main`, and terminal hosted Linux checks.

- [ ] **Step 1: Verify the exact diff and worktree scope**

```bash
git status --short --branch
git diff --check origin/main...HEAD
git diff --stat origin/main...HEAD
git diff --name-status origin/main...HEAD
```

Expected: only the design, plan, UI source, UI tests, and UI documentation are present. No deployment secrets, `.codex-local`, compiled dependencies, `_build`, `deps`, or original-checkout documents are tracked.

- [ ] **Step 2: Run final local gates from a clean tree**

```bash
mix format --check-formatted
mix specs.check
mix credo --strict
mix test test/symphony_elixir/extensions_test.exs
mix assets.deploy
```

Expected: every command exits zero. Record the exact focused test count and asset result for the PR body.

- [ ] **Step 3: Request code review and resolve findings**

Review `origin/main...HEAD` against the approved spec. Fix all Critical and Important findings, rerun the affected targeted tests, and rerun Step 2 after the final fix. Keep minor unrelated suggestions out of this PR.

- [ ] **Step 4: Create and validate the PR body**

Create `.codex-local/pr-body.md` with the repository template:

```markdown
#### Context

The operator UI needed complete responsive routes, shared navigation, and explicit runtime states.

#### TL;DR

*Complete Symphony's responsive LiveView operator experience.*

#### Summary

- Complete the shared desktop/mobile shell and browser fallback.
- Add responsive overview, session directory, and detail states.
- Cover routes and interactions with focused LiveView tests.

#### Alternatives

- A writable admin console was excluded because it needs auth, auditing, and new backend contracts.
- A separate SPA was excluded because LiveView already provides the required data and interactions.

#### Test Plan

- [ ] `make -C elixir all`
- [ ] Focused LiveView tests, production asset build, and desktop/mobile browser inspection.
```

Validate it from `elixir/`:

```bash
mix pr_body.check --file ../.codex-local/pr-body.md
```

Expected: `PR body format OK`.

- [ ] **Step 5: Push and create the PR**

```bash
git push -u origin codex/complete-operator-ui
gh pr create --repo KB-Helios/symphony --base main --head codex/complete-operator-ui --title "feat(ui): complete operator experience" --body-file .codex-local/pr-body.md
```

Read the PR back and verify title, base, head, body, changed-file scope, and URL.

- [ ] **Step 6: Wait for hosted Linux checks**

```bash
gh pr checks --watch
```

The PR is complete only when hosted checks reach a terminal state. If Linux CI fails, reproduce the focused failure where possible, fix it test-first, rerun local gates, push the additional commit, and wait for the replacement run. Report any manual browser acceptance separately from automated CI.
