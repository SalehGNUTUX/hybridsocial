defmodule Hybridsocial.Federation.DeliveryStats do
  @moduledoc """
  Read-only metrics over the `federation_deliveries` table for the
  admin Delivery Queue tab. Three buckets:

  1. `queue/0` — current snapshot: pending / retrying / failed-24h /
     oldest pending age. The four numbers an admin checks first.
  2. `throughput/0` — per-minute series for the last hour, broken down
     by activity type. Counts deliveries that *resolved* (delivered or
     failed) so the chart shows real outbound rate, not new-row rate.
  3. `top_failing_destinations/1` — domains with the most failed or
     retrying deliveries in the last 24h, with their last error
     message. Most useful single diagnostic when federation breaks.
  """

  import Ecto.Query
  alias Hybridsocial.Repo

  @doc """
  Returns the current queue snapshot.
  """
  def queue do
    now = DateTime.utc_now()
    cutoff_24h = DateTime.add(now, -24 * 3600, :second)

    pending_count = count_by_status("pending")
    retrying_count = count_by_status("retrying")

    failed_24h_count =
      Repo.one(
        from d in "federation_deliveries",
          where: d.status == "failed" and d.last_attempt_at >= ^cutoff_24h,
          select: count(d.id)
      ) || 0

    delivered_24h_count =
      Repo.one(
        from d in "federation_deliveries",
          where: d.status == "delivered" and d.last_attempt_at >= ^cutoff_24h,
          select: count(d.id)
      ) || 0

    oldest_pending =
      Repo.one(
        from d in "federation_deliveries",
          where: d.status in ["pending", "retrying"],
          select: min(d.inserted_at)
      )

    oldest_age_seconds =
      case oldest_pending do
        nil -> 0
        ts -> DateTime.diff(now, ts, :second)
      end

    %{
      pending: pending_count,
      retrying: retrying_count,
      failed_24h: failed_24h_count,
      delivered_24h: delivered_24h_count,
      oldest_pending_age_seconds: oldest_age_seconds
    }
  end

  defp count_by_status(status) do
    Repo.one(
      from d in "federation_deliveries",
        where: d.status == ^status,
        select: count(d.id)
    ) || 0
  end

  @doc """
  Per-minute throughput for the last hour, broken down by activity type.

  Returns:
      %{
        buckets: [%{t: ~U[..], total: 12, by_type: %{"Create" => 8, ...}}, ...],
        totals_by_type: %{"Create" => 240, "Like" => 60, ...}
      }
  """
  def throughput do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -3600, :second)

    rows =
      Repo.all(
        from d in "federation_deliveries",
          where:
            d.status in ["delivered", "failed"] and
              d.last_attempt_at >= ^cutoff,
          group_by:
            fragment(
              "date_bin('1 minute'::interval, ?, TIMESTAMP '2001-01-01')",
              d.last_attempt_at
            ),
          group_by: d.activity_type,
          order_by:
            fragment(
              "date_bin('1 minute'::interval, ?, TIMESTAMP '2001-01-01')",
              d.last_attempt_at
            ),
          select: %{
            t:
              fragment(
                "date_bin('1 minute'::interval, ?, TIMESTAMP '2001-01-01')",
                d.last_attempt_at
              ),
            type: d.activity_type,
            count: count(d.id)
          }
      )

    # `date_bin` returns a `timestamp` (no tz), which Ecto hands back as
    # a NaiveDateTime — promote to UTC DateTime so Phoenix's JSON
    # encoder emits a `Z` suffix the browser can parse correctly, and
    # the sort comparator below has the right struct type.
    grouped =
      Enum.reduce(rows, %{}, fn %{t: t, type: type, count: count}, acc ->
        bucket_ts = naive_to_utc(t)
        type_label = type || "Other"

        Map.update(
          acc,
          bucket_ts,
          %{type_label => count},
          fn existing -> Map.update(existing, type_label, count, &(&1 + count)) end
        )
      end)

    buckets =
      grouped
      |> Enum.map(fn {t, by_type} ->
        %{t: t, total: by_type |> Map.values() |> Enum.sum(), by_type: by_type}
      end)
      |> Enum.sort_by(& &1.t, DateTime)

    totals_by_type =
      Enum.reduce(buckets, %{}, fn %{by_type: by_type}, acc ->
        Map.merge(acc, by_type, fn _k, a, b -> a + b end)
      end)

    %{buckets: buckets, totals_by_type: totals_by_type}
  end

  @doc """
  Top N domains with the most failed/retrying deliveries in the last
  24h, with the most recent error message and last attempt timestamp.
  """
  def top_failing_destinations(limit \\ 10) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -24 * 3600, :second)

    # Per-domain failure aggregation. We pull the raw rows and group in
    # Elixir because Postgres can't easily extract host from a text URL
    # and aggregate "latest error per domain" in a single SQL pass.
    rows =
      Repo.all(
        from d in "federation_deliveries",
          where:
            d.status in ["failed", "retrying"] and
              d.last_attempt_at >= ^cutoff,
          select: %{
            target_inbox: d.target_inbox,
            error: d.error,
            last_attempt_at: d.last_attempt_at,
            attempts: d.attempts
          }
      )

    rows
    |> Enum.group_by(&domain_of/1)
    |> Enum.map(fn {domain, group} ->
      # Some rows in older deploys ended up with naive timestamps in
      # last_attempt_at (the column is utc_datetime_usec but the
      # update path historically used DateTime.utc_now without
      # explicit truncation, and Ecto can hand back NaiveDateTime in
      # mixed states). Normalize before sorting to keep the
      # comparator on a consistent struct, and before returning so
      # JSON gets a UTC-suffixed value.
      normalized =
        Enum.map(group, fn row ->
          %{row | last_attempt_at: naive_to_utc(row.last_attempt_at)}
        end)

      sorted =
        Enum.sort_by(
          normalized,
          fn r -> r.last_attempt_at end,
          fn a, b ->
            cond do
              is_nil(a) -> false
              is_nil(b) -> true
              true -> DateTime.compare(a, b) != :lt
            end
          end
        )

      latest = List.first(sorted)

      %{
        domain: domain,
        failures: length(normalized),
        last_error: latest && latest.error,
        last_attempt_at: latest && latest.last_attempt_at,
        max_attempts: normalized |> Enum.map(& &1.attempts) |> Enum.max(fn -> 0 end)
      }
    end)
    |> Enum.reject(&is_nil(&1.domain))
    |> Enum.sort_by(& &1.failures, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Per-peer delivery latency over the last hour. Computes p50 and p95
  request duration in milliseconds for the top N domains by sample
  count. Useful for spotting a slow peer that's dragging the queue.

  Only delivered rows are sampled — failed rows often time out at
  the 15s ceiling, which would skew the percentiles toward the
  retry budget rather than the real distribution. Requires at least
  three samples per domain so a single outlier isn't reported as a
  trend.
  """
  def latency_per_peer(limit \\ 10) do
    cutoff = DateTime.utc_now() |> DateTime.add(-3600, :second)

    rows =
      Repo.all(
        from d in "federation_deliveries",
          where:
            d.status == "delivered" and
              not is_nil(d.duration_ms) and
              d.last_attempt_at >= ^cutoff,
          group_by: fragment("split_part(split_part(?, '/', 3), ':', 1)", d.target_inbox),
          having: count(d.id) >= 3,
          order_by: [desc: count(d.id)],
          limit: ^limit,
          select: %{
            domain: fragment("split_part(split_part(?, '/', 3), ':', 1)", d.target_inbox),
            samples: count(d.id),
            p50_ms: fragment("percentile_cont(0.5) within group (order by ?)", d.duration_ms),
            p95_ms: fragment("percentile_cont(0.95) within group (order by ?)", d.duration_ms),
            max_ms: max(d.duration_ms)
          }
      )

    Enum.map(rows, fn row ->
      %{
        domain: row.domain,
        samples: row.samples,
        # `percentile_cont` returns float; round so the dashboard
        # doesn't render "12.3333333 ms".
        p50_ms: round_or_nil(row.p50_ms),
        p95_ms: round_or_nil(row.p95_ms),
        max_ms: row.max_ms
      }
    end)
  end

  defp round_or_nil(nil), do: nil
  defp round_or_nil(n) when is_number(n), do: round(n)
  defp round_or_nil(%Decimal{} = d), do: d |> Decimal.to_float() |> round()
  defp round_or_nil(_), do: nil

  defp domain_of(%{target_inbox: inbox}) when is_binary(inbox) do
    case URI.parse(inbox) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp domain_of(_), do: nil

  defp naive_to_utc(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  defp naive_to_utc(%DateTime{} = dt), do: dt
  defp naive_to_utc(other), do: other
end
