defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use SymphonyElixirWeb, :live_view

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:current_path, "/")

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_harness", %{"harness" => harness}, socket) do
    normalized = harness |> to_string() |> String.trim() |> String.downcase()

    case normalized do
      kind when kind in ["codex", "prime"] ->
        case update_workflow_harness(kind) do
          :ok ->
            {:noreply,
             socket
             |> assign(:payload, load_payload())
             |> put_flash(:info, "Harness set to #{kind} for next dispatches.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to update harness: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Unknown harness: #{inspect(harness)}")}
    end
  end

  def handle_event("select_harness", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
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
          <.connection_badge />
        </:actions>
      </.header>

      <%= if @payload[:error] do %>
        <.alert variant="destructive" class="card-elevated">
          <.icon name="hero-exclamation-triangle" class="h-4 w-4" />
          <.alert_title>Snapshot unavailable</.alert_title>
          <.alert_description>
            <span class="font-medium"><%= @payload.error.code %>:</span> <%= @payload.error.message %>
          </.alert_description>
        </.alert>
      <% else %>
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
          <.metric_card
            label="Runtime"
            value={format_runtime_seconds(total_runtime_seconds(@payload, @now))}
            detail="Total Codex runtime"
            icon="hero-timer"
            accent="zinc"
          />
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
                  <option value="codex" selected={@payload[:harness] == "codex"}>Codex — default</option>
                  <option value="prime" selected={@payload[:harness] == "prime"}>Prime Agent</option>
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
              <pre class="mono max-h-36 overflow-auto rounded-xl border border-border bg-muted/60 p-4 text-xs leading-relaxed"><%= pretty_value(@payload.rate_limits) %></pre>
            </.card_content>
          </.card>
        </div>

        <.sessions_card
          title="Running sessions"
          description="Active issues, last known agent activity, and token usage."
          entries={@payload.running}
          empty="No active sessions — the runtime is idle."
          now={@now}
          kind={:running}
        />

        <.sessions_card
          title="Blocked sessions"
          description="Issues paused because the agent requested operator input or approval."
          entries={@payload.blocked}
          empty="No blocked sessions."
          now={@now}
          kind={:blocked}
        />

        <.retry_card entries={@payload.retrying} />
      <% end %>
    </div>
    """
  end

  # ---- components ----

  defp connection_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2 rounded-full border border-border/70 bg-card px-3 py-1.5 text-xs font-medium shadow-sm">
      <span class="relative flex h-2 w-2">
        <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-60 [data-phx-main:not(.phx-connected)_&]:hidden">
        </span>
        <span class="relative inline-flex h-2 w-2 rounded-full bg-emerald-500 [data-phx-main:not(.phx-connected)_&]:bg-zinc-400">
        </span>
      </span>
      <span class="[data-phx-main:not(.phx-connected)_&]:hidden">Live</span>
      <span class="hidden [data-phx-main:not(.phx-connected)_&]:inline">Offline</span>
    </span>
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
        <p class="numeric text-[26px] font-semibold tracking-tight leading-none"><%= @value %></p>
        <p :if={@detail} class="mt-2 text-xs leading-relaxed text-muted-foreground"><%= @detail %></p>
      </.card_content>
    </.card>
    """
  end

  attr(:title, :string, required: true)
  attr(:description, :string, required: true)
  attr(:entries, :list, required: true)
  attr(:empty, :string, required: true)
  attr(:now, DateTime, required: true)
  attr(:kind, :atom, required: true)

  defp sessions_card(assigns) do
    ~H"""
    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <.card_title class="text-[15px] font-semibold"><%= @title %></.card_title>
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
          <div class="overflow-x-auto">
            <.table>
              <.table_header>
                <.table_row class="hover:bg-transparent">
                  <.table_head class="text-[11px] uppercase tracking-wide">Issue</.table_head>
                  <.table_head class="text-[11px] uppercase tracking-wide">State</.table_head>
                  <.table_head class="text-[11px] uppercase tracking-wide">Harness</.table_head>
                  <.table_head class="text-[11px] uppercase tracking-wide">Session</.table_head>
                  <.table_head class="text-[11px] uppercase tracking-wide"><%= if @kind == :running, do: "Runtime / turns", else: "Blocked at" %></.table_head>
                  <.table_head class="text-[11px] uppercase tracking-wide">Last update</.table_head>
                  <%= if @kind == :running do %>
                    <.table_head class="text-[11px] uppercase tracking-wide">Tokens</.table_head>
                  <% else %>
                    <.table_head class="text-[11px] uppercase tracking-wide">Error</.table_head>
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
                      <%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %>
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
        <% end %>
      </.card_content>
    </.card>
    """
  end

  attr(:entries, :list, required: true)

  defp retry_card(assigns) do
    ~H"""
    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <div class="flex items-start justify-between gap-3">
          <div>
            <.card_title class="text-[15px] font-semibold">Retry queue</.card_title>
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
            <.empty_state message="No issues are currently backing off." />
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <.table>
              <.table_header>
                <.table_row class="hover:bg-transparent">
                  <.table_head class="text-[11px] uppercase tracking-wide">Issue</.table_head>
                  <.table_head class="text-[11px] uppercase tracking-wide">Attempt</.table_head>
                  <.table_head class="text-[11px] uppercase tracking-wide">Due at</.table_head>
                  <.table_head class="text-[11px] uppercase tracking-wide">Error</.table_head>
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
        <% end %>
      </.card_content>
    </.card>
    """
  end

  attr(:message, :string, required: true)

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center rounded-xl border border-dashed border-border/70 bg-muted/20 py-10 text-center">
      <span class="flex h-10 w-10 items-center justify-center rounded-xl bg-muted text-muted-foreground">
        <.icon name="hero-inbox" class="h-5 w-5" />
      </span>
      <p class="mt-3 max-w-sm text-sm leading-relaxed text-muted-foreground"><%= @message %></p>
    </div>
    """
  end

  attr(:state, :string, required: true)

  defp state_badge(assigns) do
    normalized = String.downcase(to_string(assigns.state))

    variant =
      cond do
        String.contains?(normalized, ["progress", "running", "active"]) -> "default"
        String.contains?(normalized, ["blocked", "error", "failed"]) -> "destructive"
        String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "secondary"
        true -> "outline"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.badge variant={@variant} class="rounded-full px-2.5 py-0.5 text-[11px] font-medium"><%= @state %></.badge>
    """
  end

  attr(:harness, :string, default: nil)

  defp harness_badge(assigns) do
    label = if assigns.harness == "prime", do: "prime", else: "codex"
    variant = if assigns.harness == "prime", do: "secondary", else: "outline"
    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.badge variant={@variant} class="rounded-full px-2.5 py-0.5 text-[11px] font-medium uppercase tracking-wide"><%= @label %></.badge>
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

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
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
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} · #{turn_count} turns"
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

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "—"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp update_workflow_harness(kind) do
    path = SymphonyElixir.Workflow.workflow_file_path()

    with {:ok, content} <- File.read(path) do
      updated =
        if String.contains?(content, "harness:") do
          Regex.replace(~r/harness:\s*\n(?:[ \t]+kind:.*\n?)*/, content, "harness:\n  kind: #{kind}\n")
          |> then(fn c ->
            if String.contains?(c, "kind: #{kind}"),
              do: c,
              else: String.replace(c, ~r/harness:\s*\n/, "harness:\n  kind: #{kind}\n", global: false)
          end)
        else
          String.replace(content, "---\n", "---\nharness:\n  kind: #{kind}\n", global: false)
        end

      case File.write(path, updated) do
        :ok ->
          SymphonyElixir.WorkflowStore.force_reload()
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
