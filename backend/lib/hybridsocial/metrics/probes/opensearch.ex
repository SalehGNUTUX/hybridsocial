defmodule Hybridsocial.Metrics.Probes.Opensearch do
  @moduledoc """
  Skipped entirely on instances that run the Postgres-backed search
  (most single-host deploys), so we don't fill the metrics table with
  rows of zeros that would compress the y-axis on every other graph.
  """

  alias Hybridsocial.Config

  def sample do
    case Config.get("search_backend", "postgresql") do
      "opensearch" -> probe()
      _ -> {:skip, "search_backend != opensearch"}
    end
  end

  defp probe do
    url = Application.get_env(:hybridsocial, :opensearch_url, "http://localhost:9200")

    try do
      with {:ok, health} <- fetch_json("#{url}/_cluster/health"),
           {:ok, indices} <-
             fetch_json("#{url}/_cat/indices?format=json&h=index,docs.count,store.size") do
        cluster_status =
          case health["status"] do
            "green" -> 0
            "yellow" -> 1
            "red" -> 2
            _ -> 2
          end

        total_docs =
          indices
          |> Enum.map(&parse_int_field(&1, "docs.count"))
          |> Enum.sum()

        index_size =
          indices
          |> Enum.map(&parse_size_field(&1, "store.size"))
          |> Enum.sum()

        samples = [
          {"cluster_status", cluster_status, :gauge},
          {"index_count", length(indices), :gauge},
          {"total_docs", total_docs, :gauge},
          {"index_size_bytes", index_size, :gauge},
          {"unassigned_shards", get_int(health, "unassigned_shards"), :gauge}
        ]

        {:ok, samples}
      else
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp fetch_json(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 3000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(IO.iodata_to_binary(body)) do
          {:ok, json} -> {:ok, json}
          _ -> {:error, "invalid json"}
        end

      _ ->
        {:error, "opensearch unreachable"}
    end
  end

  defp parse_int_field(row, key) do
    case Map.get(row, key) do
      n when is_binary(n) ->
        case Integer.parse(n) do
          {v, _} -> v
          :error -> 0
        end

      n when is_integer(n) ->
        n

      _ ->
        0
    end
  end

  defp parse_size_field(row, key) do
    # _cat returns sizes like "12.4mb"; convert to bytes.
    case Map.get(row, key) do
      nil ->
        0

      val when is_binary(val) ->
        s = String.downcase(val)

        cond do
          String.ends_with?(s, "kb") -> parse_float_prefix(s, "kb") * 1024
          String.ends_with?(s, "mb") -> parse_float_prefix(s, "mb") * 1024 * 1024
          String.ends_with?(s, "gb") -> parse_float_prefix(s, "gb") * 1024 * 1024 * 1024
          String.ends_with?(s, "tb") -> parse_float_prefix(s, "tb") * 1024 * 1024 * 1024 * 1024
          String.ends_with?(s, "b") -> parse_float_prefix(s, "b")
          true -> 0
        end
    end
  end

  defp parse_float_prefix(s, suffix) do
    s
    |> String.replace_trailing(suffix, "")
    |> Float.parse()
    |> case do
      {n, _} -> trunc(n)
      :error -> 0
    end
  end

  defp get_int(map, key) when is_map(map) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      _ -> 0
    end
  end
end
