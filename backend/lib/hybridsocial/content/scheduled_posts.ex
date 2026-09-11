defmodule Hybridsocial.Content.ScheduledPosts do
  @moduledoc """
  Context module for managing scheduled posts.
  """
  import Ecto.Query
  require Logger
  alias Hybridsocial.Repo
  alias Hybridsocial.Social.Post

  @doc """
  Schedules a post for future publishing.
  Creates a post with scheduled_at in the future and published_at = nil.
  """
  def schedule_post(identity_id, attrs) do
    scheduled_at = Map.get(attrs, "scheduled_at")

    with {:ok, parsed_time} <- parse_scheduled_at(scheduled_at),
         :ok <- validate_future(parsed_time) do
      post_attrs =
        attrs
        |> Map.put("scheduled_at", parsed_time)

      # Route through the standard create path so scheduled posts
      # get the same ap_id, mention persistence, hashtag indexing
      # and poll creation as any other post. `create_post` notices
      # `scheduled_at` in the future and skips only the side
      # effects that make the post "live" (federation + direct-post
      # broadcast); the worker fires those at publish time.
      Hybridsocial.Social.Posts.create_post(identity_id, post_attrs)
    end
  end

  @doc """
  Lists a user's scheduled (unpublished) posts.
  """
  def get_scheduled_posts(identity_id) do
    Post
    |> where([p], p.identity_id == ^identity_id)
    |> where([p], not is_nil(p.scheduled_at))
    |> where([p], is_nil(p.published_at))
    |> where([p], is_nil(p.deleted_at))
    |> order_by([p], asc: p.scheduled_at)
    |> Repo.all()
  end

  @doc """
  Cancels (deletes) a scheduled post.
  """
  def cancel_scheduled_post(post_id, identity_id) do
    with {:ok, post} <- get_owned_scheduled_post(post_id, identity_id) do
      Repo.delete(post)
    end
  end

  @doc """
  Updates a scheduled post before it's published.
  """
  def update_scheduled_post(post_id, identity_id, attrs) do
    with {:ok, post} <- get_owned_scheduled_post(post_id, identity_id) do
      scheduled_at = Map.get(attrs, "scheduled_at")

      changeset =
        post
        |> Ecto.Changeset.cast(attrs, [:content, :visibility, :sensitive, :spoiler_text])
        |> Ecto.Changeset.validate_required([:content])
        |> Ecto.Changeset.validate_length(:content, max: 10_000)

      changeset =
        if scheduled_at do
          case parse_scheduled_at(scheduled_at) do
            {:ok, parsed_time} ->
              case validate_future(parsed_time) do
                :ok -> Ecto.Changeset.put_change(changeset, :scheduled_at, parsed_time)
                {:error, reason} -> Ecto.Changeset.add_error(changeset, :scheduled_at, reason)
              end

            {:error, _} ->
              Ecto.Changeset.add_error(changeset, :scheduled_at, "invalid format")
          end
        else
          changeset
        end

      Repo.update(changeset)
    end
  end

  @doc """
  Publishes all posts whose scheduled_at time has passed. Each post
  goes through the same side-effect chain as a fresh create:
  federation fan-out, mention persistence, notifications, and the
  direct-post realtime broadcast. The bulk `update_all` that used
  to live here flipped `published_at` but left every downstream
  action un-fired — scheduled direct posts never reached their
  recipients and mention notifications never arrived.
  """
  def publish_due_posts do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    due_posts =
      Post
      |> where([p], not is_nil(p.scheduled_at))
      |> where([p], p.scheduled_at <= ^now)
      |> where([p], is_nil(p.published_at))
      |> where([p], is_nil(p.deleted_at))
      |> Repo.all()

    {publishable, held} = Enum.split_with(due_posts, &group_post_still_allowed?/1)

    if held != [] do
      Logger.info(
        "Scheduled publish: held back #{length(held)} group post(s) — " <>
          "author no longer permitted to post in the target group"
      )
    end

    Enum.each(publishable, fn post ->
      case post |> Post.publish_changeset(now) |> Repo.update() do
        {:ok, published} ->
          Hybridsocial.Social.Posts.run_post_published_hooks(published)

        {:error, reason} ->
          Logger.warning("Scheduled publish failed for #{post.id}: #{inspect(reason)}")
      end
    end)

    length(publishable)
  end

  # The group check in `Posts.create_post/3` runs when the post is *scheduled*.
  # Between then and the publish tick the author can be banned, can leave, or
  # the group can be deleted — so it has to be re-evaluated here, or a ban is
  # trivially outlived by anything queued before it.
  #
  # Held back rather than deleted or stripped of its group: the author keeps
  # their content, nothing is silently re-addressed to a different audience,
  # and if the ban is lifted the post publishes on a later tick. A permanently
  # banned author's post simply stays in their scheduled list, where they can
  # delete it themselves.
  defp group_post_still_allowed?(%Post{group_id: group_id, identity_id: identity_id})
       when is_binary(group_id) do
    Hybridsocial.Groups.can_post_in?(group_id, identity_id)
  end

  defp group_post_still_allowed?(_post), do: true

  # --- Private helpers ---

  defp get_owned_scheduled_post(post_id, identity_id) do
    Post
    |> where([p], not is_nil(p.scheduled_at))
    |> where([p], is_nil(p.published_at))
    |> where([p], is_nil(p.deleted_at))
    |> Repo.get(post_id)
    |> case do
      nil -> {:error, :not_found}
      %Post{identity_id: ^identity_id} = post -> {:ok, post}
      _post -> {:error, :forbidden}
    end
  end

  defp parse_scheduled_at(nil), do: {:error, "scheduled_at is required"}

  defp parse_scheduled_at(%DateTime{} = dt), do: {:ok, DateTime.truncate(dt, :microsecond)}

  defp parse_scheduled_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :microsecond)}
      {:error, _} -> {:error, "invalid format"}
    end
  end

  defp parse_scheduled_at(_), do: {:error, "invalid format"}

  defp validate_future(dt) do
    if DateTime.compare(dt, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, "must be in the future"}
    end
  end
end
