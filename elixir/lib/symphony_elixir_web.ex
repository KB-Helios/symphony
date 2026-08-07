defmodule SymphonyElixirWeb do
  

  
  @doc """
Returns the static asset directories and files served by the web layer.
"""
@spec static_paths() :: [String.t()]
def static_paths, do: ~w(assets fonts images favicon.png)

  @doc """
  Provides the shared setup for Phoenix routers.
  """
  @spec router() :: Macro.t()
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @doc """
  Returns the quoted setup for Phoenix LiveView modules, including the application layout and shared HTML helpers.
  """
  @spec live_view() :: Macro.t()
  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {SymphonyElixirWeb.Layouts, :app}

      unquote(html_helpers())
    end
  end

  @doc """
  Configures a Phoenix LiveComponent with shared HTML helpers.
  """
  @spec live_component() :: Macro.t()
  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  @doc """
  Configures a Phoenix function component with shared HTML helpers.
  
  @returns Quoted setup code for a Phoenix function component.
  """
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

  @doc """
  Configures Phoenix verified routes for the application endpoint, router, and static assets.
  """
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

  
  
  @doc """
  Provides the configured orchestrator module.
  
  Returns the configured module, or `SymphonyElixir.Orchestrator` when no module is configured.
  """
  @spec orchestrator() :: module()
  def orchestrator do
    SymphonyElixirWeb.Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  
  
  @doc """
  Provides the configured snapshot timeout in milliseconds.
  
  Uses 15,000 milliseconds when no timeout is configured.
  
  """
  @spec snapshot_timeout_ms() :: non_neg_integer()
  def snapshot_timeout_ms do
    SymphonyElixirWeb.Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
