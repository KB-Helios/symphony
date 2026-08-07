defmodule SymphonyElixirWeb.IssueDetailLive do
  @moduledoc """
  Drill-down view for a single tracked issue session.
  """

  use SymphonyElixirWeb, :live_view

  alias Phoenix.LiveView.JS
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    socket =
      socket
      |> assign(:identifier, identifier)
      |> assign(:current_path, "/sessions")
      |> assign(:result, load_issue(identifier))

    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :result, load_issue(socket.assigns.identifier))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.link
        navigate="/sessions"
        class="inline-flex items-center gap-1.5 rounded-full border border-border bg-card px-3 py-1.5 text-xs font-medium shadow-sm hover:bg-accent hover:text-accent-foreground"
      >
        <.icon name="hero-arrow-left" class="h-3.5 w-3.5" /> Back to sessions
      </.link>

      <%= case @result do %>
        <% {:ok, issue} -> %>
          <.issue_detail issue={issue} identifier={@identifier} />
        <% {:error, :issue_not_found} -> %>
          <.card class="card-elevated overflow-hidden">
            <.card_content class="flex flex-col items-center justify-center py-16 text-center">
              <span class="flex h-12 w-12 items-center justify-center rounded-2xl bg-muted text-muted-foreground">
                <.icon name="hero-magnifying-glass" class="h-6 w-6" />
              </span>
              <p class="mt-4 text-lg font-semibold tracking-tight">Issue not found</p>
              <p class="mt-1 max-w-md text-sm leading-relaxed text-muted-foreground">
                <span class="mono rounded bg-muted px-1.5 py-0.5 text-xs"><%= @identifier %></span>
                is not currently tracked by the runtime.
              </p>
              <.button
                variant="outline"
                size="sm"
                class="mt-5 rounded-full"
                phx-click={JS.navigate("/sessions")}
              >
                View all sessions
              </.button>
            </.card_content>
          </.card>
      <% end %>
    </div>
    """
  end

  attr(:issue, :map, required: true)
  attr(:identifier, :string, required: true)

  defp issue_detail(assigns) do
    ~H"""
    <.header>
      <span class="mono text-[22px] tracking-tight"><%= @identifier %></span>
      <:subtitle>
        <span class="inline-flex flex-wrap items-center gap-2">
          <.status_badge status={@issue.status} />
          <span class="text-xs text-muted-foreground">Workspace · <%= @issue.workspace.path %></span>
        </span>
      </:subtitle>
      <:actions>
        <span class="inline-flex items-center rounded-full border border-border bg-card px-3 py-1.5 text-xs font-medium shadow-sm">
          Harness: <span class="ml-1 font-semibold"><%= harness(@issue) %></span>
        </span>
      </:actions>
    </.header>

    <div class="grid gap-4 sm:grid-cols-3">
      <.card class="card-elevated">
        <.card_header class="pb-2">
          <p class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">Status</p>
        </.card_header>
        <.card_content>
          <p class="text-[20px] font-semibold capitalize tracking-tight"><%= @issue.status %></p>
          <p class="mt-1 text-xs text-muted-foreground">Current orchestration state</p>
        </.card_content>
      </.card>

      <.card class="card-elevated">
        <.card_header class="pb-2">
          <p class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">Attempts</p>
        </.card_header>
        <.card_content>
          <p class="numeric text-[20px] font-semibold tracking-tight"><%= @issue.attempts.current_retry_attempt %></p>
          <p class="mt-1 text-xs text-muted-foreground">
            <%= @issue.attempts.restart_count %> restart(s) · retry window
          </p>
        </.card_content>
      </.card>

      <.card class="card-elevated">
        <.card_header class="pb-2">
          <p class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">Harness</p>
        </.card_header>
        <.card_content>
          <p class="text-[20px] font-semibold tracking-tight"><%= harness(@issue) %></p>
          <p class="mt-1 text-xs text-muted-foreground">Agent executing this issue</p>
        </.card_content>
      </.card>
    </div>

    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <.card_title class="text-[15px] font-semibold">Workspace</.card_title>
        <.card_description class="text-xs">Where the agent operates for this issue.</.card_description>
      </.card_header>
      <.card_content class="space-y-3 p-6">
        <.detail_row label="Path" value={@issue.workspace.path} mono />
        <.detail_row label="Host" value={@issue.workspace.host || "local"} mono />
        <.detail_row :if={@issue.last_error} label="Last error" value={@issue.last_error} />
      </.card_content>
    </.card>

    <.card :if={@issue.running} class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <.card_title class="text-[15px] font-semibold">Running session</.card_title>
        <.card_description class="text-xs">Live agent activity and token usage.</.card_description>
      </.card_header>
      <.card_content class="space-y-4 p-6">
        <div class="grid gap-3 sm:grid-cols-2">
          <.detail_row label="Session ID" value={@issue.running.session_id || "—"} mono />
          <.detail_row label="State" value={@issue.running.state || "—"} />
          <.detail_row label="Turns" value={to_string(@issue.running.turn_count)} mono />
          <.detail_row label="Started" value={@issue.running.started_at || "—"} mono />
          <.detail_row label="Last event" value={@issue.running.last_event || "—"} />
          <.detail_row label="Last message" value={@issue.running.last_message || "—"} />
        </div>
        <div class="grid gap-1 rounded-xl border border-border bg-muted/40 p-4">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Tokens</p>
          <p class="numeric text-sm font-medium">
            Total <%= @issue.running.tokens.total_tokens || 0 %> · In <%= @issue.running.tokens.input_tokens || 0 %> · Out <%= @issue.running.tokens.output_tokens || 0 %>
          </p>
        </div>
      </.card_content>
    </.card>

    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <.card_title class="text-[15px] font-semibold">Recent events</.card_title>
        <.card_description class="text-xs">Latest agent events for this issue.</.card_description>
      </.card_header>
      <.card_content class="p-0">
        <%= if @issue.recent_events == [] do %>
          <div class="p-6">
            <div class="flex flex-col items-center justify-center rounded-xl border border-dashed border-border/70 bg-muted/20 py-10 text-center">
              <span class="flex h-10 w-10 items-center justify-center rounded-xl bg-muted text-muted-foreground">
                <.icon name="hero-inbox" class="h-5 w-5" />
              </span>
              <p class="mt-3 text-sm text-muted-foreground">No events recorded yet.</p>
            </div>
          </div>
        <% else %>
          <ul class="divide-y divide-border/60">
            <li :for={event <- @issue.recent_events} class="flex gap-3 px-6 py-4">
              <span class="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary ring-1 ring-primary/15">
                <.icon name="hero-bolt" class="h-3.5 w-3.5" />
              </span>
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium leading-relaxed"><%= event.message || event.event || "event" %></p>
                <p class="mono mt-1 text-xs text-muted-foreground"><%= event.at %></p>
              </div>
            </li>
          </ul>
        <% end %>
      </.card_content>
    </.card>
    """
  end

  attr(:status, :string, required: true)

  defp status_badge(assigns) do
    variant =
      case assigns.status do
        "running" -> "default"
        "blocked" -> "destructive"
        "retrying" -> "secondary"
        _ -> "outline"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.badge variant={@variant} class="rounded-full px-2.5 py-0.5 text-[11px] font-medium capitalize"><%= @status %></.badge>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:mono, :boolean, default: false)

  defp detail_row(assigns) do
    ~H"""
    <div class="grid gap-1 sm:grid-cols-[10rem_1fr] sm:items-baseline">
      <p class="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground"><%= @label %></p>
      <p class={["break-words text-sm leading-relaxed", @mono && "mono text-xs"]}><%= @value %></p>
    </div>
    """
  end

  defp harness(issue) do
    (issue.running && issue.running.harness) ||
      (issue.blocked && issue.blocked.harness) ||
      "codex"
  end

  defp load_issue(identifier) do
    Presenter.issue_payload(identifier, orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
