defmodule SymphonyElixirWeb do
  @moduledoc """
  Web layer entrypoint for Symphony's observability UI.

  Provides the `html/0` helper used by LiveViews and function components so
  SaladUI components, Phoenix.HTML, and verified routes are available in a
  single place.
  """

  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets fonts images favicon.png)

  @spec router() :: Macro.t()
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @spec live_view() :: Macro.t()
  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {SymphonyElixirWeb.Layouts, :app}

      unquote(html_helpers())
    end
  end

  @spec live_component() :: Macro.t()
  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  @spec component() :: Macro.t()
  def component do
    quote do
      use Phoenix.Component

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.LiveView.Helpers

      # SaladUI component library (button, card, table, badge, dialog, ...)
      use SaladUI

      import SymphonyElixirWeb.CoreComponents

      unquote(verified_routes())
    end
  end

  @spec verified_routes() :: Macro.t()
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: SymphonyElixirWeb.Endpoint,
        router: SymphonyElixirWeb.Router,
        statics: SymphonyElixirWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
