defmodule Hybridsocial.Admin.BackupExpiryWorker do
  @moduledoc """
  Periodically deletes encrypted backup files older than the
  configured retention window. Default: 30 days. Tunable via the
  `backup_retention_days` instance setting.

  Runs hourly. The actual delete is a no-op when there's nothing
  to prune, so the hourly cadence costs almost nothing; it's tight
  enough that a retention change from the admin panel takes effect
  within the hour.
  """
  use GenServer

  alias Hybridsocial.Admin.Backup
  alias Hybridsocial.Config

  require Logger

  @interval :timer.hours(1)
  @default_retention_days 30

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Do one pass on boot so a freshly-restarted instance doesn't
    # have to wait an hour before expired backups are swept.
    send(self(), :tick)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    case safely_prune() do
      n when n > 0 -> Logger.info("BackupExpiryWorker: pruned #{n} expired backup(s)")
      _ -> :ok
    end

    Process.send_after(self(), :tick, @interval)
    {:noreply, state}
  end

  defp safely_prune do
    Backup.prune_expired(retention_days())
  rescue
    e ->
      Logger.error("BackupExpiryWorker crashed: #{Exception.message(e)}")
      0
  end

  defp retention_days do
    case Config.get("backup_retention_days", @default_retention_days) do
      n when is_integer(n) and n > 0 -> n
      n when is_binary(n) ->
        case Integer.parse(n) do
          {i, _} when i > 0 -> i
          _ -> @default_retention_days
        end
      _ -> @default_retention_days
    end
  end
end
