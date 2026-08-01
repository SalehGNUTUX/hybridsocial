defmodule Hybridsocial.Federation.DeliveryRetentionWorker do
  @moduledoc """
  Prunes `federation_deliveries` rows in a terminal state older than the
  configured retention window. Default: 30 days, tunable at runtime via
  the `federation_delivery_retention_days` instance setting.

  Every fan-out writes one row per recipient inbox and nothing ever
  removed them, so the table grew forever: a small instance reaches tens
  of thousands of rows within weeks, and the admin dead-letter queue
  turns into an unreadable backlog of failures against peers that died
  months ago.

  Pending / retrying rows are never touched — they are live work. Runs
  hourly so a retention change takes effect within the hour, and it is a
  cheap no-op when there is nothing past the cutoff.

  Setting the value to `0` disables pruning entirely (keep everything).
  """
  use GenServer

  alias Hybridsocial.Config
  alias Hybridsocial.Federation.DeadLetters

  require Logger

  @interval :timer.hours(1)
  @default_retention_days 30

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
      {0, 0} ->
        :ok

      {delivered, failed} ->
        Logger.info(
          "DeliveryRetentionWorker: pruned #{delivered} delivered + #{failed} failed delivery row(s)"
        )
    end

    Process.send_after(self(), :tick, @interval)
    {:noreply, state}
  end

  defp safely_prune do
    case retention_days() do
      0 -> {0, 0}
      days -> DeadLetters.prune(days)
    end
  rescue
    e ->
      Logger.error("DeliveryRetentionWorker crashed: #{Exception.message(e)}")
      {0, 0}
  end

  @doc """
  The configured retention window in days, or `0` when pruning is off.
  Falls back to the default for anything unparseable so a bad setting
  can't silently stop retention.
  """
  def retention_days do
    case Config.get("federation_delivery_retention_days", @default_retention_days) do
      n when is_integer(n) and n >= 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {i, _} when i >= 0 -> i
          _ -> @default_retention_days
        end

      _ ->
        @default_retention_days
    end
  end
end
