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
  Subscribes to a relay. The URL the admin provides can be either:

    * A Mastodon-style inbox URL (e.g. `https://relay.example/inbox`) —
      we POST `Follow { object: AS:Public }` there.
    * A Pleroma-style actor URL (e.g. `https://relay.example/actor`) —
      we dereference it to discover the inbox, then POST
      `Follow { object: <actor_url> }` to that inbox.

  Detection: if GETting the URL returns an ActivityPub actor object
  (has an `inbox` field), treat as Pleroma-style. Otherwise treat
  the URL as the inbox directly.

  The Follow is signed with the instance actor's key. The relay
  reply (Accept) lands on our inbox asynchronously; status flips
  from "pending" to "accepted" when that arrives.
  """
  def subscribe_to_relay(url, _admin_id) do
    alias Hybridsocial.Federation.Publisher

    {inbox_url, actor_url, style} = classify_relay(url)

    with {:ok, relay} <-
           %Relay{}
           |> Relay.changeset(%{
             inbox_url: inbox_url,
             actor_url: actor_url,
             status: "pending"
           })
           |> Repo.insert() do
      activity = build_relay_follow(relay, style)

      # Fire the Follow async so the admin doesn't wait on a remote
      # relay's response. Delivery errors flip status to "failed"
      # so the UI can show what happened.
      Task.start(fn ->
        case Publisher.deliver_as_instance(activity, inbox_url) do
          {:ok, _status} ->
            Logger.info("Relay Follow sent to #{inbox_url} (#{style})")

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

  # Dereferences the URL to see whether it's an AP actor (→ Pleroma
  # style) or an opaque inbox (→ Mastodon style). Falls back to
  # Mastodon-style on any network / parsing failure so a typo'd URL
  # still gets a meaningful Follow attempt the admin can see fail.
  defp classify_relay(url) do
    headers = [{"Accept", "application/activity+json"}]

    case HTTPoison.get(url, headers, recv_timeout: 10_000, timeout: 10_000, follow_redirect: true) do
      {:ok, %{status_code: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"inbox" => inbox} = actor}
          when is_binary(inbox) and inbox != "" ->
            id = Map.get(actor, "id", url)
            {inbox, id, :pleroma}

          _ ->
            {url, nil, :mastodon}
        end

      _ ->
        {url, nil, :mastodon}
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

  defp send_undo(%Relay{inbox_url: inbox_url, actor_url: actor_url, follow_activity_id: follow_id} = relay) do
    alias Hybridsocial.Federation.InstanceActor
    alias Hybridsocial.Federation.Publisher

    style = if is_binary(actor_url) and actor_url != "", do: :pleroma, else: :mastodon
    {object, to} = follow_target(style, actor_url)

    follow =
      case follow_id do
        id when is_binary(id) and id != "" ->
          %{
            "id" => id,
            "type" => "Follow",
            "actor" => InstanceActor.ap_id(),
            "object" => object,
            "to" => to
          }

        _ ->
          # Subscribed before follow_activity_id was tracked. Rebuild
          # a plausible Follow shape — relays typically match on
          # actor + object, not the id, when processing Undos.
          build_relay_follow_body(relay)
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

  defp build_relay_follow(%Relay{id: id, actor_url: actor_url}, style) do
    alias Hybridsocial.Federation.InstanceActor

    base = HybridsocialWeb.Endpoint.url()
    {object, to} = follow_target(style, actor_url)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{base}/activities/relay-follow-#{id}",
      "type" => "Follow",
      "actor" => InstanceActor.ap_id(),
      "object" => object,
      "to" => to
    }
  end

  defp follow_target(:pleroma, actor_url) when is_binary(actor_url),
    do: {actor_url, [actor_url]}

  defp follow_target(_, _),
    do: {
      "https://www.w3.org/ns/activitystreams#Public",
      ["https://www.w3.org/ns/activitystreams#Public"]
    }

  defp build_relay_follow_body(%Relay{actor_url: actor_url}) do
    alias Hybridsocial.Federation.InstanceActor

    style = if is_binary(actor_url) and actor_url != "", do: :pleroma, else: :mastodon
    {object, _to} = follow_target(style, actor_url)

    %{
      "type" => "Follow",
      "actor" => InstanceActor.ap_id(),
      "object" => object
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
  def accept_relay(actor_url_or_domain) do
    # Prefer exact actor_url match (Pleroma-style); fall back to
    # hostname-in-inbox_url match (Mastodon-style where we don't
    # know the relay's actor URL up front).
    query =
      case URI.parse(actor_url_or_domain) do
        %URI{host: host} when is_binary(host) and host != "" ->
          pattern_inbox = "%//#{host}/%"

          from r in Relay,
            where: r.actor_url == ^actor_url_or_domain or like(r.inbox_url, ^pattern_inbox)

        _ ->
          pattern_inbox = "%" <> actor_url_or_domain <> "%"

          from r in Relay,
            where: like(r.inbox_url, ^pattern_inbox)
      end

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      relay ->
        relay
        |> Relay.changeset(%{status: "accepted", last_error: nil})
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
    # Exact actor_url match catches Pleroma-style relays, host-match
    # on the inbox catches Mastodon-style (where we don't know the
    # actor URL, just the inbox).
    host_pattern =
      case URI.parse(actor_url) do
        %URI{host: host} when is_binary(host) and host != "" -> "%//#{host}/%"
        _ -> nil
      end

    query =
      if host_pattern do
        from r in Relay,
          where:
            r.status == "accepted" and
              (r.actor_url == ^actor_url or like(r.inbox_url, ^host_pattern))
      else
        from r in Relay,
          where: r.status == "accepted" and r.actor_url == ^actor_url
      end

    Repo.exists?(query)
  end

  defp known_relay?(_), do: false

  @doc """
  Gets a relay by ID.
  """
  def get_relay(id) do
    Repo.get(Relay, id)
  end
end
