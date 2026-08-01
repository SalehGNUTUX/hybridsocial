defmodule HybridsocialWeb.Compat do
  @moduledoc """
  Chooses the response shape per request: ours, or Mastodon's.

  Third-party clients hardcode `/api/v1/...`, so the compat layer can't live
  on a separate route prefix — the same endpoint has to answer in whichever
  dialect the caller speaks. The discriminator is the token: one minted through
  the OAuth authorization-code flow belongs to a third-party app and gets
  Mastodon's shape, while first-party session tokens (our own web app, and
  personal app tokens from Settings > Developers) keep the native shape. That
  makes the switch automatic for real clients and invisible to our frontend.

  `X-API-Compat: mastodon | native` overrides the inference, which is how you
  reproduce a client's view by hand and how the tests drive both shapes.
  """
  import Plug.Conn, only: [get_req_header: 2, put_resp_header: 3]

  alias HybridsocialWeb.Serializers.Mastodon

  @doc "Whether this request should be answered in Mastodon's shape."
  def mastodon?(conn) do
    case get_req_header(conn, "x-api-compat") do
      ["mastodon" | _] -> true
      ["native" | _] -> false
      _ -> third_party_token?(conn)
    end
  end

  defp third_party_token?(conn) do
    case conn.assigns[:current_session] do
      %{application_id: app_id} when is_binary(app_id) -> true
      %{"application_id" => app_id} when is_binary(app_id) -> true
      _ -> false
    end
  end

  @doc """
  Renders `payload` as JSON, projected into Mastodon's shape when the caller
  is a third-party client. `kind` names the projection to apply.
  """
  def json(conn, payload, kind) do
    if mastodon?(conn) do
      Phoenix.Controller.json(conn, project(payload, kind, conn))
    else
      Phoenix.Controller.json(conn, payload)
    end
  end

  defp project(payload, :status, _conn), do: Mastodon.status(payload)
  defp project(payload, :statuses, _conn), do: Mastodon.statuses(payload)
  defp project(payload, :accounts, _conn), do: Mastodon.accounts(payload)
  defp project(payload, :relationship, _conn), do: Mastodon.relationship(payload)
  defp project(payload, :relationships, _conn), do: Mastodon.relationships(payload)
  defp project(payload, :notifications, _conn), do: Mastodon.notifications(payload)
  defp project(payload, :notification, _conn), do: Mastodon.notification(payload)
  defp project(payload, :context, _conn), do: Mastodon.context(payload)
  defp project(payload, :search, _conn), do: Mastodon.search(payload)
  defp project(payload, :emojis, _conn), do: Mastodon.emojis(payload)
  defp project(payload, :media, _conn), do: Mastodon.media_attachment(payload)
  defp project(payload, :instance_v1, _conn), do: Mastodon.instance_v1(payload)
  defp project(payload, :instance_v2, _conn), do: Mastodon.instance_v2(payload)

  # A single account is the one place `statuses_count` is actually rendered
  # (the profile header), so it's worth the extra count query here and
  # nowhere else.
  defp project(payload, :account, _conn) do
    payload
    |> with_statuses_count()
    |> Mastodon.account()
  end

  defp project(payload, :credential_account, conn) do
    Mastodon.credential_account(with_statuses_count(payload), %{
      follow_requests_count: follow_requests_count(conn)
    })
  end

  defp with_statuses_count(%{id: id} = account) when is_binary(id) do
    Map.put(account, :statuses_count, Hybridsocial.Social.Posts.published_count(id))
  end

  defp with_statuses_count(account), do: account

  defp follow_requests_count(conn) do
    case conn.assigns[:current_identity] do
      %{id: id} -> Hybridsocial.Social.pending_follow_requests_count(id)
      _ -> 0
    end
  end

  @doc """
  Mastodon paginates purely through `Link` headers, so any endpoint that
  answered with a `{data, next_cursor}` envelope has to move the cursor into
  a header before dropping to a bare array.
  """
  def put_cursor_link(conn, _base_path, nil), do: conn

  def put_cursor_link(conn, base_path, next_cursor) do
    put_resp_header(conn, "link", "<#{base_path}?max_id=#{next_cursor}>; rel=\"next\"")
  end
end
