defmodule SymphonyElixir.ModelRouter do
  @moduledoc """
  Performs the cheap model-catalog readiness check for the configured private router.
  """

  @spec check(keyword()) :: :ok | {:error, atom()}
  def check(opts \\ []) do
    base_url = Keyword.get(opts, :base_url, System.get_env("OMNIROUTE_BASE_URL"))
    api_key = Keyword.get(opts, :api_key, System.get_env("OMNIROUTE_API_KEY"))
    model = Keyword.get(opts, :model, System.get_env("SYMPHONY_MODEL"))

    with {:ok, base_url} <- validate_base_url(base_url),
         {:ok, api_key} <- require_value(api_key, :missing_router_api_key),
         {:ok, model} <- require_value(model, :missing_model_alias),
         {:ok, response} <- request_models(base_url, api_key, opts),
         :ok <- validate_response(response, model) do
      :ok
    end
  end

  defp validate_base_url(value) when is_binary(value) do
    value = String.trim(value)

    if String.starts_with?(value, "https://") and String.ends_with?(value, "/v1") do
      {:ok, value}
    else
      {:error, :invalid_router_base_url}
    end
  end

  defp validate_base_url(_value), do: {:error, :missing_router_base_url}

  defp require_value(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp require_value(_value, error), do: {:error, error}

  defp request_models(base_url, api_key, opts) do
    request_opts = [
      url: base_url <> "/models",
      auth: {:bearer, api_key},
      receive_timeout: Keyword.get(opts, :receive_timeout, 15_000),
      retry: false
    ]

    request_opts =
      case Keyword.fetch(opts, :plug) do
        {:ok, plug} -> Keyword.put(request_opts, :plug, plug)
        :error -> request_opts
      end

    case Req.get(request_opts) do
      {:ok, response} -> {:ok, response}
      {:error, _reason} -> {:error, :router_unreachable}
    end
  end

  defp validate_response(%Req.Response{status: 200, body: %{"data" => models}}, model)
       when is_list(models) do
    if Enum.any?(models, &(is_map(&1) and Map.get(&1, "id") == model)) do
      :ok
    else
      {:error, :model_alias_unavailable}
    end
  end

  defp validate_response(%Req.Response{status: status}, _model) when status in [401, 403],
    do: {:error, :router_auth_failed}

  defp validate_response(%Req.Response{}, _model), do: {:error, :router_unreachable}
  defp validate_response(_response, _model), do: {:error, :router_unreachable}
end
