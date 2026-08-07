defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec health(Conn.t(), map()) :: Conn.t()
  def health(conn, _params) do
    json(conn, %{status: "ok", version: app_version()})
  end

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec update_harness(Conn.t(), map()) :: Conn.t()
  def update_harness(conn, %{"harness" => harness}) do
    normalized = harness |> to_string() |> String.trim() |> String.downcase()

    if normalized in SymphonyElixir.Harness.supported_harnesses() do
      case update_workflow_harness(normalized) do
        :ok ->
          json(conn, %{harness: normalized, supported_harnesses: SymphonyElixir.Harness.supported_harnesses()})

        {:error, :invalid_harness} ->
          error_response(conn, 400, "invalid_harness", "harness must be one of: #{Enum.join(SymphonyElixir.Harness.supported_harnesses(), ", ")}")

        {:error, reason} ->
          error_response(conn, 500, "harness_update_failed", inspect(reason))
      end
    else
      error_response(conn, 400, "invalid_harness", "harness must be one of: #{Enum.join(SymphonyElixir.Harness.supported_harnesses(), ", ")}")
    end
  end

  def update_harness(conn, _params) do
    error_response(conn, 400, "invalid_harness", "missing harness parameter")
  end

  defp update_workflow_harness(kind) do
    SymphonyElixir.WorkflowStore.update_harness(kind)
  end

  defp app_version do
    case Application.spec(:symphony_elixir, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      _ -> "0.0.0"
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
