defmodule Hybridsocial.Social.Streams do
  @moduledoc """
  Context for video stream (reels) view tracking and streams feed.
  """
  import Ecto.Query

  alias Hybridsocial.Accounts.Identity
  alias Hybridsocial.Repo
  alias Hybridsocial.Social.{StreamView, Post}

  @default_limit 20
  @max_limit 40

  @doc """
  Records a view event for a video stream post.
  """
  def record_view(post_id, identity_id, attrs) do
    %StreamView{}
    |> StreamView.changeset(
      Map.merge(attrs, %{
        "post_id" => post_id,
        "identity_id" => identity_id
      })
    )
    |> Repo.insert()
  end

  @doc """
  Returns view statistics for a given post.

  Returns a map with:
    - total_views
    - unique_viewers
    - avg_watch_duration
    - completion_rate
    - replay_rate
  """
  def get_view_stats(post_id) do
    query =
      StreamView
      |> where([sv], sv.post_id == ^post_id)

    total_views = Repo.aggregate(query, :count)

    if total_views == 0 do
      %{
        total_views: 0,
        unique_viewers: 0,
        avg_watch_duration: 0.0,
        completion_rate: 0.0,
        replay_rate: 0.0
      }
    else
      unique_viewers =
        query
        |> where([sv], not is_nil(sv.identity_id))
        |> select([sv], count(sv.identity_id, :distinct))
        |> Repo.one()

      avg_watch_duration =
        query
        |> select([sv], avg(sv.watch_duration))
        |> Repo.one() || 0.0

      completed_count =
        query
        |> where([sv], sv.completed == true)
        |> Repo.aggregate(:count)

      replayed_count =
        query
        |> where([sv], sv.replayed == true)
        |> Repo.aggregate(:count)

      %{
        total_views: total_views,
        unique_viewers: unique_viewers,
        avg_watch_duration: avg_watch_duration |> to_float(),
        completion_rate: to_float(completed_count / total_views * 100),
        replay_rate: to_float(replayed_count / total_views * 100)
      }
    end
  end

  @doc """
  Returns the video streams feed: any public post carrying a qualifying
  video attachment, ordered by engagement (reaction_count) then recency,
  cursor paginated.
  """
  def streams_feed(_viewer_id, opts \\ []) do
    limit = parse_limit(opts)
    min_duration = Keyword.get(opts, :min_duration_seconds, 15.0)
    search = normalize_search(Keyword.get(opts, :q))

    # Streams surfaces public video to everyone, including signed-out
    # viewers. Membership is defined by "a LOCAL author posted a public
    # post carrying a qualifying VERTICAL video". Excludes:
    #   - remote/federated authors — streams is our own local video feed
    #     (join Identity + is_local == true). See issue #22.
    #   - sensitive (NSFW) posts
    #   - posts with a content warning (spoiler_text)
    #   - non-portrait video: only height > width (strictly vertical) is
    #     eligible; horizontal AND square clips are excluded. Videos whose
    #     dimensions weren't captured (NULL width/height) are excluded too,
    #     since we can't prove they're vertical.
    #   - posts whose video attachment is shorter than `min_duration`
    #     seconds (default 15) — the format is meant for short *clips*,
    #     not micro-bursts that flash by before the page can render the
    #     next one.
    # The video predicate joins the media table (duration + dimensions
    # live there per-attachment); the EXISTS form keeps the join from
    # multiplying rows on posts with multiple media.
    query =
      Post
      |> join(:inner, [p], i in Identity, on: i.id == p.identity_id)
      |> where([p], p.visibility == "public")
      |> where([p], is_nil(p.deleted_at))
      |> where([p], p.sensitive == false)
      |> where([p], is_nil(p.spoiler_text) or p.spoiler_text == "")
      |> where([_p, i], i.is_local == true)
      |> where(
        [p],
        fragment(
          "EXISTS (SELECT 1 FROM media m WHERE m.post_id = ? AND m.deleted_at IS NULL AND m.content_type LIKE 'video/%' AND m.width IS NOT NULL AND m.height IS NOT NULL AND m.height > m.width AND (m.duration IS NULL OR m.duration >= ?))",
          p.id,
          ^min_duration
        )
      )
      |> apply_search(search)
      |> apply_cursor_filters(opts)
      |> apply_sort(Keyword.get(opts, :sort))
      |> limit(^limit)
      |> preload(:identity)

    Repo.all(query)
  end

  # --- Private helpers ---

  defp parse_limit(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> min(@max_limit)
    |> max(1)
  end

  defp apply_cursor_filters(query, opts) do
    query
    |> maybe_max_id(Keyword.get(opts, :max_id))
    |> maybe_min_id(Keyword.get(opts, :min_id))
  end

  # Timeline ordering the viewer picks: trending (engagement-weighted, the
  # default), newest, or oldest.
  defp apply_sort(query, "newest"), do: order_by(query, [p], desc: p.inserted_at)
  defp apply_sort(query, "oldest"), do: order_by(query, [p], asc: p.inserted_at)

  defp apply_sort(query, _trending),
    do: order_by(query, [p], desc: p.reaction_count, desc: p.inserted_at)

  # Free-text filter over the post body. Hashtags live literally in the
  # content (e.g. "#gaza"), so a single case-insensitive match covers both
  # plain phrases and tag searches; user wildcards are escaped so `%`/`_`
  # are treated literally.
  defp normalize_search(q) when is_binary(q) do
    case String.trim(q) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_search(_), do: nil

  defp apply_search(query, nil), do: query

  defp apply_search(query, q) do
    pattern = "%" <> escape_like(q) <> "%"
    where(query, [p], ilike(p.content, ^pattern))
  end

  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # KNOWN LIMITATION: this id-based cursor (`p.id < max_id`) only orders
  # correctly when the sort correlates with the UUIDv4 primary key, which it
  # does NOT for `newest`/`oldest` (inserted_at) or `trending` (reaction_count).
  # It is latent today because the Streams UI loads a single page and never
  # passes max_id/min_id. Before wiring infinite scroll to any of these sorts,
  # replace this with a boundary-lookup + row-tuple compare on the sort key
  # (see the UUID cursor-pagination pattern used elsewhere).
  defp maybe_max_id(query, nil), do: query
  defp maybe_max_id(query, max_id), do: where(query, [p], p.id < ^max_id)

  defp maybe_min_id(query, nil), do: query
  defp maybe_min_id(query, min_id), do: where(query, [p], p.id > ^min_id)

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value / 1
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(_), do: 0.0
end
