defmodule Hybridsocial.Groups.GroupSanctionExpiryWorker do
  @moduledoc """
  Clears group member sanctions (timed bans and partial bans) whose
  `restricted_until` has passed. Runs every 5 minutes.

  **Cleanup only.** `Groups.can_do_in_group?/3` already treats a lapsed
  sanction as lifted at read time, so a late tick — or this process being
  dead — never leaves a member sanctioned past their time. That ordering is
  deliberate: the correctness lives in the authorization path, and this just
  tidies the rows so the data matches what's being enforced.
  """
  use GenServer

  alias Hybridsocial.Groups

  require Logger

  @interval :timer.minutes(5)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    case safely_sweep() do
      n when n > 0 -> Logger.info("GroupSanctionExpiryWorker: cleared #{n} expired sanction(s)")
      _ -> :ok
    end

    schedule_tick()
    {:noreply, state}
  end

  defp safely_sweep do
    Groups.sweep_expired_sanctions()
  rescue
    e ->
      Logger.error("GroupSanctionExpiryWorker crashed: #{Exception.message(e)}")
      0
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @interval)
end
