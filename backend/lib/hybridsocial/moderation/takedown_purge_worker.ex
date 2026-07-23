defmodule Hybridsocial.Moderation.TakedownPurgeWorker do
  @moduledoc """
  Drives the takedown appeal window. Runs hourly (with a tick on boot):

  1. Always sends a one-time reminder to owners whose takedown is within
     `takedown_reminder_lead_days` (default 7) of permanent deletion.
  2. Only when `takedown_purge_enabled` is truthy, permanently deletes the
     content of takedowns whose window has passed and that were never appealed.

  The purge is IRREVERSIBLE, so it's opt-in: the reminder half runs by default,
  but nothing is hard-deleted until an admin turns `takedown_purge_enabled` on.
  """
  use GenServer

  alias Hybridsocial.{Config, Moderation}

  require Logger

  @interval :timer.hours(1)
  @default_lead_days 7

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    send(self(), :tick)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    run_once()
    Process.send_after(self(), :tick, @interval)
    {:noreply, state}
  end

  # Exposed so a test (or an admin console) can trigger a pass directly.
  def run_once do
    reminded = safely(fn -> Moderation.send_purge_reminders(lead_days()) end, "reminders")

    if reminded > 0, do: Logger.info("TakedownPurgeWorker: sent #{reminded} reminder(s)")

    if purge_enabled?() do
      purged = safely(fn -> Moderation.purge_expired_takedowns() end, "purge")

      if purged > 0,
        do: Logger.warning("TakedownPurgeWorker: permanently purged #{purged} takedown(s)")
    end

    :ok
  end

  defp safely(fun, label) do
    fun.()
  rescue
    e ->
      Logger.error("TakedownPurgeWorker #{label} crashed: #{Exception.message(e)}")
      0
  end

  defp purge_enabled? do
    case Config.get("takedown_purge_enabled", false) do
      true -> true
      "true" -> true
      "1" -> true
      _ -> false
    end
  end

  defp lead_days do
    case Config.get("takedown_reminder_lead_days", @default_lead_days) do
      n when is_integer(n) and n >= 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {i, _} when i >= 0 -> i
          _ -> @default_lead_days
        end

      _ ->
        @default_lead_days
    end
  end
end
