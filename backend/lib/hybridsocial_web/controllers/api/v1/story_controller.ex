defmodule HybridsocialWeb.Api.V1.StoryController do
  use HybridsocialWeb, :controller

  alias Hybridsocial.Social.Stories
  alias HybridsocialWeb.Serializers.PostSerializer

  @doc """
  GET /api/v1/stories — feed for the current viewer, grouped by author.
  """
  def index(conn, _params) do
    viewer = conn.assigns.current_identity
    groups = Stories.feed_for_viewer(viewer.id)

    rendered =
      Enum.map(groups, fn group ->
        %{
          identity: PostSerializer.serialize_account(group.identity, []),
          stories: group.stories,
          all_viewed: group.all_viewed,
          is_self: group.is_self
        }
      end)

    json(conn, %{groups: rendered})
  end

  @doc """
  POST /api/v1/stories — create a story.
  Body: { media_id, caption?, duration_hours (8|16|24) }
  """
  def create(conn, params) do
    identity = conn.assigns.current_identity

    case Stories.create_story(identity.id, params) do
      {:ok, story} ->
        conn
        |> put_status(:created)
        |> json(%{story: Stories.serialize(story, identity.id)})

      {:error, :media_id_required} ->
        send_error(conn, :unprocessable_entity, "story.media_required")

      {:error, :media_not_found} ->
        send_error(conn, :unprocessable_entity, "story.media_not_found")

      {:error, :media_not_owned} ->
        send_error(conn, :forbidden, "story.media_not_owned")

      {:error, {:stories_limit_reached, limit}} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "story.limit_reached",
          message:
            "You can only have #{limit} active #{if limit == 1, do: "story", else: "stories"} at a time on your tier.",
          limit: limit
        })

      {:error, %Ecto.Changeset{} = cs} ->
        send_validation_error(conn, cs)
    end
  end

  @doc """
  GET /api/v1/stories/:id — single story (viewer must be author or follower).
  """
  def show(conn, %{"id" => id}) do
    viewer = conn.assigns.current_identity

    case Stories.get_story_for_viewer(id, viewer.id) do
      {:ok, story} -> json(conn, %{story: Stories.serialize(story, viewer.id)})
      {:error, :not_found} -> send_error(conn, :not_found, "story.not_found")
      {:error, :forbidden} -> send_error(conn, :forbidden, "story.forbidden")
    end
  end

  @doc """
  POST /api/v1/stories/:id/view — record a view from the current user.
  """
  def view(conn, %{"id" => id}) do
    viewer = conn.assigns.current_identity

    case Stories.record_view(id, viewer.id) do
      {:ok, _} -> conn |> put_status(:no_content) |> send_resp(:no_content, "")
      {:error, :not_found} -> send_error(conn, :not_found, "story.not_found")
      {:error, :forbidden} -> send_error(conn, :forbidden, "story.forbidden")
    end
  end

  @doc """
  GET /api/v1/stories/:id/viewers — list viewers (author only).
  """
  def viewers(conn, %{"id" => id}) do
    requester = conn.assigns.current_identity

    case Stories.list_viewers(id, requester.id) do
      {:ok, views} ->
        rendered =
          Enum.map(views, fn v ->
            %{
              viewed_at: v.viewed_at,
              account: PostSerializer.serialize_account(v.viewer, [])
            }
          end)

        json(conn, %{viewers: rendered})

      {:error, :not_found} ->
        send_error(conn, :not_found, "story.not_found")

      {:error, :forbidden} ->
        send_error(conn, :forbidden, "story.forbidden")
    end
  end

  @doc """
  POST /api/v1/stories/:id/reactions — react with an emoji.
  Body: { emoji }
  """
  def react(conn, %{"id" => id} = params) do
    identity = conn.assigns.current_identity
    emoji = params["emoji"] || ""

    case Stories.react(id, identity.id, emoji) do
      {:ok, reaction} ->
        json(conn, %{reaction: %{emoji: reaction.emoji}})

      {:error, :not_found} ->
        send_error(conn, :not_found, "story.not_found")

      {:error, :forbidden} ->
        send_error(conn, :forbidden, "story.forbidden")

      {:error, %Ecto.Changeset{} = cs} ->
        send_validation_error(conn, cs)
    end
  end

  @doc """
  DELETE /api/v1/stories/:id/reactions — remove the caller's reaction.
  """
  def unreact(conn, %{"id" => id}) do
    identity = conn.assigns.current_identity
    :ok = Stories.unreact(id, identity.id)
    send_resp(conn, :no_content, "")
  end

  @doc """
  DELETE /api/v1/stories/:id — delete an own story (hard delete).
  """
  def delete(conn, %{"id" => id}) do
    identity = conn.assigns.current_identity

    case Stories.delete_story(id, identity.id) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> send_error(conn, :not_found, "story.not_found")
      {:error, :forbidden} -> send_error(conn, :forbidden, "story.forbidden")
    end
  end

  # --- helpers ---

  defp send_error(conn, status, code) do
    conn |> put_status(status) |> json(%{error: code})
  end

  defp send_validation_error(conn, changeset) do
    details =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "story.invalid", details: details})
  end
end
