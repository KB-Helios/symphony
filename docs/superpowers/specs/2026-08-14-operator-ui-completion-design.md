# Operator UI Completion Design

## Context

Symphony already exposes a Phoenix LiveView observability interface with three browser routes:

- `/` for the operational overview
- `/sessions` for all tracked sessions
- `/sessions/:identifier` for a single issue session

The UI has the right data sources and core route structure, but the experience is not yet complete across responsive layouts, navigation, operational states, and direct route and interaction coverage. This change completes the existing interface without expanding Symphony into a rich control plane.

## Goals

- Deliver a coherent, responsive operator experience across every existing browser route.
- Make running, blocked, retrying, unavailable, disconnected, empty, and filtered-empty states clear.
- Preserve the existing refresh and next-dispatch harness controls.
- Improve keyboard, screen-reader, focus, contrast, and reduced-motion behavior.
- Add direct LiveView coverage for routes, navigation, filtering, sorting, pagination, updates, and errors.
- Keep the implementation inside the current Phoenix LiveView, SaladUI, Tailwind, and JavaScript stack.

## Non-goals

- No authentication, authorization, account, team, billing, or multi-tenant UI.
- No new settings persistence, audit log, database, API, frontend framework, or component dependency.
- No historical analytics that the current in-memory runtime cannot provide truthfully.
- No deployment, tracker, scheduler, or agent-runtime behavior changes.

## Information Architecture

### Overview (`/`)

The overview remains the first operational surface. It presents orchestrator availability, polling state, counts for running, blocked, and retrying work, token totals, aggregate runtime, rate-limit information, the existing refresh action, and the existing next-dispatch harness selector.

Running, blocked, and retrying collections use consistent status language and link to the matching session detail route. Search and harness filtering remain local LiveView state and continue to operate on the current snapshot.

### Sessions (`/sessions`)

The sessions page remains the complete directory for tracked work. It supports status tabs, issue search, column sorting, and pagination. Desktop widths use a semantic table. Narrow widths use a card presentation generated from the same normalized row data, avoiding a second filtering or sorting implementation.

Every session entry exposes the issue identifier, orchestration status, tracker state, harness when available, worker host, and latest meaningful detail. Selecting an entry uses LiveView navigation to the detail route.

### Session Detail (`/sessions/:identifier`)

The detail page presents status, harness, attempts, workspace path and host, running-session metadata, token usage, blocked context, retry context, and recent events. The existing clipboard and safe external tracker-link behavior remains available.

Unknown identifiers render a useful in-app not-found state with a route back to the session directory. Long paths, errors, messages, and identifiers wrap without forcing horizontal page overflow.

### Browser Not Found

Unknown browser paths render an HTML not-found surface inside the shared visual language. JSON API routes retain their existing JSON error contract.

## Shared Application Shell

The shell uses one consistent hierarchy across all pages:

- A skip link targets the main content region.
- Desktop widths use the existing fixed-width sidebar with Overview and Sessions navigation.
- Mobile widths use a compact sticky header with the same two destinations and no hidden-only action.
- The active route is conveyed visually and with `aria-current="page"`.
- Connection state and theme controls remain available without obscuring page content.
- Page titles use LiveView's dynamic title component so route changes update the document title.
- The main content region has a stable maximum width, responsive padding, and a visible focus target.
- The footer retains the application version without competing with operational content.

The design reuses SaladUI primitives for cards, alerts, badges, buttons, and tables. App-specific function components remain limited to patterns that carry Symphony semantics: navigation, page headers, metrics, status presentation, empty states, and responsive session collections.

## Data and Interaction Flow

`SymphonyElixirWeb.Presenter` remains the only UI data boundary. Each LiveView loads a presenter payload on mount and subscribes to `ObservabilityPubSub` after connection. PubSub notifications reload the current snapshot without adding client-side caching or a second state store.

Search, filter, sort, tab, and pagination events update socket assigns and derive visible rows from the loaded payload. Refresh delegates to the existing presenter refresh call. Harness selection keeps its existing validated workflow update path and affects future dispatches only.

Desktop tables and mobile cards consume the same normalized rows. The existing JavaScript hooks remain responsible only for theme persistence, clipboard copy feedback, and the live runtime clock.

## State and Error Behavior

Each route provides explicit behavior for:

- initial loading
- successful data with entries
- successful data with no entries
- filters with no matches
- presenter or orchestrator unavailability
- LiveView disconnection and reconnection
- unknown issue identifiers
- unknown browser routes

Unavailable snapshots preserve navigation and explain that runtime data cannot be loaded. Empty states distinguish an idle runtime from a filter that matches nothing. Unsafe tracker URLs are omitted. User-provided or external text is rendered as escaped content, and URL handling continues to allow only valid `http` and `https` targets.

## Responsive and Accessible Behavior

- Semantic landmarks cover navigation, main content, status, tables, and page footer.
- All actions have visible labels or accessible names and work with a keyboard.
- Focus indicators remain visible in normal and forced-color modes.
- Status is never conveyed by color alone.
- Loading and changing metrics use restrained live-region semantics to avoid excessive announcements.
- Tables retain captions and column sort state; mobile cards retain equivalent labels.
- Motion-heavy decoration and pulsing indicators are disabled when `prefers-reduced-motion: reduce` is active.
- Layouts are inspected at desktop and mobile widths in both light and dark themes.

## Verification

Implementation follows test-driven development for behavior changes. Direct LiveView tests cover:

- every browser route and shared navigation
- loading, populated, empty, unavailable, and not-found states
- search, status filtering, harness filtering, sorting, and pagination
- refresh and harness-selection results
- PubSub-driven updates
- safe and unsafe tracker links
- HTML browser fallback versus JSON API error behavior

Local verification includes focused web tests, formatting, static analysis that can run on Windows, and production asset compilation. The repository's complete suite is Linux-oriented and has a known failing Windows baseline because it assumes `sh`, Unix symlinks, fake SSH binaries, and `/tmp` semantics. Hosted Linux CI is therefore the authoritative full `make -C elixir all` gate for the PR.

## Acceptance Criteria

- All three operator pages and the browser not-found state share the completed application shell.
- Desktop and mobile layouts expose equivalent information and actions without page-level horizontal overflow.
- Existing refresh, harness selection, theme, clipboard, navigation, and live-update behavior is preserved.
- Each operational state has a clear, accessible presentation and recovery path where applicable.
- No new runtime or frontend dependency is added.
- Focused local UI checks pass, production assets compile, and hosted Linux CI passes the full repository gate.
