defmodule SymphonyElixir.ChildEnvironment do
  @moduledoc """
  Builds the explicit environment inherited by local and remote harness children.
  """

  @base ~w(HOME PATH LANG LC_ALL TERM TMPDIR SSL_CERT_FILE SSL_CERT_DIR SSH_AUTH_SOCK GIT_SSH_COMMAND)
  @codex @base ++ ~w(CODEX_HOME OMNIROUTE_BASE_URL OMNIROUTE_API_KEY SYMPHONY_MODEL)
  @prime @base
  @valid_name ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @spec effective(map(), :codex | :prime, [String.t()]) :: map()
  def effective(source \\ System.get_env(), profile, denied \\ []) when is_map(source) do
    allowed = profile |> allowed_names() |> Kernel.++(test_names(source)) |> MapSet.new()
    denied = denied |> valid_names() |> MapSet.new()

    source
    |> Enum.filter(fn {name, value} ->
      is_binary(value) and MapSet.member?(allowed, name) and not MapSet.member?(denied, name)
    end)
    |> Map.new()
  end

  @spec port_env(map(), :codex | :prime, [String.t()]) :: [{charlist(), charlist() | false}]
  def port_env(source \\ System.get_env(), profile, denied \\ []) when is_map(source) do
    kept = effective(source, profile, denied)

    source
    |> Map.keys()
    |> valid_names()
    |> Enum.reject(&Map.has_key?(kept, &1))
    |> Enum.sort()
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  @spec shell_command(map(), :codex | :prime, [String.t()]) :: String.t()
  def shell_command(source \\ System.get_env(), profile, denied \\ []) when is_map(source) do
    assignments =
      source
      |> effective(profile, denied)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(" ", fn {name, value} -> "#{name}=#{shell_escape(value)}" end)

    if assignments == "", do: "env -i", else: "env -i " <> assignments
  end

  defp allowed_names(:codex), do: @codex
  defp allowed_names(:prime), do: @prime

  defp valid_names(names) when is_list(names) do
    Enum.filter(names, &(is_binary(&1) and Regex.match?(@valid_name, &1)))
  end

  defp valid_names(_names), do: []

  defp test_names(source) do
    if Application.get_env(:symphony_elixir, :allow_test_child_environment, false) do
      source |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "SYMP_TEST_"))
    else
      []
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
