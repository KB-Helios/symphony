defmodule SymphonyElixir.StateStore do
  @moduledoc """
  Atomically persists the durable runtime snapshot.
  """

  alias SymphonyElixir.RuntimeState

  @spec load(Path.t()) :: {:ok, map() | nil} | {:error, atom()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, json} -> decode(json)
      {:error, :enoent} -> {:ok, nil}
      {:error, _reason} -> {:error, :state_read_failed}
    end
  end

  @spec save(Path.t(), map()) :: :ok | {:error, atom()}
  def save(path, snapshot) when is_binary(path) and is_map(snapshot) do
    with {:ok, validated} <- RuntimeState.validate(snapshot),
         {:ok, json} <- encode(validated),
         :ok <- atomic_write(path, json) do
      :ok
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, snapshot} -> RuntimeState.validate(snapshot)
      {:error, _reason} -> {:error, :state_invalid_json}
    end
  end

  defp encode(snapshot) do
    case Jason.encode(snapshot) do
      {:ok, json} -> {:ok, json <> "\n"}
      {:error, _reason} -> {:error, :state_encode_failed}
    end
  rescue
    _error -> {:error, :state_encode_failed}
  end

  defp atomic_write(path, contents) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.mkdir_p(directory),
         {:ok, file} <- :file.open(String.to_charlist(temporary), [:write, :binary, :exclusive]),
         :ok <- write_sync_close(file, contents),
         :ok <- File.rename(temporary, path) do
      sync_directory(directory)
      :ok
    else
      {:error, _reason} ->
        File.rm(temporary)
        {:error, :state_write_failed}
    end
  end

  defp write_sync_close(file, contents) do
    result =
      with :ok <- :file.write(file, contents),
           :ok <- :file.sync(file) do
        :ok
      end

    close_result = :file.close(file)

    case {result, close_result} do
      {:ok, :ok} -> :ok
      _ -> {:error, :write_or_sync_failed}
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :raw]) do
      {:ok, file} ->
        _ = :file.sync(file)
        _ = :file.close(file)
        :ok

      {:error, _unsupported} ->
        :ok
    end
  end
end
