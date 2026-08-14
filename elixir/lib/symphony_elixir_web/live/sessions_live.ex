defmodule SymphonyElixirWeb.SessionsLive do
  @moduledoc """
  Combined view of every tracked issue session: running, blocked, and retrying.
  """

  use SymphonyElixirWeb, :live_view

  alias SymphonyElixirWeb.{ObservabilityPubSub, Presenter}

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:current_path, "/sessions")
      |> assign(:tab, :all)
      |> assign(:sort_by, :identifier)
      |> assign(:sort_dir, :asc)
      |> assign(:page, 1)
      |> assign(:q, "")
      |> assign(:per_page, @per_page)
      |> assign(:page_title, "Sessions")

    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload, load_payload())}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: parse_tab(tab), page: 1)}
  end

  def handle_event("switch_tab", _params, socket), do: {:noreply, socket}

  def handle_event("search", %{"q" => q}, socket) do
    q = q |> to_string() |> String.trim() |> String.slice(0, 120)
    {:noreply, assign(socket, q: q, page: 1)}
  end

  def handle_event("search", _params, socket), do: {:noreply, socket}

  def handle_event("sort", %{"sort" => sort}, socket) do
    sort_by = parse_sort(sort)
    current_by = socket.assigns.sort_by
    current_dir = socket.assigns.sort_dir

    {new_by, new_dir} =
      if sort_by == current_by do
        {current_by, if(current_dir == :asc, do: :desc, else: :asc)}
      else
        {sort_by, :asc}
      end

    {:noreply, assign(socket, sort_by: new_by, sort_dir: new_dir)}
  end

  def handle_event("sort", _params, socket), do: {:noreply, socket}

  def handle_event("paginate", %{"page" => page}, socket) do
    page_int =
      case Integer.parse(to_string(page)) do
        {n, _} -> max(n, 1)
        :error -> socket.assigns.page
      end

    {:noreply, assign(socket, :page, page_int)}
  end

  def handle_event("paginate", _params, socket), do: {:noreply, socket}

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
            <%= if is_nil(@payload), do: "—", else: total(@payload) %> tracked
          </span>
        </:actions>
      </.header>

      <%= if is_nil(@payload) do %>
        <div role="status" aria-busy="true" aria-label="Loading sessions" class="space-y-3">
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
          <div class="grid gap-3 sm:grid-cols-3">
          <.mini_stat label="Running" value={length(@payload.running)} tone="violet" icon="hero-bolt" />
          <.mini_stat label="Blocked" value={length(@payload.blocked)} tone="rose" icon="hero-pause-circle" />
          <.mini_stat label="Retrying" value={length(@payload.retrying)} tone="amber" icon="hero-clock" />
        </div>

        <.card class="card-elevated overflow-hidden">
          <.card_header class="border-b border-border/60 bg-muted/20">
            <div class="flex items-start justify-between gap-3">
              <div>
                <.card_title class="text-[15px] font-semibold">All sessions</.card_title>
                <.card_description class="text-xs">
                  <%= total(@payload) %> tracked issue(s) · grouped by status
                </.card_description>
              </div>
              <.pill_link navigate="/" icon_left="hero-arrow-left">Back to overview</.pill_link>
            </div>
          </.card_header>

          <div class="flex flex-col gap-3 border-b border-border/60 p-3 sm:flex-row sm:items-center sm:justify-between">
            <form phx-change="search" class="flex min-w-[220px] max-w-sm flex-1 items-center gap-2">
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
                  aria-label="Filter sessions by issue identifier"
                  class="flex h-9 w-full rounded-xl border border-input bg-background py-2 pl-9 pr-3 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
                />
              </div>
            </form>

            <div role="tablist" aria-label="Filter sessions by status" class="flex flex-wrap items-center gap-1.5">
              <.tab_button tab={@tab} value={:all} count={total(@payload)} icon="hero-squares-2x2" label="All" />
              <.tab_button
                tab={@tab}
                value={:running}
                count={length(@payload.running)}
                icon="hero-bolt"
                label="Running"
              />
              <.tab_button
                tab={@tab}
                value={:blocked}
                count={length(@payload.blocked)}
                icon="hero-pause-circle"
                label="Blocked"
              />
              <.tab_button
                tab={@tab}
                value={:retrying}
                count={length(@payload.retrying)}
                icon="hero-clock"
                label="Retrying"
              />
            </div>
          </div>

          <.card_content
            class="p-0"
            role="tabpanel"
            id="sessions-panel"
            aria-labelledby={"sessions-tab-#{@tab}"}
          >
            <%= if total(@payload) == 0 do %>
              <div class="p-6">
                <.empty_state
                  title="No sessions yet"
                  message="When the runtime starts tracking issues, they'll appear here with live state and harness info."
                />
              </div>
            <% else %>
              <% filtered = filtered_rows(@payload, @tab, @q) %>
              <% sorted = sorted_rows(filtered, @sort_by, @sort_dir) %>
              <% total_filtered = length(sorted) %>
              <% total_pages = total_pages(total_filtered, @per_page) %>
              <% current_page = clamp_page(@page, total_pages) %>
              <% paginated = paginated_rows(sorted, current_page, @per_page) %>
              <%= if total_filtered == 0 do %>
                <div class="p-6">
                  <.empty_state
                    icon="hero-magnifying-glass"
                    title="No matches"
                    message="No sessions match the current tab or search filter."
                  />
                </div>
              <% else %>
                <div id="sessions-desktop" class="hidden overflow-x-auto md:block">
                  <.table aria-busy="false">
                      <.table_caption class="sr-only">Sessions table</.table_caption>
                    <.table_header>
                      <.table_row class="hover:bg-transparent">
                        <.th aria-sort={aria_sort(@sort_by, @sort_dir, :identifier)}>
                          <button
                            phx-click="sort"
                            phx-value-sort="identifier"
                            class="inline-flex items-center gap-1 font-medium hover:text-foreground"
                          >
                            Issue <.icon name={sort_icon(@sort_by, @sort_dir, :identifier)} class="h-3 w-3" />
                          </button>
                        </.th>
                        <.th aria-sort={aria_sort(@sort_by, @sort_dir, :status)}>
                          <button
                            phx-click="sort"
                            phx-value-sort="status"
                            class="inline-flex items-center gap-1 font-medium hover:text-foreground"
                          >
                            Status <.icon name={sort_icon(@sort_by, @sort_dir, :status)} class="h-3 w-3" />
                          </button>
                        </.th>
                        <.th aria-sort={aria_sort(@sort_by, @sort_dir, :state)}>
                          <button
                            phx-click="sort"
                            phx-value-sort="state"
                            class="inline-flex items-center gap-1 font-medium hover:text-foreground"
                          >
                            State <.icon name={sort_icon(@sort_by, @sort_dir, :state)} class="h-3 w-3" />
                          </button>
                        </.th>
                        <.th>Harness</.th>
                        <.th>Host</.th>
                        <.th>Detail</.th>
                      </.table_row>
                    </.table_header>
                    <.table_body>
                      <.table_row
                        :for={row <- paginated}
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
                          <%= if row.harness do %>
                            <.harness_badge harness={row.harness} />
                          <% else %>
                            <span class="text-xs text-muted-foreground">—</span>
                          <% end %>
                        </.table_cell>
                        <.table_cell>
                          <span class="mono inline-flex rounded-full border border-border bg-muted/40 px-2.5 py-1 text-xs font-medium">
                            <%= row.worker_host || "local" %>
                          </span>
                        </.table_cell>
                        <.table_cell class="max-w-[28rem] truncate text-sm text-muted-foreground">
                          <%= row.detail %>
                        </.table_cell>
                      </.table_row>
                    </.table_body>
                  </.table>
                </div>

                <div id="sessions-mobile" class="divide-y divide-border/60 md:hidden">
                  <article :for={row <- paginated} class="space-y-3 p-4">
                    <div class="flex items-start justify-between gap-3">
                      <.link navigate={~p"/sessions/#{row.identifier}"} class="font-semibold tracking-tight">
                        <%= row.identifier %>
                      </.link>
                      <.status_badge status={row.status} />
                    </div>
                    <dl class="grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
                      <div>
                        <dt class="text-xs text-muted-foreground">State</dt>
                        <dd class="mt-1"><%= row.state || "—" %></dd>
                      </div>
                      <div>
                        <dt class="text-xs text-muted-foreground">Harness</dt>
                        <dd class="mt-1"><%= row.harness || "—" %></dd>
                      </div>
                      <div>
                        <dt class="text-xs text-muted-foreground">Host</dt>
                        <dd class="mono mt-1 text-xs"><%= row.worker_host || "local" %></dd>
                      </div>
                      <div class="col-span-2">
                        <dt class="text-xs text-muted-foreground">Latest activity</dt>
                        <dd class="mt-1 break-words text-muted-foreground"><%= row.detail %></dd>
                      </div>
                    </dl>
                  </article>
                </div>

                <div class="flex flex-col gap-3 border-t border-border/60 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
                  <span class="text-xs text-muted-foreground">
                    Showing <%= showing_range(current_page, @per_page, total_filtered) %> of <%= total_filtered %>
                  </span>
                  <div class="flex items-center gap-2">
                    <.pill_button
                      aria-label="Previous page"
                      phx-click="paginate"
                      phx-value-page={current_page - 1}
                      disabled={current_page <= 1}
                      icon_left="hero-chevron-left"
                    >
                      Prev
                    </.pill_button>
                    <span class="mono text-xs text-muted-foreground">Page <%= current_page %> / <%= total_pages %></span>
                    <.pill_button
                      aria-label="Next page"
                      phx-click="paginate"
                      phx-value-page={current_page + 1}
                      disabled={current_page >= total_pages}
                      icon_right="hero-chevron-right"
                    >
                      Next
                    </.pill_button>
                  </div>
                </div>
              <% end %>
            <% end %>
          </.card_content>
        </.card>
        <% end %>
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
      <.card_content role="status" aria-live="polite" aria-atomic="true" class="flex items-center justify-between gap-3 p-4">
        <div>
          <p class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground"><%= @label %></p>
          <p class="numeric mt-1 text-2xl font-semibold tracking-tight"><%= @value %></p>
        </div>
        <span class={[
          "flex h-9 w-9 items-center justify-center rounded-xl ring-1",
          @tone == "violet" && "bg-violet-500/10 text-violet-600 ring-violet-500/15 dark:text-violet-400",
          @tone == "amber" && "bg-amber-500/10 text-amber-600 ring-amber-500/15 dark:text-amber-400",
          @tone == "rose" && "bg-rose-500/10 text-rose-600 ring-rose-500/15 dark:text-rose-400",
          @tone == "zinc" && "bg-muted text-muted-foreground ring-border"
        ]}>
          <.icon name={@icon} class="h-4 w-4" />
        </span>
      </.card_content>
    </.card>
    """
  end

  attr(:tab, :atom, required: true)
  attr(:value, :atom, required: true)
  attr(:count, :integer, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)

  defp tab_button(assigns) do
    ~H"""
    <button
      id={"sessions-tab-#{@value}"}
      role="tab"
      aria-selected={to_string(@tab == @value)}
      aria-controls="sessions-panel"
      phx-click="switch_tab"
      phx-value-tab={@value}
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-medium transition-colors",
        @tab == @value && "bg-accent text-accent-foreground shadow-sm",
        @tab != @value && "text-muted-foreground hover:bg-muted hover:text-foreground"
      ]}
    >
      <.icon name={@icon} class="h-3.5 w-3.5" />
      <%= @label %> <span class="mono text-[11px]">(<%= @count %>)</span>
    </button>
    """
  end

  defp total(payload) do
    running = Map.get(payload, :running, [])
    blocked = Map.get(payload, :blocked, [])
    retrying = Map.get(payload, :retrying, [])
    length(running) + length(blocked) + length(retrying)
  end

  defp rows(payload) do
    running =
      Enum.map(Map.get(payload, :running, []), fn e ->
        %{
          identifier: e.issue_identifier,
          status: "running",
          state: e.state,
          harness: e.harness,
          worker_host: Map.get(e, :worker_host),
          detail: e.last_message || to_string(e.last_event || "n/a")
        }
      end)

    blocked =
      Enum.map(Map.get(payload, :blocked, []), fn e ->
        %{
          identifier: e.issue_identifier,
          status: "blocked",
          state: e.state || "Blocked",
          harness: e.harness,
          worker_host: Map.get(e, :worker_host),
          detail: e.error || e.last_message || "n/a"
        }
      end)

    retrying =
      Enum.map(Map.get(payload, :retrying, []), fn e ->
        %{
          identifier: e.issue_identifier,
          status: "retrying",
          state: "retry ##{e.attempt}",
          harness: nil,
          worker_host: Map.get(e, :worker_host),
          detail: e.error || "n/a"
        }
      end)

    running ++ blocked ++ retrying
  end

  defp filtered_rows(payload, tab, q) do
    rows(payload)
    |> filter_by_tab(tab)
    |> filter_by_search(q)
  end

  defp filter_by_tab(rows, :all), do: rows

  defp filter_by_tab(rows, tab) when tab in [:running, :blocked, :retrying] do
    tab_str = Atom.to_string(tab)
    Enum.filter(rows, &(&1.status == tab_str))
  end

  defp filter_by_tab(rows, _tab), do: rows

  defp filter_by_search(rows, q) when q == "" or is_nil(q), do: rows

  defp filter_by_search(rows, q) when is_binary(q) do
    q_down = String.downcase(q)
    Enum.filter(rows, fn row -> String.contains?(String.downcase(row.identifier), q_down) end)
  end

  defp sorted_rows(rows, sort_by, sort_dir) do
    Enum.sort_by(
      rows,
      fn row ->
        case sort_by do
          :identifier -> String.downcase(to_string(row.identifier))
          :status -> row.status
          :state -> String.downcase(to_string(row.state || ""))
          _ -> String.downcase(to_string(row.identifier))
        end
      end,
      sort_dir
    )
  end

  defp paginated_rows(rows, page, per_page) do
    start = (page - 1) * per_page
    Enum.slice(rows, start, per_page)
  end

  defp total_pages(total, _per_page) when total <= 0, do: 1

  defp total_pages(total, per_page) do
    div(total + per_page - 1, per_page)
  end

  defp clamp_page(page, total_pages) do
    page |> max(1) |> min(total_pages)
  end

  defp showing_range(_page, _per_page, total) when total == 0, do: "0–0"

  defp showing_range(page, per_page, total) do
    start_idx = (page - 1) * per_page + 1
    end_idx = min(page * per_page, total)
    "#{start_idx}–#{end_idx}"
  end

  defp sort_icon(current_by, current_dir, column) when current_by == column do
    if current_dir == :asc, do: "hero-chevron-up", else: "hero-chevron-down"
  end

  defp sort_icon(_current_by, _current_dir, _column), do: "hero-chevron-up-down"

  defp aria_sort(current_by, current_dir, column) when current_by == column do
    if current_dir == :asc, do: "ascending", else: "descending"
  end

  defp aria_sort(_current_by, _current_dir, _column), do: "none"

  defp parse_tab(tab) when is_binary(tab) do
    case String.downcase(String.trim(tab)) do
      "running" -> :running
      "blocked" -> :blocked
      "retrying" -> :retrying
      _ -> :all
    end
  end

  defp parse_tab(tab) when is_atom(tab) and tab in [:all, :running, :blocked, :retrying], do: tab
  defp parse_tab(_), do: :all

  defp parse_sort(sort) when is_binary(sort) do
    case String.downcase(String.trim(sort)) do
      "status" -> :status
      "state" -> :state
      "identifier" -> :identifier
      "issue" -> :identifier
      _ -> :identifier
    end
  end

  defp parse_sort(sort) when is_atom(sort) and sort in [:identifier, :status, :state], do: sort
  defp parse_sort(_), do: :identifier

  defp load_payload do
    Presenter.state_payload(SymphonyElixirWeb.orchestrator(), SymphonyElixirWeb.snapshot_timeout_ms())
  end
end
