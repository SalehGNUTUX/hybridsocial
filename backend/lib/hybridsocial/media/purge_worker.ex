defmodule Hybridsocial.Media.PurgeWorker do
  @moduledoc """
  Periodically hard-deletes media rows that have been soft-deleted
  for more than the configured retention window (default 7 days).
  Soft-delete = `deleted_at` set by the post-edit reconcile flow,
  the user's own media-trash action, etc.

  Runs once an hour. Safe to start before any rows exist; the first
  pass is a no-op until something gets soft-deleted.
  """
  use GenServer

  require Logger

  import Ecto.Query
  alias Hybridsocial.Repo
  alias Hybridsocial.Media.{MediaFile, Storage}

  @default_interval :timer.hours(1)
  @retention_days 7

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule_next(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:purge, state) do
    try do
      purged = purge_expired()
      if purged > 0, do: Logger.info("MediaPurgeWorker: deleted #{purged} expired rows")
    rescue
      e -> Logger.error("MediaPurgeWorker failed: #{inspect(e)}")
    end

    schedule_next(state.interval)
    {:noreply, state}
  end

  @doc """
  Hard-deletes media rows whose `deleted_at` is older than the
  retention window. Best-effort removes the underlying storage blob
  too — a failed file delete still drops the DB row so the row
  doesn't pile up forever.
  """
  def purge_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days * 86400, :second)

    expired =
      from(m in MediaFile,
        where: not is_nil(m.deleted_at) and m.deleted_at < ^cutoff
      )
      |> Repo.all()

    Enum.each(expired, fn media ->
      try do
        if media.storage_path, do: Storage.delete(media.storage_path)
        if media.thumbnail_path, do: Storage.delete(media.thumbnail_path)
      rescue
        _ -> :ok
      end

      Repo.delete(media)
    end)

    length(expired)
  end

  defp schedule_next(interval) do
    Process.send_after(self(), :purge, interval)
  end
end
