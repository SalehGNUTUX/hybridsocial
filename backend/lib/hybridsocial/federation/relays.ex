defmodule Hybridsocial.Federation.Relays do
  @moduledoc """
  Context for managing ActivityPub relay subscriptions.
  Relays broadcast content to and from other instances.
  """
  import Ecto.Query
  require Logger

  alias Hybridsocial.Repo
  alias Hybridsocial.Federation.Relay

  @doc """
  Subscribes to a relay by sending an AP `Follow { object: Public }`
  to the relay's inbox. Signed with the instance actor's key (relays
  follow the server, not a user).

  The relay will reply with an Accept activity landing on our inbox;
  `accept_relay/1` upgrades the row status to "accepted" at that
  point. Until then status stays "pending" and no fan-out happens.
  """
  def subscribe_to_relay(inbox_url, _admin_id) do
    alias Hybridsocial.Federation.Publisher

    with {:ok, relay} <-
           %Relay{}
           |> Relay.changeset(%{inbox_url: inbox_url, status: "pending"})
           |> Repo.insert() do
      activity = build_relay_follow(relay.id)

      # Fire the Follow async so the admin doesn't wait on a remote
      # relay's response. Delivery errors flip status back to "failed"
      # so the UI can show what happened.
      Task.start(fn ->
        case Publisher.deliver_as_instance(activity, inbox_url) do
          {:ok, _status} ->
            Logger.info("Relay Follow sent to #{inbox_url}")
            # Stash the Follow activity so we can build a matching
            # Undo later without regenerating the id.
            relay
            |> Relay.changeset(%{follow_activity_id: activity["id"]})
            |> Repo.update()

          {:error, reason} ->
            Logger.warning("Relay Follow to #{inbox_url} failed: #{inspect(reason)}")

            Repo.get(Relay, relay.id)
            |> case do
              nil -> :ok
              r -> r |> Relay.changeset(%{status: "failed", last_error: inspect(reason)}) |> Repo.update()
            end
        end
      end)

      {:ok, relay}
    end
  end

  @doc """
  Unsubscribes from a relay. Sends `Undo { Follow }` first, then
  deletes the DB row. Missing instance keys or network errors are
  logged but don't prevent the row delete — the admin asked to
  leave, we leave locally regardless.
  """
  def unsubscribe_from_relay(relay_id, _admin_id) do
    case Repo.get(Relay, relay_id) do
      nil ->
        {:error, :not_found}

      relay ->
        send_undo(relay)
        Repo.delete(relay)
    end
  end

  defp send_undo(%Relay{inbox_url: inbox_url, follow_activity_id: follow_id}) do
    alias Hybridsocial.Federation.InstanceActor
    alias Hybridsocial.Federation.Publisher

    follow =
      case follow_id do
        id when is_binary(id) and id != "" ->
          %{
            "id" => id,
            "type" => "Follow",
            "actor" => InstanceActor.ap_id(),
            "object" => "https://www.w3.org/ns/activitystreams#Public",
            "to" => ["https://www.w3.org/ns/activitystreams#Public"]
          }

        _ ->
          # Subscribed before follow_activity_id was tracked. Rebuild
          # a plausible Follow shape — relays typically match on
          # actor + object, not the id, when processing Undos.
          build_relay_follow_body()
      end

    undo = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{InstanceActor.ap_id()}/undo/#{Ecto.UUID.generate()}",
      "type" => "Undo",
      "actor" => InstanceActor.ap_id(),
      "object" => follow
    }

    Task.start(fn ->
      case Publisher.deliver_as_instance(undo, inbox_url) do
        {:ok, _} -> Logger.info("Relay Undo{Follow} sent to #{inbox_url}")
        {:error, r} -> Logger.warning("Relay Undo to #{inbox_url} failed: #{inspect(r)}")
      end
    end)

    :ok
  end

  defp build_relay_follow(relay_row_id) do
    alias Hybridsocial.Federation.InstanceActor

    base = HybridsocialWeb.Endpoint.url()

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{base}/activities/relay-follow-#{relay_row_id}",
      "type" => "Follow",
      "actor" => InstanceActor.ap_id(),
      "object" => "https://www.w3.org/ns/activitystreams#Public",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }
  end

  defp build_relay_follow_body do
    alias Hybridsocial.Federation.InstanceActor

    %{
      "type" => "Follow",
      "actor" => InstanceActor.ap_id(),
      "object" => "https://www.w3.org/ns/activitystreams#Public"
    }
  end

  @doc """
  Lists all relays.
  """
  def list_relays do
    Relay
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  @doc """
  Marks a relay as accepted. Called when we receive an Accept activity
  from the relay in response to our Follow.
  """
  def accept_relay(domain) do
    relay =
      Relay
      |> where([r], fragment("? LIKE '%' || ? || '%'", r.inbox_url, ^domain))
      |> Repo.one()

    case relay do
      nil ->
        {:error, :not_found}

      relay ->
        relay
        |> Relay.changeset(%{status: "accepted"})
        |> Repo.update()
    end
  end

  @doc """
  Processes an Announce activity received from a relay. The relay
  re-publishes content from instances we don't directly federate
  with — typical use case is "Mastodon Relay" instances that fan
  out posts across smaller instances.

  We extract the announced object URL, dereference it through the
  standard inbox path so it gets MRF + content-filter treatment, and
  rely on the inbox's get_post_by_ap_id check to dedupe if we've
  already seen the post via another route.
  """
  def process_relay_announce(activity) do
    case activity do
      %{"actor" => relay_actor, "object" => object_url} when is_binary(object_url) ->
        # Confirm the announcing actor is a registered relay before
        # accepting the announced post — otherwise any actor could
        # spam our inbox with arbitrary URLs.
        if known_relay?(relay_actor) do
          Hybridsocial.Federation.ObjectResolver.resolve(object_url)
        else
          {:error, :unknown_relay}
        end

      _ ->
        {:error, :invalid_announce}
    end
  end

  # Relays in our DB are stored by inbox_url. The relay's actor URL
  # typically lives on the same host (e.g. inbox at
  # https://relay.example/inbox, actor at https://relay.example/actor).
  # Match by host so we don't have to track a second column.
  defp known_relay?(actor_url) when is_binary(actor_url) do
    case URI.parse(actor_url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host_pattern = "%//#{host}/%"

        Repo.exists?(
          from(r in Relay,
            where: like(r.inbox_url, ^host_pattern) and r.status == "accepted"
          )
        )

      _ ->
        false
    end
  end

  defp known_relay?(_), do: false

  @doc """
  Gets a relay by ID.
  """
  def get_relay(id) do
    Repo.get(Relay, id)
  end
end
