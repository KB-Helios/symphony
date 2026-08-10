defmodule SymphonyElixirWeb.ErrorJSON do
  @moduledoc false

  @spec render(String.t(), map()) :: map()
  def render(template, _assigns) do
    code = if String.starts_with?(template, "5"), do: "internal_server_error", else: "not_found"
    %{error: %{code: code, message: Phoenix.Controller.status_message_from_template(template)}}
  end
end
