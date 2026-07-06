defmodule HybridsocialWeb.Federation.ActorController do
  use HybridsocialWeb, :controller

  import Ecto.Query

  alias Hybridsocial.Repo
  alias Hybridsocial.Accounts
  alias Hybridsocial.Accounts.Identity
  alias Hybridsocial.Social.Follow
  alias Hybridsocial.Federation.ActorSerializer
  alias Hybridsocial.Federation.LocalUrl
  alias Hybridsocial.Federation.OutboxSerializer

  # ActivityPub spec permits either of these two media types for
  # actor + collection JSON. Some clients (notably Pleroma's older
  # versions) request only `application/ld+json`, so we negotiate
  # rather than hardcoding one.
  @ap_content_type "application/activity+json"
  @ld_content_type ~s(application/ld+json; profile="https://www.w3.org/ns/activitystreams")

  # Resolve the actor for a request. Native actors are addressed by UUID
  # at `/actors/:id`. Actors imported from a retired Pleroma/Rebased
  # instance are addressed at their original `/users/:nickname` path, and
  # are only served there when a LOCAL identity actually advertises that
  # exact URL — so a native user (who lives at `/actors/<uuid>`) can't be
  # dereferenced under `/users/`.
  defp resolve_identity(%{"id" => id}), do: Accounts.get_identity(id)

  defp resolve_identity(%{"nickname" => nickname}) do
    case Accounts.get_identity_by_handle(nickname) do
      %Identity{} = identity ->
        expected = "#{HybridsocialWeb.Endpoint.url()}/users/#{nickname}"

        if LocalUrl.local_identity?(identity) and identity.ap_actor_url == expected,
          do: identity,
          else: nil

      _ ->
        nil
    end
  end

  defp resolve_identity(_), do: nil

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{error: "Actor not found"})
  end

  # sobelow_skip ["XSS.ContentType"]
  # Safe: negotiated_content_type/1 only returns one of two module
  # attributes (@ap_content_type, @ld_content_type) — no user data
  # reaches the header.
  def show(conn, params) do
    case resolve_identity(params) do
      nil ->
        not_found(conn)

      identity ->
        # A browser hitting the canonical actor URL should land on the web
        # profile, not raw ActivityPub JSON — matches how Pleroma/Mastodon
        # negotiate. Fediverse servers (activity+json / ld+json) still get
        # the actor document.
        if prefers_html?(conn) do
          redirect(conn, to: "/@" <> identity.handle)
        else
          actor = ActorSerializer.to_ap(identity)

          conn
          |> put_resp_content_type(negotiated_content_type(conn))
          |> json(actor)
        end
    end
  end

  defp prefers_html?(conn) do
    accept =
      conn
      |> Plug.Conn.get_req_header("accept")
      |> List.first()
      |> to_string()
      |> String.downcase()

    String.contains?(accept, "text/html") and
      not String.contains?(accept, "application/activity+json") and
      not String.contains?(accept, "application/ld+json")
  end

  # Picks the content type to emit based on the Accept header. Falls
  # back to `application/activity+json` (the more common AP type) when
  # nothing matches or the client sent no Accept header.
  defp negotiated_content_type(conn) do
    accept_headers = Plug.Conn.get_req_header(conn, "accept")
    accept = accept_headers |> List.first() |> to_string() |> String.downcase()

    cond do
      String.contains?(accept, "application/ld+json") -> @ld_content_type
      String.contains?(accept, "application/activity+json") -> @ap_content_type
      true -> @ap_content_type
    end
  end

  # The self-referential collection `id` must match what the actor
  # document advertises, so imported actors report their stored URL
  # while native actors keep the computed `/actors/<uuid>/...` form.
  defp collection_url(identity, stored, suffix) do
    stored || "#{HybridsocialWeb.Endpoint.url()}/actors/#{identity.id}#{suffix}"
  end

  defp actor_url_for(identity, base_url) do
    identity.ap_actor_url || "#{base_url}/actors/#{identity.id}"
  end

  # sobelow_skip ["XSS.ContentType"]
  def followers(conn, params) do
    case resolve_identity(params) do
      nil ->
        not_found(conn)

      identity ->
        base_url = HybridsocialWeb.Endpoint.url()
        collection_url = collection_url(identity, identity.followers_url, "/followers")

        follower_identities =
          Follow
          |> where([f], f.followee_id == ^identity.id and f.status == :accepted)
          |> join(:inner, [f], i in Identity, on: f.follower_id == i.id)
          |> select([f, i], i)
          |> Repo.all()

        follower_urls = Enum.map(follower_identities, &actor_url_for(&1, base_url))

        collection = %{
          "@context" => ["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"],
          "id" => collection_url,
          "type" => "OrderedCollection",
          "totalItems" => length(follower_urls),
          "orderedItems" => follower_urls
        }

        conn
        |> put_resp_content_type(negotiated_content_type(conn))
        |> json(collection)
    end
  end

  # sobelow_skip ["XSS.ContentType"]
  def following(conn, params) do
    case resolve_identity(params) do
      nil ->
        not_found(conn)

      identity ->
        base_url = HybridsocialWeb.Endpoint.url()
        collection_url = collection_url(identity, identity.following_url, "/following")

        following_identities =
          Follow
          |> where([f], f.follower_id == ^identity.id and f.status == :accepted)
          |> join(:inner, [f], i in Identity, on: f.followee_id == i.id)
          |> select([f, i], i)
          |> Repo.all()

        following_urls = Enum.map(following_identities, &actor_url_for(&1, base_url))

        collection = %{
          "@context" => ["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"],
          "id" => collection_url,
          "type" => "OrderedCollection",
          "totalItems" => length(following_urls),
          "orderedItems" => following_urls
        }

        conn
        |> put_resp_content_type(negotiated_content_type(conn))
        |> json(collection)
    end
  end

  def featured(conn, params) do
    case resolve_identity(params) do
      nil ->
        not_found(conn)

      identity ->
        base_url = HybridsocialWeb.Endpoint.url()

        # Use the schema (not a raw "posts" string source) so Ecto casts
        # the string-form UUID to binary for us. The raw-source query
        # crashed with `Postgrex expected a binary of 16 bytes` when
        # called via the federation route — Mastodon hits this endpoint
        # on every actor lookup.
        pinned =
          from(p in Hybridsocial.Social.Post,
            where: p.identity_id == ^identity.id and p.is_pinned == true and is_nil(p.deleted_at),
            select: p.id,
            order_by: [desc: p.inserted_at]
          )
          |> Repo.all()

        items = Enum.map(pinned, fn post_id -> "#{base_url}/posts/#{post_id}" end)

        conn
        |> put_resp_content_type(@ap_content_type)
        |> json(%{
          "@context" => ["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"],
          "id" => collection_url(identity, identity.featured_url, "/collections/featured"),
          "type" => "OrderedCollection",
          "totalItems" => length(items),
          "orderedItems" => items
        })
    end
  end

  # sobelow_skip ["XSS.ContentType"]
  def outbox(conn, params) do
    case resolve_identity(params) do
      nil ->
        not_found(conn)

      identity ->
        page =
          case params["page"] do
            nil -> nil
            p when is_binary(p) -> String.to_integer(p)
            p when is_integer(p) -> p
          end

        collection = OutboxSerializer.serialize_outbox(identity, page)

        conn
        |> put_resp_content_type(negotiated_content_type(conn))
        |> json(collection)
    end
  end
end
