defmodule SymphonyElixir.ModelRouterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ModelRouter

  test "accepts the configured alias from the private model catalog" do
    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer router-secret"]
      assert conn.request_path == "/v1/models"
      Req.Test.json(conn, %{"data" => [%{"id" => "kimi-k3"}]})
    end

    assert :ok =
             ModelRouter.check(
               base_url: "https://router.example/v1",
               api_key: "router-secret",
               model: "kimi-k3",
               plug: plug
             )
  end

  test "returns stable errors without credentials or a selected alias" do
    assert {:error, :missing_router_api_key} =
             ModelRouter.check(base_url: "https://router.example/v1", api_key: nil, model: "kimi-k3")

    assert {:error, :model_alias_unavailable} =
             ModelRouter.check(
               base_url: "https://router.example/v1",
               api_key: "secret",
               model: "other-model",
               plug: fn conn -> Req.Test.json(conn, %{"data" => [%{"id" => "kimi-k3"}]}) end
             )
  end
end
