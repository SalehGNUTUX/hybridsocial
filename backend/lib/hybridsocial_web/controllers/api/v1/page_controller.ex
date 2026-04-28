defmodule HybridsocialWeb.Api.V1.PageController do
  use HybridsocialWeb, :controller

  alias Hybridsocial.Pages
  alias Hybridsocial.Social
  import HybridsocialWeb.Helpers.Pagination, only: [clamp_limit: 1]
  import Ecto.Query, only: [where: 3, order_by: 3, limit: 2]

  # ---------------------------------------------------------------------------
  # Page CRUD
  # ---------------------------------------------------------------------------

  @doc "POST /api/v1/pages"
  def create(conn, params) do
    identity = conn.assigns.current_identity

    case Pages.create_page(identity.id, params) do
      {:ok, page} ->
        conn
        |> put_status(:created)
        |> json(serialize_page(page))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  @doc "GET /api/v1/pages"
  def index(conn, params) do
    opts = [
      limit: clamp_limit(params["limit"]),
      offset: to_integer(params["offset"], 0)
    ]

    pages = Pages.list_pages(opts)
    json(conn, Enum.map(pages, &serialize_page/1))
  end

  @doc "GET /api/v1/pages/:id"
  def show(conn, %{"id" => id}) do
    case Pages.get_page(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "page.not_found"})

      page ->
        branding = Pages.get_branding(id)
        viewer_id = viewer_identity_id(conn)
        json(conn, serialize_page(page, branding, viewer_id))
    end
  end

  # ---------------------------------------------------------------------------
  # Follow / unfollow — pages are Identity rows, so the same Follow
  # plumbing that powers /api/v1/accounts/:id/follow works here. We
  # expose a page-shaped endpoint so the frontend's /api/v1/pages/:id
  # surface stays self-contained instead of forcing it to know that a
  # page id is also a follow target.
  # ---------------------------------------------------------------------------

  @doc "POST /api/v1/pages/:id/follow"
  def follow(conn, %{"id" => id}) do
    identity = conn.assigns.current_identity

    case Pages.get_page(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "page.not_found"})

      _page ->
        case Social.follow(identity.id, id) do
          {:ok, follow} ->
            json(conn, %{
              id: id,
              following: follow.status == :accepted,
              requested: follow.status == :pending
            })

          {:error, :cannot_follow_self} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "social.cannot_follow_self"})

          {:error, :blocked} ->
            conn |> put_status(:forbidden) |> json(%{error: "social.blocked"})

          {:error, :not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "page.not_found"})

          {:error, _changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "validation.failed"})
        end
    end
  end

  @doc "POST /api/v1/pages/:id/unfollow"
  def unfollow(conn, %{"id" => id}) do
    identity = conn.assigns.current_identity
    :ok = Social.unfollow(identity.id, id)
    json(conn, %{id: id, following: false})
  end

  @doc """
  GET /api/v1/pages/:id/statuses

  Returns posts authored to this page, newest first. Mirrors the
  shape of /api/v1/timelines/list/:id (PaginatedResponse<Post>) so
  the frontend FeedList can render it without a special case.
  """
  def statuses(conn, %{"id" => id} = params) do
    case Pages.get_page(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "page.not_found"})

      _page ->
        viewer_id =
          case conn.assigns[:current_identity] do
            %{id: vid} -> vid
            _ -> nil
          end

        limit = clamp_limit(params["limit"])
        cursor = params["cursor"] || params["max_id"]

        posts =
          Hybridsocial.Social.Post
          |> where([p], p.page_id == ^id)
          |> where([p], is_nil(p.deleted_at))
          |> where([p], is_nil(p.hidden_at))
          |> maybe_apply_cursor(cursor)
          |> order_by([p], desc: p.inserted_at)
          |> limit(^limit)
          |> Hybridsocial.Repo.all()
          # PostSerializer reads `post.identity.show_badge` etc.; an
          # unpreloaded :identity here crashes serialize_many. Match
          # the preloads other timeline queries do.
          |> Hybridsocial.Repo.preload([:identity, :quote])

        serialized =
          HybridsocialWeb.Serializers.PostSerializer.serialize_many(posts,
            current_identity_id: viewer_id
          )

        next_cursor =
          case List.last(posts) do
            nil -> nil
            last -> last.id
          end

        json(conn, %{data: serialized, next_cursor: next_cursor, prev_cursor: nil})
    end
  end

  defp maybe_apply_cursor(query, nil), do: query

  defp maybe_apply_cursor(query, cursor) when is_binary(cursor) do
    case Hybridsocial.Repo.get(Hybridsocial.Social.Post, cursor) do
      %{inserted_at: ts} -> where(query, [p], p.inserted_at < ^ts)
      _ -> query
    end
  end

  @doc "PATCH /api/v1/pages/:id"
  def update(conn, %{"id" => id} = params) do
    identity = conn.assigns.current_identity

    case Pages.update_page(id, identity.id, params) do
      {:ok, page} ->
        json(conn, serialize_page(page))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "page.not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "page.forbidden"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  @doc "DELETE /api/v1/pages/:id"
  def delete(conn, %{"id" => id}) do
    identity = conn.assigns.current_identity

    case Pages.delete_page(id, identity.id) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "page.not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "page.forbidden"})
    end
  end

  # ---------------------------------------------------------------------------
  # Roles
  # ---------------------------------------------------------------------------

  @doc "GET /api/v1/pages/:id/roles"
  def roles(conn, %{"id" => id}) do
    roles = Pages.get_roles(id)
    json(conn, Enum.map(roles, &serialize_role/1))
  end

  @doc "POST /api/v1/pages/:id/roles"
  def add_role(conn, %{"id" => id} = params) do
    identity = conn.assigns.current_identity
    target_id = params["identity_id"]
    role = params["role"]

    case Pages.add_role(id, identity.id, target_id, role) do
      {:ok, org_role} ->
        conn
        |> put_status(:created)
        |> json(serialize_role(org_role))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "page.not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "page.forbidden"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  @doc "DELETE /api/v1/pages/:id/roles/:role_id"
  def remove_role(conn, %{"id" => id, "role_id" => role_id}) do
    identity = conn.assigns.current_identity

    case Pages.remove_role(id, identity.id, role_id) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "role.not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "page.forbidden"})
    end
  end

  # ---------------------------------------------------------------------------
  # Branding
  # ---------------------------------------------------------------------------

  @doc "GET /api/v1/pages/:id/branding"
  def branding(conn, %{"id" => id}) do
    case Pages.get_branding(id) do
      nil ->
        json(conn, %{
          identity_id: id,
          theme_color: nil,
          cover_image_url: nil,
          custom_css: nil,
          logo_url: nil,
          layout_preference: %{}
        })

      branding ->
        json(conn, serialize_branding(branding))
    end
  end

  @doc "PATCH /api/v1/pages/:id/branding"
  def update_branding(conn, %{"id" => id} = params) do
    identity = conn.assigns.current_identity

    attrs =
      Map.take(params, [
        "theme_color",
        "cover_image_url",
        "logo_url",
        "layout_preference"
      ])

    case Pages.update_branding(id, identity.id, attrs) do
      {:ok, branding} ->
        json(conn, serialize_branding(branding))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "page.not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "page.forbidden"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  # ---------------------------------------------------------------------------
  # Manager invites (mirror of Groups.invite flow)
  # ---------------------------------------------------------------------------

  @doc "POST /api/v1/pages/:id/invite — inviter must be owner / admin / editor."
  def invite(conn, %{"id" => id} = params) do
    identity = conn.assigns.current_identity
    invited_id = params["invited_id"]

    case Pages.invite_to_page(id, identity.id, invited_id) do
      {:ok, invite} ->
        conn |> put_status(:created) |> json(serialize_invite(invite))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "page.not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "page.forbidden"})

      {:error, :invites_disabled} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "invite.disabled_by_recipient"})

      {:error, :invites_restricted} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "invite.recipient_follows_only"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  @doc "GET /api/v1/pages/invites — pending invites addressed to me."
  def my_invites(conn, _params) do
    identity = conn.assigns.current_identity
    invites = Pages.pending_page_invites(identity.id)
    json(conn, Enum.map(invites, &serialize_invite/1))
  end

  @doc "POST /api/v1/pages/invites/:invite_id/accept"
  def accept_invite(conn, %{"invite_id" => invite_id}) do
    identity = conn.assigns.current_identity

    case Pages.accept_page_invite(invite_id, identity.id) do
      {:ok, invite} ->
        json(conn, serialize_invite(invite))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "invite.not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "invite.forbidden"})

      {:error, :already_resolved} ->
        conn |> put_status(:conflict) |> json(%{error: "invite.already_resolved"})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invite.accept_failed"})
    end
  end

  @doc "POST /api/v1/pages/invites/:invite_id/decline"
  def decline_invite(conn, %{"invite_id" => invite_id}) do
    identity = conn.assigns.current_identity

    case Pages.decline_page_invite(invite_id, identity.id) do
      {:ok, invite} ->
        json(conn, serialize_invite(invite))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "invite.not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "invite.forbidden"})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invite.decline_failed"})
    end
  end

  defp serialize_invite(invite) do
    %{
      id: invite.id,
      page_id: invite.page_id,
      invited_by: invite.invited_by,
      invited_id: invite.invited_id,
      status: invite.status,
      created_at: invite.inserted_at
    }
  end

  # ---------------------------------------------------------------------------
  # Serializers
  # ---------------------------------------------------------------------------

  defp serialize_page(page, branding \\ nil, viewer_id \\ nil) do
    base = %{
      id: page.id,
      type: page.type,
      handle: page.handle,
      display_name: page.display_name,
      bio: page.bio,
      avatar_url: page.avatar_url,
      header_url: page.header_url,
      is_locked: page.is_locked,
      is_bot: page.is_bot,
      created_at: page.inserted_at,
      followers_count: count_page_followers(page.id),
      is_following: viewer_follows_page?(viewer_id, page.id),
      organization: serialize_org(page.organization)
    }

    if branding do
      Map.put(base, :branding, serialize_branding(branding))
    else
      base
    end
  end

  defp count_page_followers(identity_id) do
    Hybridsocial.Social.Follow
    |> Ecto.Query.where([f], f.followee_id == ^identity_id and f.status == :accepted)
    |> Hybridsocial.Repo.aggregate(:count)
  end

  # Anonymous viewers can't follow, so skip the query for them.
  defp viewer_follows_page?(nil, _page_id), do: false

  defp viewer_follows_page?(viewer_id, page_id) do
    Hybridsocial.Social.Follow
    |> Ecto.Query.where(
      [f],
      f.follower_id == ^viewer_id and f.followee_id == ^page_id and
        f.status == :accepted
    )
    |> Hybridsocial.Repo.exists?()
  end

  defp viewer_identity_id(conn) do
    case conn.assigns[:current_identity] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp serialize_org(nil), do: nil

  defp serialize_org(org) do
    %{
      owner_id: org.owner_id,
      website: org.website,
      category: org.category
    }
  end

  defp serialize_role(role) do
    %{
      id: role.id,
      organization_id: role.organization_id,
      identity_id: role.identity_id,
      role: role.role,
      granted_by: role.granted_by,
      created_at: role.inserted_at
    }
  end

  defp serialize_branding(branding) do
    %{
      identity_id: branding.identity_id,
      theme_color: branding.theme_color,
      cover_image_url: branding.cover_image_url,
      logo_url: branding.logo_url,
      layout_preference: branding.layout_preference,
      updated_at: branding.updated_at
    }
  end

  defp to_integer(nil, default), do: default

  defp to_integer(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_integer(val, _default) when is_integer(val), do: val

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
