defmodule Hybridsocial.Moderation.ReportExpiryWorker do
  @moduledoc """
  Periodically deletes resolved / dismissed reports older than the
  configured retention window. Default: 90 days. Tunable at runtime
  via the `report_retention_days` instance setting.

  Pending reports are never touched — they still need moderator
  action. Runs hourly; cheap no-op when there's nothing past cutoff,
  tight enough that a retention setting change takes effect within
  the hour.
  """
  use GenServer

  alias Hybridsocial.{Config, Moderation}

  require Logger

  @interval :timer.hours(1)
  @default_retention_days 90

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Initial tick on boot so a freshly-started instance catches up
    # without waiting a full hour.
    send(self(), :tick)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    case safely_prune() do
      n when n > 0 -> Logger.info("ReportExpiryWorker: pruned #{n} closed report(s)")
      _ -> :ok
    end

    Process.send_after(self(), :tick, @interval)
    {:noreply, state}
  end

  defp safely_prune do
    Moderation.prune_closed_reports(retention_days())
  rescue
    e ->
      Logger.error("ReportExpiryWorker crashed: #{Exception.message(e)}")
      0
  end

  defp retention_days do
    case Config.get("report_retention_days", @default_retention_days) do
      n when is_integer(n) and n > 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {i, _} when i > 0 -> i
          _ -> @default_retention_days
        end

      _ ->
        @default_retention_days
    end
  end
end
