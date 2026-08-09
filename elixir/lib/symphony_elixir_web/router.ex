defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/sessions", SessionsLive, :index)
    live("/sessions/:identifier", IssueDetailLive, :show)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/health", ObservabilityApiController, :health)
    match(:*, "/api/v1/health", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/state", ObservabilityApiController, :state)
    post("/api/v1/harness", ObservabilityApiController, :update_harness)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/harness", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
