defmodule Hybridsocial.Moderation.WebhookDeliveryWorker do
  @moduledoc """
  Drains the `webhook_deliveries` queue. Picks up rows where
  `status = "pending"` and `next_attempt_at <= now`, POSTs to the
  configured URL with the HMAC-SHA256 body signature, and on non-2xx
  bumps `attempts` with an exponential backoff schedule
  (60s → 5min → 30min). After three failed attempts the row is marked
  `failed` so it stops being retried.
  """
  use GenServer
  require Logger
  import Ecto.Query

  alias Hybridsocial.Repo
  alias Hybridsocial.Moderation.{Webhook, WebhookDelivery}

  # Tick interval. Tight enough that an admin toggling a receiver
  # back on sees events flow again within seconds, loose enough that
  # an idle instance isn't hammering the DB.
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

    pending =
      WebhookDelivery
      |> where([d], d.status == "pending" and d.next_attempt_at <= ^now)
      |> order_by([d], asc: d.next_attempt_at)
      |> limit(@batch_size)
      |> Repo.all()
      |> Repo.preload(:webhook)

    Enum.each(pending, &attempt_delivery/1)
  end

  defp attempt_delivery(%WebhookDelivery{webhook: nil} = delivery) do
    # Webhook was deleted between enqueue and drain — mark failed so
    # we stop retrying a ghost.
    mark_failed(delivery, "webhook deleted", nil)
  end

  defp attempt_delivery(%WebhookDelivery{webhook: %Webhook{enabled: false}} = delivery) do
    # Webhook disabled since enqueue. Leave pending; admin may
    # re-enable. But bump next_attempt_at to avoid tight loops.
    delivery
    |> WebhookDelivery.changeset(%{
      next_attempt_at: DateTime.utc_now() |> DateTime.add(60, :second)
    })
    |> Repo.update()
  end

  defp attempt_delivery(%WebhookDelivery{webhook: %Webhook{} = webhook} = delivery) do
    body = Jason.encode!(%{event: delivery.event, payload: delivery.payload})
    headers = build_headers(webhook, delivery.event, body)

    case post(webhook.url, body, headers) do
      {:ok, status} when status >= 200 and status < 300 ->
        delivery
        |> WebhookDelivery.changeset(%{
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
      |> WebhookDelivery.changeset(%{
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
    |> WebhookDelivery.changeset(%{
      status: "failed",
      attempts: delivery.attempts + 1,
      last_error: error,
      last_status_code: status_code
    })
    |> Repo.update()
  end

  # 60s → 5min → 30min. After attempt #3 we give up in mark_failed.
  defp next_backoff(1), do: DateTime.utc_now() |> DateTime.add(60, :second)
  defp next_backoff(2), do: DateTime.utc_now() |> DateTime.add(300, :second)
  defp next_backoff(_), do: DateTime.utc_now() |> DateTime.add(1800, :second)

  defp build_headers(webhook, event, body) do
    base = [
      {"content-type", "application/json"},
      {"user-agent", "HybridSocial-Webhook/1.0"},
      {"x-webhook-event", event}
    ]

    if webhook.secret do
      signature =
        :crypto.mac(:hmac, :sha256, webhook.secret, body) |> Base.encode16(case: :lower)

      [{"x-webhook-signature", signature} | base]
    else
      base
    end
  end

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
