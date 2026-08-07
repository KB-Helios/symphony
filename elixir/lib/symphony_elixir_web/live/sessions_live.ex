defmodule SymphonyElixirWeb.SessionsLive do
  @moduledoc """
  Combined view of every tracked issue session: running, blocked, and retrying.
  """

  use SymphonyElixirWeb, :live_view

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:current_path, "/sessions")

    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload, load_payload())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Sessions
        <:subtitle>
          Every tracked issue across running, blocked, and retry states — tap an issue to drill in.
        </:subtitle>
        <:actions>
          <span class="inline-flex items-center rounded-full border border-border bg-card px-3 py-1.5 text-xs font-medium shadow-sm">
            <%= total(@payload) %> tracked
          </span>
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
        <div class="grid gap-3 sm:grid-cols-3">
          <.mini_stat label="Running" value={length(@payload.running)} tone="violet" icon="hero-bolt" />
          <.mini_stat label="Blocked" value={length(@payload.blocked)} tone="amber" icon="hero-pause-circle" />
          <.mini_stat label="Retrying" value={length(@payload.retrying)} tone="zinc" icon="hero-clock" />
        </div>

        <.card class="card-elevated overflow-hidden">
          <.card_header class="border-b border-border/60 bg-muted/20">
            <div class="flex items-start justify-between gap-3">
              <div>
                <.card_title class="text-[15px] font-semibold">All sessions</.card_title>
                <.card_description class="text-xs">
                  <%= total(@payload) %> tracked issue(s) · newest first
                </.card_description>
              </div>
              <.link
                navigate="/"
                class="inline-flex h-8 items-center rounded-full border border-border bg-card px-3 text-xs font-medium shadow-sm hover:bg-accent hover:text-accent-foreground"
              >
                Back to overview
              </.link>
            </div>
          </.card_header>
          <.card_content class="p-0">
            <%= if total(@payload) == 0 do %>
              <div class="p-6">
                <div class="flex flex-col items-center justify-center rounded-xl border border-dashed border-border/70 bg-muted/20 py-12 text-center">
                  <span class="flex h-10 w-10 items-center justify-center rounded-xl bg-muted text-muted-foreground">
                    <.icon name="hero-inbox" class="h-5 w-5" />
                  </span>
                  <p class="mt-3 text-sm font-medium">No sessions yet</p>
                  <p class="mt-1 max-w-sm text-sm leading-relaxed text-muted-foreground">
                    When the runtime starts tracking issues, they'll appear here with live state and harness info.
                  </p>
                </div>
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <.table>
                  <.table_header>
                    <.table_row class="hover:bg-transparent">
                      <.table_head class="text-[11px] uppercase tracking-wide">Issue</.table_head>
                      <.table_head class="text-[11px] uppercase tracking-wide">Status</.table_head>
                      <.table_head class="text-[11px] uppercase tracking-wide">State</.table_head>
                      <.table_head class="text-[11px] uppercase tracking-wide">Harness</.table_head>
                      <.table_head class="text-[11px] uppercase tracking-wide">Detail</.table_head>
                    </.table_row>
                  </.table_header>
                  <.table_body>
                    <.table_row
                      :for={row <- rows(@payload)}
                      class="group transition-colors hover:bg-muted/40"
                    >
                      <.table_cell>
                        <.link
                          navigate={"/sessions/#{row.identifier}"}
                          class="inline-flex items-center gap-1.5 font-semibold tracking-tight underline decoration-border underline-offset-4 hover:decoration-foreground"
                        >
                          <%= row.identifier %> <.icon
                            name="hero-arrow-top-right-on-square"
                            class="h-3.5 w-3.5 text-muted-foreground group-hover:text-foreground"
                          />
                        </.link>
                      </.table_cell>
                      <.table_cell><.status_badge status={row.status} /></.table_cell>
                      <.table_cell class="text-sm"><%= row.state || "—" %></.table_cell>
                      <.table_cell>
                        <span class="inline-flex rounded-full border border-border bg-card px-2.5 py-1 text-xs font-medium uppercase tracking-wide">
                          <%= row.harness || "codex" %>
                        </span>
                      </.table_cell>
                      <.table_cell class="max-w-[28rem] truncate text-sm text-muted-foreground">
                        <%= row.detail %>
                      </.table_cell>
                    </.table_row>
                  </.table_body>
                </.table>
              </div>
            <% end %>
          </.card_content>
        </.card>
      <% end %>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:tone, :string, default: "zinc")
  attr(:icon, :string, required: true)

  defp mini_stat(assigns) do
    ~H"""
    <.card class="card-elevated">
      <.card_content class="flex items-center justify-between gap-3 p-4">
        <div>
          <p class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground"><%= @label %></p>
          <p class="numeric mt-1 text-2xl font-semibold tracking-tight"><%= @value %></p>
        </div>
        <span class={[
          "flex h-9 w-9 items-center justify-center rounded-xl ring-1",
          @tone == "violet" && "bg-violet-500/10 text-violet-600 ring-violet-500/15 dark:text-violet-400",
          @tone == "amber" && "bg-amber-500/10 text-amber-600 ring-amber-500/15 dark:text-amber-400",
          @tone == "zinc" && "bg-muted text-muted-foreground ring-border"
        ]}>
          <.icon name={@icon} class="h-4 w-4" />
        </span>
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

  defp total(payload) do
    length(payload.running) + length(payload.blocked) + length(payload.retrying)
  end

  defp rows(payload) do
    running =
      Enum.map(payload.running, fn e ->
        %{
          identifier: e.issue_identifier,
          status: "running",
          state: e.state,
          harness: e.harness,
          detail: e.last_message || to_string(e.last_event || "n/a")
        }
      end)

    blocked =
      Enum.map(payload.blocked, fn e ->
        %{
          identifier: e.issue_identifier,
          status: "blocked",
          state: e.state || "Blocked",
          harness: e.harness,
          detail: e.error || e.last_message || "n/a"
        }
      end)

    retrying =
      Enum.map(payload.retrying, fn e ->
        %{
          identifier: e.issue_identifier,
          status: "retrying",
          state: "retry ##{e.attempt}",
          harness: nil,
          detail: e.error || "n/a"
        }
      end)

    running ++ blocked ++ retrying
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
