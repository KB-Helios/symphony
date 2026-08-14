defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use SymphonyElixirWeb, :live_view

  alias SymphonyElixirWeb.{ObservabilityPubSub, Presenter}

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()
    q = ""
    harness_filter = "all"

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:now, DateTime.utc_now())
      |> assign(:q, q)
      |> assign(:harness_filter, harness_filter)
      |> assign(:filtered_running, filtered_running(payload, q, harness_filter))
      |> assign(:filtered_blocked, filtered_blocked(payload, q, harness_filter))
      |> assign(:filtered_retrying, filtered_retrying(payload, q))
      |> assign(:current_path, "/")
      |> assign(:page_title, "Operations")

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_harness", %{"harness" => harness}, socket) do
    normalized = harness |> to_string() |> String.trim() |> String.downcase()

    if normalized in SymphonyElixir.Harness.supported_harnesses() do
      case update_workflow_harness(normalized) do
        :ok ->
          payload = load_payload()

          {:noreply,
           socket
           |> assign(:payload, payload)
           |> assign(:filtered_running, filtered_running(payload, socket.assigns.q, socket.assigns.harness_filter))
           |> assign(:filtered_blocked, filtered_blocked(payload, socket.assigns.q, socket.assigns.harness_filter))
           |> assign(:filtered_retrying, filtered_retrying(payload, socket.assigns.q))
           |> put_flash(:info, "Harness set to #{normalized} for next dispatches.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to update harness: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unknown harness: #{inspect(harness)}")}
    end
  end

  def handle_event("select_harness", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    q = q |> to_string() |> String.trim() |> String.slice(0, 120)
    payload = socket.assigns.payload
    harness_filter = socket.assigns.harness_filter

    {:noreply,
     socket
     |> assign(:q, q)
     |> assign(:filtered_running, filtered_running(payload, q, harness_filter))
     |> assign(:filtered_blocked, filtered_blocked(payload, q, harness_filter))
     |> assign(:filtered_retrying, filtered_retrying(payload, q))}
  end

  def handle_event("search", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", %{"harness" => harness}, socket) do
    normalized = harness |> to_string() |> String.trim() |> String.downcase()
    harness_filter = if normalized in SymphonyElixir.Harness.supported_harnesses(), do: normalized, else: "all"
    payload = socket.assigns.payload
    q = socket.assigns.q

    {:noreply,
     socket
     |> assign(:harness_filter, harness_filter)
     |> assign(:filtered_running, filtered_running(payload, q, harness_filter))
     |> assign(:filtered_blocked, filtered_blocked(payload, q, harness_filter))
     |> assign(:filtered_retrying, filtered_retrying(payload, q))}
  end

  def handle_event("filter", _params, socket) do
    payload = socket.assigns.payload
    q = socket.assigns.q

    {:noreply,
     socket
     |> assign(:harness_filter, "all")
     |> assign(:filtered_running, filtered_running(payload, q, "all"))
     |> assign(:filtered_blocked, filtered_blocked(payload, q, "all"))
     |> assign(:filtered_retrying, filtered_retrying(payload, q))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, _payload} ->
        {:noreply, put_flash(socket, :info, "Refresh requested")}

      {:error, :unavailable} ->
        {:noreply, put_flash(socket, :error, "Orchestrator unavailable")}
    end
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    payload = load_payload()
    q = socket.assigns.q
    harness_filter = socket.assigns.harness_filter

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:now, DateTime.utc_now())
     |> assign(:filtered_running, filtered_running(payload, q, harness_filter))
     |> assign(:filtered_blocked, filtered_blocked(payload, q, harness_filter))
     |> assign(:filtered_retrying, filtered_retrying(payload, q))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Operations
        <:subtitle>
          Live orchestration state — running sessions, retry pressure, token spend, and rate-limit health.
        </:subtitle>
        <:actions>
          <.poll_indicator polling={@payload && @payload[:polling]} />
        </:actions>
      </.header>

      <%= if @payload do %>
        <% {label, description, accent} = operations_state(@payload) %>
        <.operations_status label={label} description={description} accent={accent} />
      <% end %>

      <%= if is_nil(@payload) do %>
        <div role="status" aria-busy="true" aria-label="Loading dashboard" class="space-y-4">
          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
            <div :for={_ <- 1..5} class="h-24 animate-pulse rounded-xl bg-muted/40"></div>
          </div>
          <div class="h-14 animate-pulse rounded-xl bg-muted/40"></div>
          <div class="h-14 animate-pulse rounded-xl bg-muted/40"></div>
          <div class="h-14 animate-pulse rounded-xl bg-muted/40"></div>
        </div>
      <% else %>
        <%= if @payload[:error] do %>
          <.alert variant="destructive" class="card-elevated">
            <.icon name="hero-exclamation-triangle" class="h-4 w-4" />
            <.alert_title>Snapshot unavailable</.alert_title>
            <.alert_description>
              <span class="font-medium"><%= @payload.error.code %>:</span> <%= @payload.error.message %>
            </.alert_description>
          </.alert>
        <% else %>
          <.toolbar q={@q} harness_filter={@harness_filter} />

          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
          <.metric_card
            label="Running"
            value={@payload.counts.running}
            detail="Active issue sessions"
            icon="hero-bolt"
            accent="violet"
          />
          <.metric_card
            label="Retrying"
            value={@payload.counts.retrying}
            detail="Awaiting retry window"
            icon="hero-clock"
            accent="amber"
          />
          <.metric_card
            label="Blocked"
            value={@payload.counts.blocked}
            detail="Paused for operator input"
            icon="hero-pause-circle"
            accent="rose"
          />
          <.metric_card
            label="Total tokens"
            value={format_int(@payload.codex_totals.total_tokens)}
            detail={"In #{format_int(@payload.codex_totals.input_tokens)} · Out #{format_int(@payload.codex_totals.output_tokens)}"}
            icon="hero-cpu-chip"
            accent="zinc"
          />
          <.card class="card-elevated overflow-hidden">
            <.card_header class="pb-2">
              <div class="flex items-center justify-between gap-2">
                <p class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">
                  Runtime
                </p>
                <span class="flex h-7 w-7 items-center justify-center rounded-lg bg-muted text-muted-foreground ring-1 ring-border">
                  <.icon name="hero-timer" class="h-3.5 w-3.5" />
                </span>
              </div>
            </.card_header>
            <.card_content>
              <p
                id="total-runtime"
                phx-hook="RuntimeClock"
                data-completed-seconds={completed_runtime_seconds(@payload)}
                data-started-ats={Jason.encode!(Enum.map(@payload.running, & &1.started_at) |> Enum.reject(&is_nil/1))}
                class="numeric text-[26px] font-semibold tracking-tight leading-none"
              >
                <%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %>
              </p>
              <p class="mt-2 text-xs leading-relaxed text-muted-foreground">Total Codex runtime</p>
            </.card_content>
          </.card>
        </div>

        <div class="grid gap-4 lg:grid-cols-5">
          <.card class="card-elevated lg:col-span-2">
            <.card_header class="pb-3">
              <div class="flex items-center gap-2">
                <span class="flex h-7 w-7 items-center justify-center rounded-lg bg-primary/10 text-primary ring-1 ring-primary/15">
                  <.icon name="hero-command-line" class="h-4 w-4" />
                </span>
                <div>
                  <.card_title class="text-[15px] font-semibold">Agent harness</.card_title>
                  <.card_description class="text-xs">
                    Applies to next dispatches · per-issue <code class="mono rounded bg-muted px-1 py-0.5 text-[11px]">harness:prime</code>
                  </.card_description>
                </div>
              </div>
            </.card_header>
            <.card_content>
              <form phx-change="select_harness">
                <label for="harness-select" class="sr-only">Harness</label>
                <select
                  id="harness-select"
                  name="harness"
                  class="flex h-10 w-full items-center justify-between rounded-xl border border-input bg-background px-3 py-2 text-sm ring-offset-background transition-colors focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
                >
                  <option :for={{value, label} <- harness_select_options()} value={value} selected={@payload[:harness] == value}><%= label %></option>
                </select>
                <p class="mt-2 text-xs text-muted-foreground">
                  Current: <span class="font-medium text-foreground"><%= @payload[:harness] || "codex" %></span>
                </p>
              </form>
            </.card_content>
          </.card>

          <.card class="card-elevated lg:col-span-3">
            <.card_header class="pb-3">
              <div class="flex items-center gap-2">
                <span class="flex h-7 w-7 items-center justify-center rounded-lg bg-amber-500/10 text-amber-600 ring-1 ring-amber-500/15 dark:text-amber-400">
                  <.icon name="hero-signal" class="h-4 w-4" />
                </span>
                <div>
                  <.card_title class="text-[15px] font-semibold">Rate limits</.card_title>
                  <.card_description class="text-xs">Latest upstream snapshot, when available.</.card_description>
                </div>
              </div>
            </.card_header>
            <.card_content>
              <.rate_limits_content rate_limits={@payload.rate_limits} />
            </.card_content>
          </.card>
        </div>

        <.sessions_card
          title="Running sessions"
          description="Active issues, last known agent activity, and token usage."
          entries={@filtered_running}
          empty={if @q != "" or @harness_filter != "all", do: "No sessions match the current filter.", else: "No active sessions — the runtime is idle."}
          kind={:running}
        />

        <.sessions_card
          title="Blocked sessions"
          description="Issues paused because the agent requested operator input or approval."
          entries={@filtered_blocked}
          empty={if @q != "" or @harness_filter != "all", do: "No blocked sessions match the filter.", else: "No blocked sessions."}
          kind={:blocked}
        />

        <.retry_card entries={@filtered_retrying} empty_q={@q} />
        <% end %>
      <% end %>
    </div>
    """
  end

  # ---- components ----

  attr(:polling, :any, default: nil)

  defp poll_indicator(assigns) do
    assigns = assign(assigns, :label, poll_label(assigns.polling))

    ~H"""
    <span
      :if={@label}
      class="inline-flex items-center gap-2 rounded-full border border-border/70 bg-card px-3 py-1.5 text-xs font-medium text-muted-foreground shadow-sm"
    >
      <span class="h-2 w-2 rounded-full bg-violet-500"></span>
      <span class="mono"><%= @label %></span>
    </span>
    """
  end

  attr(:label, :string, required: true)
  attr(:description, :string, required: true)
  attr(:accent, :string, required: true)

  defp operations_status(assigns) do
    assigns =
      assign(
        assigns,
        :icon,
        case assigns.accent do
          "emerald" -> "hero-check-circle"
          "amber" -> "hero-exclamation-triangle"
          "rose" -> "hero-exclamation-triangle"
          _ -> "hero-pause-circle"
        end
      )

    ~H"""
    <div
      id="operations-status"
      role="status"
      aria-live="polite"
      class={[
        "card-elevated flex items-center gap-3 rounded-xl border px-4 py-3",
        @accent == "emerald" && "border-emerald-200 bg-emerald-50 text-emerald-950 dark:border-emerald-900/50 dark:bg-emerald-950/30 dark:text-emerald-100",
        @accent == "amber" && "border-amber-200 bg-amber-50 text-amber-950 dark:border-amber-900/50 dark:bg-amber-950/30 dark:text-amber-100",
        @accent == "rose" && "border-rose-200 bg-rose-50 text-rose-950 dark:border-rose-900/50 dark:bg-rose-950/30 dark:text-rose-100",
        @accent == "zinc" && "border-border bg-muted/40 text-foreground"
      ]}
    >
      <span class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-card/70 ring-1 ring-current/10">
        <.icon name={@icon} class="h-4 w-4" />
      </span>
      <div>
        <p class="text-sm font-semibold"><%= @label %></p>
        <p class="text-xs text-muted-foreground"><%= @description %></p>
      </div>
    </div>
    """
  end

  attr(:q, :string, required: true)
  attr(:harness_filter, :string, required: true)

  defp toolbar(assigns) do
    ~H"""
    <.card class="card-elevated">
      <.card_content class="flex flex-wrap items-center gap-3 p-3 sm:p-4">
        <form phx-change="search" class="flex min-w-[220px] flex-1 items-center gap-2">
          <div class="relative flex-1">
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
            />
            <input
              type="text"
              name="q"
              value={@q}
              placeholder="Filter by issue…"
              phx-debounce="300"
              autocomplete="off"
              class="flex h-9 w-full rounded-xl border border-input bg-background py-2 pl-9 pr-3 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
            />
          </div>
        </form>

        <form phx-change="filter" class="flex items-center gap-2">
          <label for="toolbar-harness" class="sr-only">Harness filter</label>
          <select
            id="toolbar-harness"
            name="harness"
            class="flex h-9 items-center justify-between rounded-xl border border-input bg-background px-3 py-2 text-sm ring-offset-background transition-colors focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
          >
            <option :for={{value, label} <- harness_filter_options()} value={value} selected={@harness_filter == value}><%= label %></option>
          </select>
        </form>

        <.button
          phx-click="refresh"
          phx-disable-with="Refreshing…"
          aria-label="Refresh dashboard"
          variant="outline"
          size="sm"
          class="h-9 rounded-xl px-4 text-sm"
        >
          <.icon name="hero-arrow-path" class="mr-1.5 h-4 w-4" /> Refresh
        </.button>
      </.card_content>
    </.card>
    """
  end

  attr(:rate_limits, :any, required: true)

  defp rate_limits_content(assigns) do
    ~H"""
    <%= if is_nil(@rate_limits) or not is_map(@rate_limits) do %>
      <p class="py-6 text-center text-sm text-muted-foreground">— unavailable</p>
    <% else %>
      <% primary = rate_limit_bucket(@rate_limits, ["primary", :primary]) %>
      <% secondary = rate_limit_bucket(@rate_limits, ["secondary", :secondary]) %>
      <% credits = rate_limit_bucket(@rate_limits, ["credits", :credits]) %>
      <% limit_id =
        Map.get(@rate_limits, "limit_id") || Map.get(@rate_limits, :limit_id) ||
          Map.get(@rate_limits, "limit_name") || Map.get(@rate_limits, :limit_name) %>
      <div class="grid grid-cols-2 gap-3">
        <div class="rounded-xl border border-border bg-muted/30 p-3">
          <p class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">Primary</p>
          <p class="mt-1.5">
            <span class="inline-flex rounded-full bg-card px-2.5 py-1 text-xs font-medium ring-1 ring-border">
              <%= format_rate_limit_bucket(primary) %>
            </span>
          </p>
        </div>
        <div class="rounded-xl border border-border bg-muted/30 p-3">
          <p class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">Secondary</p>
          <p class="mt-1.5">
            <span class="inline-flex rounded-full bg-card px-2.5 py-1 text-xs font-medium ring-1 ring-border">
              <%= format_rate_limit_bucket(secondary) %>
            </span>
          </p>
        </div>
      </div>
      <div class="mt-3 flex flex-wrap items-center gap-2 rounded-xl border border-border/60 bg-muted/20 px-3 py-2.5">
        <span class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">Credits</span>
        <span class="inline-flex rounded-full bg-card px-2.5 py-1 text-xs font-medium ring-1 ring-border">
          <%= format_rate_limit_credits(credits) %>
        </span>
        <span :if={limit_id} class="mono ml-auto text-xs text-muted-foreground"><%= limit_id %></span>
      </div>
    <% end %>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, default: nil)
  attr(:icon, :string, default: "hero-sparkles")
  attr(:accent, :string, default: "zinc")

  defp metric_card(assigns) do
    ~H"""
    <.card class="card-elevated overflow-hidden">
      <.card_header class="pb-2">
        <div class="flex items-center justify-between gap-2">
          <p class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">
            <%= @label %>
          </p>
          <span class={[
            "flex h-7 w-7 items-center justify-center rounded-lg ring-1",
            @accent == "violet" && "bg-violet-500/10 text-violet-600 ring-violet-500/15 dark:text-violet-400",
            @accent == "amber" && "bg-amber-500/10 text-amber-600 ring-amber-500/15 dark:text-amber-400",
            @accent == "rose" && "bg-rose-500/10 text-rose-600 ring-rose-500/15 dark:text-rose-400",
            @accent == "zinc" && "bg-muted text-muted-foreground ring-border"
          ]}>
            <.icon name={@icon} class="h-3.5 w-3.5" />
          </span>
        </div>
      </.card_header>
      <.card_content>
        <p role="status" aria-live="polite" aria-atomic="true" class="numeric text-[26px] font-semibold tracking-tight leading-none"><%= @value %></p>
        <p :if={@detail} class="mt-2 text-xs leading-relaxed text-muted-foreground"><%= @detail %></p>
      </.card_content>
    </.card>
    """
  end

  attr(:title, :string, required: true)
  attr(:description, :string, required: true)
  attr(:entries, :list, required: true)
  attr(:empty, :string, required: true)
  attr(:kind, :atom, required: true)

  defp sessions_card(assigns) do
    ~H"""
    <section aria-labelledby={"#{@kind}-sessions-heading"}>
    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <.card_title id={"#{@kind}-sessions-heading"} class="text-[15px] font-semibold"><%= @title %></.card_title>
            <.card_description class="text-xs"><%= @description %></.card_description>
          </div>
          <span class={[
            "inline-flex items-center rounded-full border px-2.5 py-1 text-xs font-medium",
            @kind == :running && "border-violet-200 bg-violet-50 text-violet-700 dark:border-violet-900/50 dark:bg-violet-950/40 dark:text-violet-300",
            @kind == :blocked && "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/30 dark:text-amber-300"
          ]}>
            <%= length(@entries) %> <%= if length(@entries) == 1, do: "session", else: "sessions" %>
          </span>
        </div>
      </.card_header>
      <.card_content class="p-0">
        <%= if @entries == [] do %>
          <div class="p-6">
            <.empty_state message={@empty} />
          </div>
        <% else %>
          <div class="hidden overflow-x-auto md:block">
            <.table>
              <.table_caption class="sr-only"><%= @title %> table</.table_caption>
              <.table_header>
                <.table_row class="hover:bg-transparent">
                  <.th>Issue</.th>
                  <.th>State</.th>
                  <.th>Harness</.th>
                  <.th>Session</.th>
                  <.th><%= if @kind == :running, do: "Runtime / turns", else: "Blocked at" %></.th>
                  <.th>Last update</.th>
                  <%= if @kind == :running do %>
                    <.th>Tokens</.th>
                  <% else %>
                    <.th>Error</.th>
                  <% end %>
                </.table_row>
              </.table_header>
              <.table_body>
                <.table_row
                  :for={entry <- @entries}
                  class="group transition-colors hover:bg-muted/40"
                >
                  <.table_cell>
                    <div class="grid gap-1">
                      <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                      <.link
                        navigate={"/sessions/#{entry.issue_identifier}"}
                        class="inline-flex w-fit items-center gap-1 text-xs font-medium text-primary hover:underline"
                      >
                        View details <.icon name="hero-arrow-right" class="h-3 w-3" />
                      </.link>
                    </div>
                  </.table_cell>
                  <.table_cell>
                    <.state_badge state={entry.state || "Blocked"} />
                  </.table_cell>
                  <.table_cell>
                    <.harness_badge harness={entry.harness} />
                  </.table_cell>
                  <.table_cell>
                    <%= if entry.session_id do %>
                      <.button
                        variant="outline"
                        size="sm"
                        aria-label={"Copy session ID for #{entry.issue_identifier}"}
                        data-label="Copy ID"
                        data-copy={entry.session_id}
                        phx-hook="ClipboardCopy"
                        id={"copy-#{@kind}-#{entry.issue_identifier}"}
                        class="h-7 rounded-full px-3 text-xs"
                      >
                        Copy ID
                      </.button>
                    <% else %>
                      <span class="text-xs text-muted-foreground">—</span>
                    <% end %>
                  </.table_cell>
                  <.table_cell class="numeric whitespace-nowrap text-xs">
                    <%= if @kind == :running do %>
                      <span
                        id={"runtime-#{entry.issue_identifier}"}
                        phx-hook="RuntimeClock"
                        data-started-at={entry.started_at}
                        data-turn-count={entry.turn_count}
                      >
                        <%= format_runtime_and_turns(entry.started_at, entry.turn_count, DateTime.utc_now()) %>
                      </span>
                    <% else %>
                      <span class="mono"><%= entry.blocked_at || "—" %></span>
                    <% end %>
                  </.table_cell>
                  <.table_cell>
                    <div class="grid max-w-[22rem] gap-0.5">
                      <span
                        class="truncate text-sm font-medium"
                        title={entry.last_message || to_string(entry.last_event || "n/a")}
                      >
                        <%= entry.last_message || to_string(entry.last_event || "n/a") %>
                      </span>
                      <span class="truncate text-xs text-muted-foreground">
                        <%= entry.last_event || "n/a" %>
                        <span :if={entry.last_event_at} class="mono">· <%= entry.last_event_at %></span>
                      </span>
                    </div>
                  </.table_cell>
                  <%= if @kind == :running do %>
                    <.table_cell>
                      <div class="numeric grid gap-0.5 text-sm">
                        <span class="font-medium">Total <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="text-xs text-muted-foreground">
                          In <%= format_int(entry.tokens.input_tokens) %> · Out <%= format_int(entry.tokens.output_tokens) %>
                        </span>
                      </div>
                    </.table_cell>
                  <% else %>
                    <.table_cell class="max-w-48 truncate text-sm"><%= entry.error || "—" %></.table_cell>
                  <% end %>
                </.table_row>
              </.table_body>
            </.table>
          </div>
          <div id={"#{@kind}-sessions-mobile"} class="grid gap-3 p-4 md:hidden">
            <article :for={entry <- @entries} class="rounded-xl border border-border/70 bg-card p-3 shadow-sm">
              <div class="flex items-start justify-between gap-3">
                <div class="grid gap-1">
                  <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                  <.link
                    navigate={"/sessions/#{entry.issue_identifier}"}
                    class="inline-flex w-fit items-center gap-1 text-xs font-medium text-primary hover:underline"
                  >
                    View details <.icon name="hero-arrow-right" class="h-3 w-3" />
                  </.link>
                </div>
                <.state_badge state={entry.state || "Blocked"} />
              </div>
              <div class="mt-3 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                <.harness_badge harness={entry.harness} />
                <span :if={entry.worker_host} class="mono rounded bg-muted px-2 py-1">Host <%= entry.worker_host %></span>
                <span :if={@kind == :running} class="mono"> <%= format_runtime_and_turns(entry.started_at, entry.turn_count, DateTime.utc_now()) %></span>
                <span :if={@kind == :blocked} class="mono">Blocked <%= entry.blocked_at || "—" %></span>
              </div>
              <.button
                :if={entry.session_id}
                variant="outline"
                size="sm"
                aria-label={"Copy session ID for #{entry.issue_identifier}"}
                data-label="Copy ID"
                data-copy={entry.session_id}
                phx-hook="ClipboardCopy"
                id={"copy-mobile-#{@kind}-#{entry.issue_identifier}"}
                class="mt-3 h-7 rounded-full px-3 text-xs"
              >
                Copy ID
              </.button>
              <p class="mt-3 text-sm"><%= entry.last_message || entry.error || to_string(entry.last_event || "n/a") %></p>
            </article>
          </div>
        <% end %>
      </.card_content>
    </.card>
    </section>
    """
  end

  attr(:entries, :list, required: true)
  attr(:empty_q, :string, default: "")

  defp retry_card(assigns) do
    ~H"""
    <section aria-labelledby="retrying-sessions-heading">
    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <div class="flex items-start justify-between gap-3">
          <div>
            <.card_title id="retrying-sessions-heading" class="text-[15px] font-semibold">Retry queue</.card_title>
            <.card_description class="text-xs">Issues waiting for the next retry window.</.card_description>
          </div>
          <span class="inline-flex items-center rounded-full border border-border bg-card px-2.5 py-1 text-xs font-medium text-muted-foreground">
            <%= length(@entries) %> queued
          </span>
        </div>
      </.card_header>
      <.card_content class="p-0">
        <%= if @entries == [] do %>
          <div class="p-6">
            <.empty_state message={
              if @empty_q != "", do: "No retry entries match the filter.", else: "No issues are currently backing off."
            } />
          </div>
        <% else %>
          <div class="hidden overflow-x-auto md:block">
            <.table>
              <.table_caption class="sr-only">Retry queue table</.table_caption>
              <.table_header>
                <.table_row class="hover:bg-transparent">
                  <.th>Issue</.th>
                  <.th>Attempt</.th>
                  <.th>Due at</.th>
                  <.th>Error</.th>
                </.table_row>
              </.table_header>
              <.table_body>
                <.table_row :for={entry <- @entries} class="hover:bg-muted/40">
                  <.table_cell>
                    <div class="grid gap-1">
                      <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                      <.link
                        navigate={"/sessions/#{entry.issue_identifier}"}
                        class="text-xs font-medium text-primary hover:underline"
                      >
                        View details
                      </.link>
                    </div>
                  </.table_cell>
                  <.table_cell class="numeric text-xs">
                    <span class="inline-flex rounded-full bg-muted px-2 py-1 text-xs font-medium">#<%= entry.attempt %></span>
                  </.table_cell>
                  <.table_cell class="mono whitespace-nowrap text-xs"><%= entry.due_at || "—" %></.table_cell>
                  <.table_cell class="max-w-64 truncate text-sm"><%= entry.error || "—" %></.table_cell>
                </.table_row>
              </.table_body>
            </.table>
          </div>
          <div id="retrying-sessions-mobile" class="grid gap-3 p-4 md:hidden">
            <article :for={entry <- @entries} class="rounded-xl border border-border/70 bg-card p-3 shadow-sm">
              <div class="flex items-start justify-between gap-3">
                <div class="grid gap-1">
                  <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                  <.link
                    navigate={"/sessions/#{entry.issue_identifier}"}
                    class="inline-flex w-fit items-center gap-1 text-xs font-medium text-primary hover:underline"
                  >
                    View details <.icon name="hero-arrow-right" class="h-3 w-3" />
                  </.link>
                </div>
                <span class="inline-flex rounded-full bg-muted px-2 py-1 text-xs font-medium">Attempt #<%= entry.attempt %></span>
              </div>
              <div class="mt-3 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                <span class="rounded bg-muted px-2 py-1">Retrying</span>
                <span :if={entry.worker_host} class="mono rounded bg-muted px-2 py-1">Host <%= entry.worker_host %></span>
                <span class="mono">Due <%= entry.due_at || "—" %></span>
              </div>
              <p class="mt-3 text-sm"><%= entry.error || "—" %></p>
            </article>
          </div>
        <% end %>
      </.card_content>
    </.card>
    </section>
    """
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <.link
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
        class="font-semibold tracking-tight underline decoration-border underline-offset-4 hover:decoration-foreground"
      >
        <%= @identifier %>
      </.link>
    <% else %>
      <span class="font-semibold tracking-tight"><%= @identifier %></span>
    <% end %>
    """
  end

  # ---- data / formatting helpers ----

  defp operations_state(payload) do
    cond do
      payload[:error] ->
        {"Unavailable", "Snapshot data cannot be loaded.", "rose"}

      payload.counts.blocked > 0 or payload.counts.retrying > 0 ->
        {"Attention required", "Blocked or retrying work needs review.", "amber"}

      payload.counts.running > 0 ->
        {"Operational", "Sessions are actively running.", "emerald"}

      true ->
        {"Runtime idle", "No sessions are currently active.", "zinc"}
    end
  end

  defp poll_label(%{checking: true}), do: "checking now…"

  defp poll_label(%{next_poll_in_ms: ms}) when is_integer(ms) do
    "next check in #{max(div(ms + 999, 1_000), 0)}s"
  end

  defp poll_label(_polling), do: nil

  defp load_payload do
    Presenter.state_payload(orchestrator(), SymphonyElixirWeb.snapshot_timeout_ms())
  end

  defp orchestrator do
    SymphonyElixirWeb.orchestrator()
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now)
       when is_integer(turn_count) and turn_count > 0 do
    turn_label = if turn_count == 1, do: "turn", else: "turns"
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} · #{turn_count} #{turn_label}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "—"

  # ---- filter helpers ----

  defp filtered_running(payload, q, harness_filter) do
    (Map.get(payload, :running) || [])
    |> Enum.filter(&matches_identifier?(&1.issue_identifier, q))
    |> Enum.filter(&matches_harness?(&1.harness, harness_filter))
  end

  defp filtered_blocked(payload, q, harness_filter) do
    (Map.get(payload, :blocked) || [])
    |> Enum.filter(&matches_identifier?(&1.issue_identifier, q))
    |> Enum.filter(&matches_harness?(&1.harness, harness_filter))
  end

  defp filtered_retrying(payload, q) do
    Enum.filter(Map.get(payload, :retrying) || [], &matches_identifier?(&1.issue_identifier, q))
  end

  defp matches_identifier?(_identifier, q) when q == "" or is_nil(q), do: true

  defp matches_identifier?(identifier, q) when is_binary(identifier) and is_binary(q) do
    String.contains?(String.downcase(identifier), String.downcase(q))
  end

  defp matches_identifier?(_identifier, _q), do: false

  defp matches_harness?(_harness, "all"), do: true

  defp matches_harness?(harness, filter) when is_binary(harness) and is_binary(filter) do
    String.downcase(harness) == filter
  end

  # Sessions without a recorded harness count as the default ("codex").
  defp matches_harness?(_harness, filter), do: filter == "codex"

  # ---- rate limit helpers ----

  defp rate_limit_bucket(rate_limits, keys) when is_map(rate_limits) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(rate_limits, key) end)
  end

  defp format_rate_limit_bucket(nil), do: "n/a"

  defp format_rate_limit_bucket(bucket) when is_map(bucket) do
    remaining = Map.get(bucket, "remaining") || Map.get(bucket, :remaining)
    limit = Map.get(bucket, "limit") || Map.get(bucket, :limit)

    reset_value =
      Map.get(bucket, "reset_in_seconds") || Map.get(bucket, :reset_in_seconds) ||
        Map.get(bucket, "resetInSeconds") || Map.get(bucket, :resetInSeconds) ||
        Map.get(bucket, "reset_at") || Map.get(bucket, :reset_at) ||
        Map.get(bucket, "resetAt") || Map.get(bucket, :resetAt) ||
        Map.get(bucket, "resets_at") || Map.get(bucket, :resets_at) ||
        Map.get(bucket, "resetsAt") || Map.get(bucket, :resetsAt)

    base =
      cond do
        is_integer(remaining) and is_integer(limit) ->
          "#{format_int(remaining)}/#{format_int(limit)}"

        is_integer(remaining) ->
          "remaining #{format_int(remaining)}"

        is_integer(limit) ->
          "limit #{format_int(limit)}"

        map_size(bucket) == 0 ->
          "n/a"

        true ->
          bucket |> inspect(limit: 6) |> String.slice(0, 40)
      end

    if is_nil(reset_value) do
      base
    else
      "#{base} reset #{format_reset_value(reset_value)}"
    end
  end

  defp format_rate_limit_bucket(other), do: to_string(other)

  defp format_rate_limit_credits(nil), do: "credits n/a"

  defp format_rate_limit_credits(credits) when is_map(credits) do
    unlimited = Map.get(credits, "unlimited") == true || Map.get(credits, :unlimited) == true
    has_credits = Map.get(credits, "has_credits") == true || Map.get(credits, :has_credits) == true
    balance = Map.get(credits, "balance") || Map.get(credits, :balance)

    cond do
      unlimited ->
        "credits unlimited"

      has_credits and is_number(balance) ->
        "credits #{format_number(balance)}"

      has_credits ->
        "credits available"

      true ->
        "credits none"
    end
  end

  defp format_rate_limit_credits(other), do: "credits #{to_string(other)}"

  defp format_reset_value(value) when is_integer(value), do: "#{format_int(value)}s"
  defp format_reset_value(value) when is_binary(value), do: value
  defp format_reset_value(value), do: to_string(value)

  defp format_number(value) when is_integer(value), do: format_int(value)

  defp format_number(value) when is_float(value) do
    value
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
  end

  defp update_workflow_harness(kind) do
    SymphonyElixir.WorkflowStore.update_harness(kind)
  end

  defp harness_select_options do
    SymphonyElixir.Harness.supported_harnesses()
    |> Enum.map(fn kind ->
      label =
        case kind do
          "codex" -> "Codex — default"
          "prime" -> "Prime Agent"
          _ -> String.capitalize(kind)
        end

      {kind, label}
    end)
  end

  defp harness_filter_options do
    [{"all", "All harnesses"}] ++
      Enum.map(SymphonyElixir.Harness.supported_harnesses(), fn kind ->
        {kind, String.capitalize(kind)}
      end)
  end
end
