defmodule SymphonyElixirWeb.BrowserFallbackController do
  @moduledoc "HTML fallback for unknown browser routes."

  use Phoenix.Controller, formats: [:html]

  alias Plug.Conn

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(html: SymphonyElixirWeb.BrowserFallbackHTML)
    |> render(:not_found, page_title: "Page not found")
  end
end
