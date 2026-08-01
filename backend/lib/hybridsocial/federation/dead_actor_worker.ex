defmodule Hybridsocial.Federation.DeadActorWorker do
  @moduledoc """
  Periodically retires remote followers whose server says they are
  gone (see `Hybridsocial.Federation.DeadActors`).

  Most servers do broadcast a `Delete` when an account closes, and the
  inbox handles that immediately — but the broadcast is best-effort: it
  is lost if we were unreachable at that moment, and some servers never
  send it at all. This sweep is the backstop, so a dead follower is
  retired within a day either way instead of generating one dead letter
  per post forever.

  Runs daily rather than hourly: each candidate costs a signed fetch
  plus possibly a webfinger against a foreign host, and an account that
  has been gone for a week can wait another few hours. Set
  `federation_dead_actor_cleanup_enabled` to `false` to turn it off.
  """
  use GenServer

  alias Hybridsocial.Config
  alias Hybridsocial.Federation.DeadActors

  require Logger

  @interval :timer.hours(24)
  # Let the node finish booting (and any queued deliveries drain) before
  # spending the first round of outbound fetches.
  @boot_delay :timer.minutes(10)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Process.send_after(self(), :tick, @boot_delay)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    if enabled?(), do: safely_sweep()

    Process.send_after(self(), :tick, @interval)
    {:noreply, state}
  end

  defp safely_sweep do
    case DeadActors.sweep() do
      %{checked: 0} ->
        :ok

      %{checked: checked, retired: retired, alive: alive, unknown: unknown} ->
        Logger.info(
          "DeadActorWorker: checked #{checked} candidate(s) — " <>
            "#{retired} retired, #{alive} still alive, #{unknown} inconclusive"
        )
    end
  rescue
    e ->
      Logger.error("DeadActorWorker crashed: #{Exception.message(e)}")
      :error
  end

  defp enabled?, do: Config.get("federation_dead_actor_cleanup_enabled", true) != false
end
