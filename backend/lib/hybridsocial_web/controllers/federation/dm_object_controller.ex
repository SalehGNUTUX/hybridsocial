defmodule HybridsocialWeb.Federation.DmObjectController do
  @moduledoc """
  Handler for DM note URLs (`GET /dm/:id`).

  ActivityPub object IDs are globally unique URIs — Mastodon stores
  `object.id` and may dereference it later (e.g. when it displays the
  "See more replies on the origin instance" link in its UI, or when another
  peer attempts to fetch context).

  DMs are private, so we never expose their contents over a public
  GET. But when the viewer IS a participant (authenticated via the
  hs_access cookie from a browser click), we redirect them to their
  DM conversation view — that's the reachable landing page for the
  link. Non-participants (including unauthenticated visitors and
  AP-dereference-only peers) get a 404.
  """
  use HybridsocialWeb, :controller

  import Ecto.Query

  alias Hybridsocial.Messaging.{Message, Participant}
  alias Hybridsocial.Repo

  def show(conn, %{"id" => message_id}) do
    with %Message{conversation_id: conv_id} <- Repo.get(Message, message_id),
         true <- viewer_is_participant?(conn, conv_id) do
      # Participant: bounce into the frontend DM conversation view.
      # The SvelteKit route handles rendering + its own auth check.
      conn
      |> put_resp_header("location", "/messages/#{conv_id}")
      |> send_resp(302, "")
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "dm.not_found"})
    end
  end

  defp viewer_is_participant?(conn, conversation_id) do
    case current_identity_id(conn) do
      nil ->
        false

      identity_id ->
        Repo.exists?(
          from p in Participant,
            where:
              p.conversation_id == ^conversation_id and p.identity_id == ^identity_id and
                is_nil(p.left_at)
        )
    end
  end

  # Lightweight cookie/Bearer auth check. We don't want to pipe this
  # route through `:authenticated` (that layer adds rate-limit +
  # audit-log machinery meant for REST API endpoints); we only need
  # "is this request bearing a valid token?"
  defp current_identity_id(conn) do
    conn = Plug.Conn.fetch_cookies(conn)

    token =
      conn.cookies["hs_access"] ||
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer " <> t | _] -> t
          _ -> nil
        end

    if is_binary(token) and token != "" do
      case Hybridsocial.Auth.Token.verify_access_token(token) do
        {:ok, %{"sub" => identity_id}} -> identity_id
        _ -> nil
      end
    end
  end
end
