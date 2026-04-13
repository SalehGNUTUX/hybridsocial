defmodule Hybridsocial.Social.Stories do
  @moduledoc """
  Local-only ephemeral stories (Facebook/WhatsApp style).

  Visible to followers of the author plus the author themselves.
  Each story has a configurable lifetime (8/16/24 hours) and is hard-deleted
  by `Hybridsocial.Social.StoryExpiryWorker` once `expires_at` passes.
  """

  import Ecto.Query

  alias Hybridsocial.Repo
  alias Hybridsocial.Media
  alias Hybridsocial.Media.{MediaFile, Storage}
  alias Hybridsocial.Social.{Story, StoryView, StoryReaction, Follow}

  require Logger

  # ----------------------------------------------------------------------
  # Create
  # ----------------------------------------------------------------------

  @doc """
  Creates a story for the given identity. The media must belong to the same
  identity. Returns `{:ok, story}` or `{:error, changeset | reason}`.
  """
  def create_story(identity_id, attrs) do
    with {:ok, media_id} <- fetch_media_id(attrs),
         %MediaFile{identity_id: ^identity_id} <- Media.get_media(media_id) do
      %Story{}
      |> Story.create_changeset(
        attrs
        |> normalize_attrs()
        |> Map.put(:identity_id, identity_id)
      )
      |> Repo.insert()
      |> case do
        {:ok, story} -> {:ok, Repo.preload(story, [:identity, :media])}
        other -> other
      end
    else
      nil -> {:error, :media_not_found}
      %MediaFile{} -> {:error, :media_not_owned}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_media_id(%{media_id: id}) when is_binary(id), do: {:ok, id}
  defp fetch_media_id(%{"media_id" => id}) when is_binary(id), do: {:ok, id}
  defp fetch_media_id(_), do: {:error, :media_id_required}

  # Whitelist of allowed attribute keys. Never atomize unknown user input —
  # atoms aren't garbage collected, so attacker-controlled strings would be
  # a DoS vector.
  @allowed_attrs ~w(media_id caption duration_hours identity_id)
  @allowed_atoms Enum.map(@allowed_attrs, &String.to_atom/1)

  defp normalize_attrs(%{} = attrs) do
    attrs
    |> Enum.flat_map(fn
      {k, v} when is_binary(k) and k in @allowed_attrs ->
        [{String.to_existing_atom(k), v}]

      {k, v} when is_atom(k) and k in @allowed_atoms ->
        [{k, v}]

      _ ->
        []
    end)
    |> Map.new()
    |> coerce_duration()
  end

  defp coerce_duration(%{duration_hours: hours} = attrs) when is_binary(hours) do
    case Integer.parse(hours) do
      {n, _} -> %{attrs | duration_hours: n}
      :error -> attrs
    end
  end

  defp coerce_duration(attrs), do: attrs

  # ----------------------------------------------------------------------
  # Read: feed grouped by author
  # ----------------------------------------------------------------------

  @doc """
  Returns the story feed for `viewer_id`: an ordered list of `%{identity, stories}`
  groups, one per author. The viewer's own group is first (if any), then followed
  authors ordered by most-recent story first.
  """
  def feed_for_viewer(viewer_id) do
    now = DateTime.utc_now()

    followed_ids =
      Follow
      |> where([f], f.follower_id == ^viewer_id and f.status == :accepted)
      |> select([f], f.followee_id)
      |> Repo.all()

    author_ids = [viewer_id | followed_ids] |> Enum.uniq()

    stories =
      Story
      |> where([s], s.identity_id in ^author_ids)
      |> where([s], s.expires_at > ^now)
      |> order_by([s], asc: s.published_at)
      |> preload([:identity, :media])
      |> Repo.all()

    viewed_ids = viewed_story_ids(viewer_id, Enum.map(stories, & &1.id))

    stories
    |> Enum.group_by(& &1.identity_id)
    |> Enum.map(fn {identity_id, group_stories} ->
      identity = hd(group_stories).identity

      %{
        identity: identity,
        stories: Enum.map(group_stories, &serialize(&1, viewer_id, viewed_ids)),
        all_viewed: Enum.all?(group_stories, &MapSet.member?(viewed_ids, &1.id)),
        is_self: identity_id == viewer_id
      }
    end)
    |> Enum.sort_by(fn group ->
      # Self first, then unviewed first, then most recent
      latest = group.stories |> Enum.map(& &1.published_at) |> Enum.max(DateTime)

      {
        if(group.is_self, do: 0, else: 1),
        if(group.all_viewed, do: 1, else: 0),
        -DateTime.to_unix(latest, :microsecond)
      }
    end)
  end

  defp viewed_story_ids(_viewer_id, []), do: MapSet.new()

  defp viewed_story_ids(viewer_id, story_ids) do
    StoryView
    |> where([v], v.viewer_id == ^viewer_id and v.story_id in ^story_ids)
    |> select([v], v.story_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # ----------------------------------------------------------------------
  # Read: single story (with viewer permission check)
  # ----------------------------------------------------------------------

  @doc """
  Fetches a single story if `viewer_id` is allowed to see it (author or follower).
  """
  def get_story_for_viewer(story_id, viewer_id) do
    case get_active_story(story_id) do
      nil ->
        {:error, :not_found}

      %Story{} = story ->
        if can_view?(story, viewer_id) do
          {:ok, story}
        else
          {:error, :forbidden}
        end
    end
  end

  defp get_active_story(story_id) do
    now = DateTime.utc_now()

    Story
    |> where([s], s.id == ^story_id and s.expires_at > ^now)
    |> preload([:identity, :media])
    |> Repo.one()
  end

  defp can_view?(%Story{identity_id: id}, viewer_id) when id == viewer_id, do: true

  defp can_view?(%Story{identity_id: author_id}, viewer_id) do
    Repo.exists?(
      from f in Follow,
        where:
          f.follower_id == ^viewer_id and
            f.followee_id == ^author_id and
            f.status == :accepted
    )
  end

  # ----------------------------------------------------------------------
  # Views (read receipts)
  # ----------------------------------------------------------------------

  @doc """
  Records that `viewer_id` saw the story. No-op if the viewer is the author or
  has already viewed it. Increments `view_count` on first insert.
  """
  def record_view(story_id, viewer_id) do
    with {:ok, story} <- get_story_for_viewer(story_id, viewer_id) do
      if story.identity_id == viewer_id do
        {:ok, :self}
      else
        case insert_view(story_id, viewer_id) do
          {:ok, _view} ->
            Repo.update_all(
              from(s in Story, where: s.id == ^story_id),
              inc: [view_count: 1]
            )

            {:ok, :recorded}

          {:error, %Ecto.Changeset{}} ->
            # Unique constraint — already viewed
            {:ok, :already_viewed}
        end
      end
    end
  end

  defp insert_view(story_id, viewer_id) do
    %StoryView{}
    |> StoryView.changeset(%{story_id: story_id, viewer_id: viewer_id})
    |> Repo.insert()
  end

  @doc """
  Lists viewers of a story. Only the story author may call this.
  """
  def list_viewers(story_id, requester_id) do
    case Repo.get(Story, story_id) do
      nil ->
        {:error, :not_found}

      %Story{identity_id: ^requester_id} ->
        viewers =
          StoryView
          |> where([v], v.story_id == ^story_id)
          |> order_by([v], desc: v.viewed_at)
          |> preload(:viewer)
          |> Repo.all()

        {:ok, viewers}

      _ ->
        {:error, :forbidden}
    end
  end

  # ----------------------------------------------------------------------
  # Reactions
  # ----------------------------------------------------------------------

  @doc """
  Adds (or replaces) a reaction from `identity_id` on `story_id`.
  """
  def react(story_id, identity_id, emoji) do
    with {:ok, _story} <- get_story_for_viewer(story_id, identity_id) do
      Repo.transaction(fn ->
        existing =
          Repo.one(
            from r in StoryReaction,
              where: r.story_id == ^story_id and r.identity_id == ^identity_id
          )

        result =
          case existing do
            nil ->
              with {:ok, reaction} <-
                     %StoryReaction{}
                     |> StoryReaction.changeset(%{
                       story_id: story_id,
                       identity_id: identity_id,
                       emoji: emoji
                     })
                     |> Repo.insert() do
                Repo.update_all(
                  from(s in Story, where: s.id == ^story_id),
                  inc: [reaction_count: 1]
                )

                {:ok, reaction}
              end

            %StoryReaction{} = reaction ->
              reaction
              |> StoryReaction.changeset(%{emoji: emoji})
              |> Repo.update()
          end

        case result do
          {:ok, reaction} -> reaction
          {:error, cs} -> Repo.rollback(cs)
        end
      end)
    end
  end

  @doc """
  Removes the caller's reaction on a story. Returns `:ok` either way.
  """
  def unreact(story_id, identity_id) do
    {count, _} =
      Repo.delete_all(
        from r in StoryReaction,
          where: r.story_id == ^story_id and r.identity_id == ^identity_id
      )

    if count > 0 do
      Repo.update_all(
        from(s in Story, where: s.id == ^story_id and s.reaction_count > 0),
        inc: [reaction_count: -count]
      )
    end

    :ok
  end

  # ----------------------------------------------------------------------
  # Delete (manual + expiry)
  # ----------------------------------------------------------------------

  @doc """
  Hard-deletes a story owned by `identity_id`. Also removes its media file.
  """
  def delete_story(story_id, identity_id) do
    case Repo.get(Story, story_id) do
      nil ->
        {:error, :not_found}

      %Story{identity_id: ^identity_id} = story ->
        do_hard_delete(story)
        {:ok, story}

      _ ->
        {:error, :forbidden}
    end
  end

  @doc """
  Hard-deletes every story whose `expires_at` is in the past, including their
  associated media records and stored files. Returns the number deleted.
  """
  def delete_expired do
    now = DateTime.utc_now()

    expired =
      Story
      |> where([s], s.expires_at <= ^now)
      |> preload(:media)
      |> Repo.all()

    Enum.each(expired, &do_hard_delete/1)

    length(expired)
  end

  defp do_hard_delete(%Story{} = story) do
    story = if story.media, do: story, else: Repo.preload(story, :media)

    Repo.delete(story)

    case story.media do
      %MediaFile{storage_path: path} = media ->
        case Storage.delete(path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Stories: failed to delete media file #{path} for story #{story.id}: #{inspect(reason)}"
            )
        end

        Repo.delete(media)

      _ ->
        :ok
    end
  end

  # ----------------------------------------------------------------------
  # Serialization
  # ----------------------------------------------------------------------

  @doc """
  Serializes a story to a plain map for JSON encoding. Includes the viewer's
  reaction (if any) and whether the viewer has seen it.
  """
  def serialize(%Story{} = story, viewer_id, viewed_set \\ nil) do
    viewed_set = viewed_set || viewed_story_ids(viewer_id, [story.id])
    user_reaction = get_user_reaction(story.id, viewer_id)

    %{
      id: story.id,
      identity_id: story.identity_id,
      caption: story.caption,
      duration_hours: story.duration_hours,
      view_count: story.view_count,
      reaction_count: story.reaction_count,
      published_at: story.published_at,
      expires_at: story.expires_at,
      media: serialize_media(story.media),
      viewed: MapSet.member?(viewed_set, story.id),
      user_reaction: user_reaction,
      is_own: story.identity_id == viewer_id
    }
  end

  defp serialize_media(%MediaFile{} = media) do
    %{
      id: media.id,
      content_type: media.content_type,
      url: Media.media_url(media),
      width: media.width,
      height: media.height,
      duration: media.duration,
      blurhash: media.blurhash
    }
  end

  defp serialize_media(_), do: nil

  defp get_user_reaction(story_id, identity_id) do
    Repo.one(
      from r in StoryReaction,
        where: r.story_id == ^story_id and r.identity_id == ^identity_id,
        select: r.emoji
    )
  end
end
