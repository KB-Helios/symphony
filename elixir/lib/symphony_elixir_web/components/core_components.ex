defmodule SymphonyElixirWeb.CoreComponents do
  @moduledoc """
  Small set of app-specific function components that complement SaladUI.

  Only components that SaladUI does not already provide live here (flash
  messages and page headers) to avoid function-definition conflicts.
  """

  use Phoenix.Component

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
      role="alert"
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
  Renders a status badge for session status (running, blocked, retrying).
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

  defp hide(js, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition: {"transition-all transform ease-in duration-200", "opacity-100 translate-y-0", "opacity-0 -translate-y-1"}
    )
  end
end
