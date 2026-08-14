defmodule SymphonyElixirWeb.IssueDetailLive do
  @moduledoc """
  Drill-down view for a single tracked issue session.
  """

  use SymphonyElixirWeb, :live_view

  alias SymphonyElixirWeb.{ObservabilityPubSub, Presenter}

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    result = load_issue(identifier)

    socket =
      socket
      |> assign(:identifier, identifier)
      |> assign(:current_path, "/sessions")
      |> assign(:result, result)
      |> assign(:page_title, page_title(result, identifier))

    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    result = load_issue(socket.assigns.identifier)

    {:noreply,
     socket
     |> assign(:result, result)
     |> assign(:page_title, page_title(result, socket.assigns.identifier))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.pill_link navigate="/sessions" icon_left="hero-arrow-left">Back to sessions</.pill_link>

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
                <span class="mono break-all rounded bg-muted px-1.5 py-0.5 text-xs"><%= @identifier %></span>
                is not currently tracked by the runtime.
              </p>
              <.pill_link navigate="/sessions" class="mt-5">
                View all sessions
              </.pill_link>
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
    <section aria-labelledby="session-summary-heading">
      <.header>
        <span id="session-summary-heading" class="mono break-all text-[22px] tracking-tight"><%= @identifier %></span>
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-2">
            <.status_badge status={@issue.status} />
            <span class="break-all text-xs text-muted-foreground">Workspace · <%= @issue.workspace.path %></span>
          </span>
        </:subtitle>
        <:actions>
          <.harness_badge harness={harness(@issue)} />
          <.pill_link
            :if={external_issue_url(issue_url(@issue))}
            href={external_issue_url(issue_url(@issue))}
            target="_blank"
            rel="noopener noreferrer"
            icon_right="hero-arrow-top-right-on-square"
          >
            Open in tracker<span class="sr-only"> (opens in new tab)</span>
          </.pill_link>
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
    </section>

    <section aria-labelledby="workspace-heading">
    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <.card_title id="workspace-heading" class="text-[15px] font-semibold">Workspace</.card_title>
        <.card_description class="text-xs">Where the agent operates for this issue.</.card_description>
      </.card_header>
      <.card_content class="space-y-3 p-6">
        <div class="grid gap-1 sm:grid-cols-[10rem_1fr] sm:items-baseline">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Path</p>
          <div class="flex flex-wrap items-center gap-2">
            <p class="mono break-all text-xs leading-relaxed"><%= @issue.workspace.path %></p>
            <.button
              variant="outline"
              size="sm"
              class="rounded-full"
              aria-label={"Copy workspace path for #{@identifier}"}
              phx-hook="ClipboardCopy"
              data-copy={@issue.workspace.path}
              data-label="Copy"
              id={"copy-workspace-#{@identifier}"}
            >
              Copy
            </.button>
          </div>
        </div>
        <.detail_row label="Host" value={@issue.workspace.host || "local"} mono />
        <.detail_row :if={@issue.last_error} label="Last error" value={@issue.last_error} />
      </.card_content>
    </.card>
    </section>

    <section :if={@issue.blocked} aria-labelledby="blocked-context-heading">
    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <.card_title id="blocked-context-heading" class="text-[15px] font-semibold">Blocked context</.card_title>
        <.card_description class="text-xs">Waiting for operator input.</.card_description>
      </.card_header>
      <.card_content class="space-y-3 p-6">
        <.detail_row label="Error" value={@issue.blocked.error || "—"} />
        <.detail_row label="Blocked at" value={@issue.blocked.blocked_at || "—"} mono />
        <.detail_row :if={@issue.blocked.session_id} label="Session ID" value={@issue.blocked.session_id} mono />
        <.detail_row :if={@issue.blocked.state} label="State" value={@issue.blocked.state} />
      </.card_content>
    </.card>
    </section>

    <section :if={@issue.retry} aria-labelledby="retry-context-heading">
    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <.card_title id="retry-context-heading" class="text-[15px] font-semibold">Retry context</.card_title>
        <.card_description class="text-xs">Backing off before the next attempt.</.card_description>
      </.card_header>
      <.card_content class="space-y-3 p-6">
        <.detail_row label="Attempt" value={to_string(@issue.retry.attempt)} mono />
        <.detail_row label="Due at" value={@issue.retry.due_at || "—"} mono />
        <.detail_row label="Error" value={@issue.retry.error || "—"} />
      </.card_content>
    </.card>
    </section>

    <section :if={@issue.running} aria-labelledby="running-session-heading">
    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <.card_title id="running-session-heading" class="text-[15px] font-semibold">Running session</.card_title>
        <.card_description class="text-xs">Live agent activity and token usage.</.card_description>
      </.card_header>
      <.card_content class="space-y-4 p-6">
        <div class="grid gap-3 sm:grid-cols-2">
          <.detail_row label="Session ID" value={@issue.running.session_id || "—"} mono />
          <.detail_row label="State" value={@issue.running.state || "—"} />
          <.detail_row label="Turns" value={to_string(@issue.running.turn_count)} mono />
          <.detail_row label="Started" value={@issue.running.started_at || "—"} mono />
          <.detail_row label="Last event" value={to_string(@issue.running.last_event || "—")} />
          <.detail_row label="Last message" value={@issue.running.last_message || "—"} />
        </div>
        <div class="rounded-xl border border-border bg-muted/40 p-4">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Tokens</p>
          <div class="mt-3 grid grid-cols-3 gap-3">
            <div>
              <p class="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">In</p>
              <p class="numeric mt-1 text-sm font-semibold"><%= @issue.running.tokens.input_tokens || 0 %></p>
            </div>
            <div>
              <p class="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">Out</p>
              <p class="numeric mt-1 text-sm font-semibold"><%= @issue.running.tokens.output_tokens || 0 %></p>
            </div>
            <div>
              <p class="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">Total</p>
              <p class="numeric mt-1 text-sm font-semibold"><%= @issue.running.tokens.total_tokens || 0 %></p>
            </div>
          </div>
        </div>
      </.card_content>
    </.card>
    </section>

    <section aria-labelledby="recent-events-heading">
    <.card class="card-elevated overflow-hidden">
      <.card_header class="border-b border-border/60 bg-muted/20">
        <.card_title id="recent-events-heading" class="text-[15px] font-semibold">Recent events</.card_title>
        <.card_description class="text-xs">Latest agent events for this issue.</.card_description>
      </.card_header>
      <.card_content class="p-0">
        <%= if @issue.recent_events == [] do %>
          <div class="p-6">
            <.empty_state message="No events recorded yet." />
          </div>
        <% else %>
          <div class="p-6">
            <ol class="relative ml-2 border-l border-border pl-6">
              <li
                :for={event <- sorted_events(@issue.recent_events)}
                class="relative mb-6 last:mb-0"
              >
                <span class="absolute -left-[25px] top-1 h-2.5 w-2.5 rounded-full bg-primary ring-4 ring-card">
                </span>
                <p class="break-words text-sm font-medium leading-relaxed"><%= event.message || event.event || "event" %></p>
                <p class="mono break-all mt-1 text-xs text-muted-foreground"><%= event.at %></p>
              </li>
            </ol>
          </div>
        <% end %>
      </.card_content>
    </.card>
    </section>
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

  defp issue_url(issue) when is_map(issue) do
    Map.get(issue, :issue_url) ||
      Map.get(issue, "issue_url") ||
      issue_url_from_nested(Map.get(issue, :running) || Map.get(issue, "running")) ||
      issue_url_from_nested(Map.get(issue, :retry) || Map.get(issue, "retry")) ||
      issue_url_from_nested(Map.get(issue, :blocked) || Map.get(issue, "blocked"))
  end

  defp issue_url(_issue), do: nil

  defp issue_url_from_nested(nil), do: nil

  defp issue_url_from_nested(entry) when is_map(entry) do
    Map.get(entry, :issue_url) || Map.get(entry, "issue_url")
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

  defp sorted_events(events) when is_list(events) do
    Enum.sort_by(
      events,
      fn event -> Map.get(event, :at) || Map.get(event, "at") || "" end,
      :desc
    )
  end

  defp load_issue(identifier) do
    Presenter.issue_payload(identifier, SymphonyElixirWeb.orchestrator(), SymphonyElixirWeb.snapshot_timeout_ms())
  end

  defp page_title({:ok, _issue}, identifier), do: identifier
  defp page_title({:error, _reason}, _identifier), do: "Issue not found"
end
