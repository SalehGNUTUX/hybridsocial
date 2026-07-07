defmodule Hybridsocial.Bots.WebhookDeliveryWorker do
  @moduledoc """
  Drains the `bot_webhook_deliveries` queue. Mirrors the same shape
  as `Hybridsocial.Moderation.WebhookDeliveryWorker` so operators
  reading one only have to learn the pattern once: GenServer ticks
  every 10 seconds, picks `pending` rows whose `next_attempt_at` has
  arrived, POSTs the payload, and on non-2xx schedules an exponential
  retry. After three failures the row is marked `failed` and stops
  being retried.
  """
  use GenServer
  require Logger
  import Ecto.Query

  alias Hybridsocial.Repo
  alias Hybridsocial.Accounts.{Bot, BotWebhookDelivery}
  alias Hybridsocial.Bots.Webhooks

  @tick_ms 10_000
  @max_attempts 3
  @batch_size 20
  @http_timeout_ms 10_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    schedule_tick(500)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    drain()
    schedule_tick(@tick_ms)
    {:noreply, state}
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp drain do
    now = DateTime.utc_now()

    BotWebhookDelivery
    |> where([d], d.status == "pending" and d.next_attempt_at <= ^now)
    |> order_by([d], asc: d.next_attempt_at)
    |> limit(@batch_size)
    |> Repo.all()
    |> Enum.each(&attempt/1)
  end

  defp attempt(%BotWebhookDelivery{} = delivery) do
    # Look up the bot fresh each attempt — the owner may have rotated
    # the secret or cleared the URL between enqueue and now. A
    # rotated secret should sign new attempts with the new value;
    # a cleared URL means we abandon the row.
    case Repo.get(Bot, delivery.bot_identity_id) do
      %Bot{is_active: false} ->
        # Bot disabled. Don't deliver, but don't fail the row — leave
        # it pending so re-enabling drains the backlog. Bump
        # next_attempt_at so we don't tight-loop on a long-disabled bot.
        delivery
        |> BotWebhookDelivery.changeset(%{
          next_attempt_at: DateTime.utc_now() |> DateTime.add(@tick_ms * 6, :millisecond)
        })
        |> Repo.update()

      %Bot{webhook_url: nil} ->
        mark_failed(delivery, "webhook cleared by owner", nil)

      %Bot{webhook_secret_hash: nil} ->
        mark_failed(delivery, "webhook secret missing", nil)

      %Bot{} = bot ->
        deliver(delivery, bot)

      nil ->
        mark_failed(delivery, "bot deleted", nil)
    end
  end

  defp deliver(%BotWebhookDelivery{} = delivery, %Bot{} = bot) do
    body =
      Jason.encode!(%{
        event: delivery.event,
        payload: delivery.payload,
        delivered_at: DateTime.utc_now()
      })

    signature = Webhooks.sign(bot.webhook_secret_hash, body)

    headers = [
      {"content-type", "application/json"},
      {"user-agent", "HybridSocial-Webhook/1.0"},
      {"x-webhook-event", delivery.event},
      {"x-webhook-signature", "sha256=#{signature}"},
      {"x-webhook-delivery", delivery.id}
    ]

    # Use the URL snapshotted at enqueue time — see the migration
    # comment for why we don't re-read from the bot row.
    case post(delivery.webhook_url, body, headers) do
      {:ok, status} when status >= 200 and status < 300 ->
        delivery
        |> BotWebhookDelivery.changeset(%{
          status: "delivered",
          attempts: delivery.attempts + 1,
          last_status_code: status,
          delivered_at: DateTime.utc_now()
        })
        |> Repo.update()

      {:ok, status} ->
        retry_or_fail(delivery, "HTTP #{status}", status)

      {:error, reason} ->
        retry_or_fail(delivery, inspect(reason), nil)
    end
  end

  defp retry_or_fail(delivery, error, status_code) do
    attempts = delivery.attempts + 1

    if attempts >= @max_attempts do
      mark_failed(delivery, error, status_code)
    else
      delivery
      |> BotWebhookDelivery.changeset(%{
        attempts: attempts,
        last_error: error,
        last_status_code: status_code,
        next_attempt_at: next_backoff(attempts)
      })
      |> Repo.update()
    end
  end

  defp mark_failed(delivery, error, status_code) do
    delivery
    |> BotWebhookDelivery.changeset(%{
      status: "failed",
      attempts: delivery.attempts + 1,
      last_error: error,
      last_status_code: status_code
    })
    |> Repo.update()
  end

  # Same backoff schedule as the moderation worker so operators don't
  # need to learn two different retry curves: 60s → 5min → 30min.
  defp next_backoff(1), do: DateTime.utc_now() |> DateTime.add(60, :second)
  defp next_backoff(2), do: DateTime.utc_now() |> DateTime.add(300, :second)
  defp next_backoff(_), do: DateTime.utc_now() |> DateTime.add(1800, :second)

  defp post(url, body, headers) do
    case Hybridsocial.HTTP.post(url, body, headers,
           timeout: @http_timeout_ms,
           recv_timeout: @http_timeout_ms
         ) do
      {:ok, %Hybridsocial.HTTP.Response{status_code: status}} -> {:ok, status}
      {:error, %Hybridsocial.HTTP.Error{reason: reason}} -> {:error, reason}
    end
  end
end
