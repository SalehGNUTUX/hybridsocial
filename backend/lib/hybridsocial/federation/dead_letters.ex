defmodule Hybridsocial.Federation.DeadLetters do
  @moduledoc """
  Operations on `federation_deliveries` rows that have exhausted their
  retries (status = "failed"). Powers the admin Dead-Letter Queue.
  """

  import Ecto.Query
  require Logger

  alias Hybridsocial.Repo
  alias Hybridsocial.Federation.{Delivery, Publisher}
  alias Hybridsocial.Accounts

  @doc """
  List failed deliveries, newest failure first.
  """
  def list(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(200)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    from(d in "federation_deliveries",
      where: d.status == "failed",
      order_by: [desc: d.last_attempt_at, desc: d.inserted_at],
      limit: ^limit,
      offset: ^offset,
      select: %{
        id: d.id,
        activity_id: d.activity_id,
        activity_type: d.activity_type,
        actor_id: d.actor_id,
        target_inbox: d.target_inbox,
        attempts: d.attempts,
        last_attempt_at: d.last_attempt_at,
        inserted_at: d.inserted_at,
        error: d.error,
        body_available: not is_nil(d.activity_body)
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      # Querying the raw table source (`d in "federation_deliveries"`)
      # bypasses the schema's :binary_id Ecto type, so id/actor_id come
      # back as 16-byte binaries that Jason can't encode. Cast to the
      # standard UUID string form before serialization.
      row
      |> Map.put(:id, uuid_to_string(row.id))
      |> Map.put(:actor_id, uuid_to_string(row.actor_id))
      |> Map.put(:domain, domain_of(row.target_inbox))
    end)
  end

  defp uuid_to_string(nil), do: nil

  defp uuid_to_string(<<_::128>> = bin) do
    case Ecto.UUID.load(bin) do
      {:ok, str} -> str
      _ -> nil
    end
  end

  defp uuid_to_string(s) when is_binary(s), do: s

  @doc "Total number of failed deliveries (for pagination metadata)."
  def count do
    Repo.one(
      from d in "federation_deliveries",
        where: d.status == "failed",
        select: count(d.id)
    ) || 0
  end

  @doc """
  Re-attempt a single failed delivery. Reads the stored activity body,
  signs it, POSTs it to the original inbox, and updates the row's
  status accordingly. Returns `{:ok, :delivered | :failed}` or
  `{:error, reason}`.
  """
  def retry(delivery_id) do
    with {:ok, _} <- Ecto.UUID.cast(delivery_id),
         %Delivery{} = delivery <- Repo.get(Delivery, delivery_id),
         {:ok, body} <- ensure_body(delivery),
         {:ok, identity} <- ensure_actor(delivery.actor_id) do
      # Bump the row to retrying so concurrent admin clicks don't
      # double-fire. attempts increments so the audit trail still
      # makes sense; we don't reset to zero — the failures happened.
      {:ok, _} =
        delivery
        |> Delivery.changeset(%{
          status: "retrying",
          last_attempt_at: DateTime.utc_now()
        })
        |> Repo.update()

      result = Publisher.deliver(body, delivery.target_inbox, identity)
      duration_ms = Publisher.last_delivery_duration_ms()

      case result do
        {:ok, _status} ->
          delivery
          |> Delivery.changeset(%{
            status: "delivered",
            attempts: delivery.attempts + 1,
            last_attempt_at: DateTime.utc_now(),
            duration_ms: duration_ms,
            error: nil
          })
          |> Repo.update()

          {:ok, :delivered}

        {:error, reason} ->
          delivery
          |> Delivery.changeset(%{
            status: "failed",
            attempts: delivery.attempts + 1,
            last_attempt_at: DateTime.utc_now(),
            duration_ms: duration_ms,
            error: to_string(reason)
          })
          |> Repo.update()

          {:ok, :failed}
      end
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Re-attempt every failed delivery for a given domain. Returns
  `{ok_count, failed_count}` so the UI can show the outcome.
  """
  def retry_domain(domain) when is_binary(domain) do
    ids =
      from(d in "federation_deliveries",
        where:
          d.status == "failed" and
            fragment("split_part(split_part(?, '/', 3), ':', 1) = ?", d.target_inbox, ^domain),
        select: d.id
      )
      |> Repo.all()

    Enum.reduce(ids, {0, 0}, fn id, {ok, fail} ->
      # `ids` came from a binary_id select on the raw source, so each
      # element is a 16-byte binary. retry/1 expects a UUID string.
      case retry(uuid_to_string(id)) do
        {:ok, :delivered} -> {ok + 1, fail}
        _ -> {ok, fail + 1}
      end
    end)
  end

  @doc "Permanently drop a dead-letter row without retrying."
  def drop(delivery_id) do
    case Repo.get(Delivery, delivery_id) do
      nil -> {:error, :not_found}
      delivery -> Repo.delete(delivery)
    end
  end

  defp ensure_body(%Delivery{activity_body: body}) when is_map(body), do: {:ok, body}
  defp ensure_body(_), do: {:error, :body_not_available}

  defp ensure_actor(actor_id) do
    case Accounts.get_identity(actor_id) do
      nil -> {:error, :actor_not_found}
      identity -> {:ok, identity}
    end
  end

  defp domain_of(inbox) when is_binary(inbox) do
    case URI.parse(inbox) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp domain_of(_), do: nil
end
