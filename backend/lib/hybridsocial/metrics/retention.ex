defmodule Hybridsocial.Metrics.Retention do
  @moduledoc """
  Daily prune of `service_metrics` rows older than the retention
  window. Default is 30 days, overridable via the
  `metrics_retention_days` runtime config knob.

  Runs in its own GenServer rather than tagged onto the collector so
  a slow DELETE never delays a metrics tick.
  """

  use GenServer
  require Logger

  alias Hybridsocial.Repo

  @one_day_ms 24 * 60 * 60 * 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Wait an hour after boot before the first prune so a startup
    # storm of DDL/migrations doesn't pile on top of a vacuum.
    Process.send_after(self(), :prune, 60 * 60 * 1000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    Process.send_after(self(), :prune, @one_day_ms)
    do_prune()
    {:noreply, state}
  end

  defp do_prune do
    days = retention_days()
    cutoff = DateTime.utc_now() |> DateTime.add(-days * @one_day_ms, :millisecond)

    {deleted, _} =
      Repo.query!(
        "DELETE FROM service_metrics WHERE inserted_at < $1",
        [cutoff]
      )
      |> case do
        %Postgrex.Result{num_rows: n} -> {n, nil}
        _ -> {0, nil}
      end

    Logger.info("metrics retention: pruned #{deleted} rows older than #{days}d")
  rescue
    e -> Logger.warning("metrics retention failed: #{Exception.message(e)}")
  end

  defp retention_days do
    case Hybridsocial.Config.get("metrics_retention_days", 30) do
      n when is_integer(n) and n > 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {v, _} when v > 0 -> v
          _ -> 30
        end

      _ ->
        30
    end
  end
end
