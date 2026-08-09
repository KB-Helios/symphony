defmodule SymphonyElixirWeb.CoreComponents do
  @moduledoc """
  Small set of app-specific function components that complement SaladUI.

  Only components that SaladUI does not already provide live here (flash
  messages and page headers) to avoid function-definition conflicts.
  """

  use Phoenix.Component
  use SaladUI

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages to display")
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup")
  attr(:rest, :global)

  @spec flash(map()) :: Phoenix.LiveView.Rendered.t()
  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role={if @kind == :error, do: "alert", else: "status"}
      class={[
        "pointer-events-auto w-full max-w-sm rounded-xl border p-4 shadow-lg backdrop-blur",
        @kind == :info &&
          "border-emerald-500/30 bg-emerald-50/90 text-emerald-900 dark:bg-emerald-950/80 dark:text-emerald-100",
        @kind == :error &&
          "border-red-500/30 bg-red-50/90 text-red-900 dark:bg-red-950/80 dark:text-red-100"
      ]}
      {@rest}
    >
      <p class="text-sm font-medium leading-relaxed">{msg}</p>
    </div>
    """
  end

  @doc """
  Renders a flash group for both info and error messages.
  """
  attr(:flash, :map, required: true)

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div class="pointer-events-none fixed inset-x-0 top-4 z-50 flex flex-col items-center gap-2 px-4">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders a page header with a title and optional subtitle and actions slot.
  """
  attr(:class, :any, default: nil)

  slot(:inner_block, required: true)
  slot(:subtitle)
  slot(:actions)

  @spec header(map()) :: Phoenix.LiveView.Rendered.t()
  def header(assigns) do
    ~H"""
    <header class={["flex flex-wrap items-start justify-between gap-4", @class]}>
      <div class="min-w-0">
        <h1 class="text-[20px] font-semibold tracking-tight text-foreground sm:text-[22px]">
          {render_slot(@inner_block)}
        </h1>
        <div :if={@subtitle != []} class="mt-1.5 max-w-2xl text-sm leading-relaxed text-muted-foreground">
          {render_slot(@subtitle)}
        </div>
      </div>
      <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  Renders a status badge for orchestration claim status (running, blocked, retrying).
  """
  attr(:status, :string, required: true)

  @spec status_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badge(assigns) do
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

  @doc """
  Renders a badge for a provider-native issue state (e.g. "In Progress",
  "Todo"). Distinct from `status_badge/1`, which renders orchestration claim
  status — tracker state spelling is preserved and categorized by keywords.
  """
  attr(:state, :string, required: true)

  @spec state_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def state_badge(assigns) do
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

  @doc """
  Renders a badge for the agent harness executing a session.
  """
  attr(:harness, :string, default: nil)

  @spec harness_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def harness_badge(assigns) do
    label = assigns.harness || "codex"
    variant = if label == "prime", do: "secondary", else: "outline"
    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.badge variant={@variant} class="rounded-full px-2.5 py-0.5 text-[11px] font-medium uppercase tracking-wide"><%= @label %></.badge>
    """
  end

  @doc """
  Renders a consistent empty state for tables, feeds, and lists.
  """
  attr(:icon, :string, default: "hero-inbox")
  attr(:title, :string, default: nil)
  attr(:message, :string, required: true)

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center rounded-xl border border-dashed border-border/70 bg-muted/20 py-10 text-center">
      <span class="flex h-10 w-10 items-center justify-center rounded-xl bg-muted text-muted-foreground">
        <.icon name={@icon} class="h-5 w-5" />
      </span>
      <p :if={@title} class="mt-3 text-sm font-medium"><%= @title %></p>
      <p class="mt-3 max-w-sm text-sm leading-relaxed text-muted-foreground"><%= @message %></p>
    </div>
    """
  end

  @doc """
  Renders a table header cell with the shared column-header styling.
  """
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  @spec th(map()) :: Phoenix.LiveView.Rendered.t()
  def th(assigns) do
    ~H"""
    <th
      scope="col"
      class={[
        "h-12 px-4 text-left align-middle font-medium text-muted-foreground text-[11px] uppercase tracking-wide",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </th>
    """
  end

  @pill_class "inline-flex items-center gap-1.5 rounded-full border border-border bg-card px-3 py-1.5 text-xs font-medium shadow-sm transition-colors hover:bg-accent hover:text-accent-foreground"

  @doc """
  Renders a pill-shaped navigation link in the shared outline style.
  """
  attr(:navigate, :string, default: nil)
  attr(:href, :string, default: nil)
  attr(:icon_left, :string, default: nil)
  attr(:icon_right, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  @spec pill_link(map()) :: Phoenix.LiveView.Rendered.t()
  def pill_link(assigns) do
    assigns = assign(assigns, :link_class, [@pill_class, assigns.class])

    ~H"""
    <.link navigate={@navigate} href={@href} class={@link_class} {@rest}>
      <.icon :if={@icon_left} name={@icon_left} class="h-3.5 w-3.5" />
      {render_slot(@inner_block)}
      <.icon :if={@icon_right} name={@icon_right} class="h-3.5 w-3.5" />
    </.link>
    """
  end

  @doc """
  Renders a pill-shaped action button in the shared outline style.
  """
  attr(:disabled, :boolean, default: false)
  attr(:icon_left, :string, default: nil)
  attr(:icon_right, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  @spec pill_button(map()) :: Phoenix.LiveView.Rendered.t()
  def pill_button(assigns) do
    assigns =
      assign(assigns, :button_class, [
        @pill_class,
        "disabled:pointer-events-none disabled:opacity-50",
        assigns.class
      ])

    ~H"""
    <button class={@button_class} disabled={@disabled} {@rest}>
      <.icon :if={@icon_left} name={@icon_left} class="h-3 w-3" />
      {render_slot(@inner_block)}
      <.icon :if={@icon_right} name={@icon_right} class="h-3 w-3" />
    </button>
    """
  end

  defp hide(js, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition: {"transition-all transform ease-in duration-200", "opacity-100 translate-y-0", "opacity-0 -translate-y-1"}
    )
  end
end
