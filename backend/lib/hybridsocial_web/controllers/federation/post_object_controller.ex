defmodule HybridsocialWeb.Federation.PostObjectController do
  @moduledoc """
  Serves the ActivityPub JSON-LD representation of a single post at
  `GET /posts/:id`. This is the URL our Create/Update activities
  embed as `object.id`, so remote servers dereference it to verify +
  hydrate the object. Without this endpoint every outbound Create
  Mastodon receives fails subsequent re-fetches with a 404, which
  is why replies from a peer instance never show up in Mastodon threads
  beyond the first level — Mastodon couldn't resolve the reply
  chain.

  Only public + unlisted posts are served; followers-only and direct
  messages 404 to preserve the scope the author picked.
  """
  use HybridsocialWeb, :controller

  alias Hybridsocial.Federation.ActivityBuilder
  alias Hybridsocial.Social.Posts

  @ap_content_type "application/activity+json"
  @ld_content_type ~s(application/ld+json; profile="https://www.w3.org/ns/activitystreams")

  @public_visibilities ~w(public unlisted)

  def show(conn, %{"id" => id}) do
    # Browsers that follow a federated "View original" link don't ask
    # for AP — they ask for `text/html`. Without a redirect they used
    # to receive the raw JSON-LD document. Serve AP only when the
    # client actually asked for it; otherwise bounce them to the
    # SvelteKit page (`/post/:id`, singular).
    if wants_activity_pub?(conn) do
      serve_activity_pub(conn, id)
    else
      conn
      |> Phoenix.Controller.redirect(to: "/post/#{id}")
      |> halt()
    end
  end

  # sobelow_skip ["XSS.ContentType"]
  # Safe: negotiated_content_type/1 returns one of two fixed module
  # attributes (@ld_content_type / @ap_content_type). The request Accept
  # header is only pattern-matched, never echoed into the response, so no
  # user input reaches the content-type header. (The annotation belongs on
  # THIS function — put_resp_content_type is called here, not in show/2.)
  defp serve_activity_pub(conn, id) do
    with post when not is_nil(post) <- Posts.get_post_with_context(id),
         true <- public?(post) do
      note = ActivityBuilder.build_note(post)

      # `build_note/1` is reused across Create/Update/outbox, which
      # only attach @context at the WRAPPER level. When we serve the
      # note directly, the root document needs its own @context.
      note_with_context =
        Map.put(
          note,
          "@context",
          [
            "https://www.w3.org/ns/activitystreams",
            "https://w3id.org/security/v1"
          ]
        )

      conn
      |> put_resp_content_type(negotiated_content_type(conn))
      |> json(note_with_context)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "post.not_found"})
    end
  end

  defp wants_activity_pub?(conn) do
    accept = Plug.Conn.get_req_header(conn, "accept") |> List.first() |> to_string()

    String.contains?(accept, "application/activity+json") or
      String.contains?(accept, "application/ld+json")
  end

  defp public?(%{visibility: vis, deleted_at: nil}) when vis in @public_visibilities,
    do: true

  defp public?(%{visibility: v, deleted_at: nil}) when is_atom(v) do
    Atom.to_string(v) in @public_visibilities
  end

  defp public?(_), do: false

  defp negotiated_content_type(conn) do
    accept = Plug.Conn.get_req_header(conn, "accept") |> List.first() |> to_string()

    cond do
      String.contains?(accept, "application/ld+json") -> @ld_content_type
      String.contains?(accept, "application/activity+json") -> @ap_content_type
      true -> @ap_content_type
    end
  end
end
