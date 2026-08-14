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
