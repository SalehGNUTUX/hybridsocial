defmodule Hybridsocial.Feeds.Algorithms.Chronological do
  @moduledoc """
  Chronological timeline algorithm.

  Returns posts from followed accounts and own posts in strict reverse-chronological
  order, merged with boosts from followed accounts. This is the default algorithm
  and does not apply any scoring or ranking.
  """
  @behaviour Hybridsocial.Feeds.TimelineAlgorithm

  import Ecto.Query

  alias Hybridsocial.Repo
  alias Hybridsocial.Social.{Post, Follow, Boost, FollowedTag}
  alias Hybridsocial.Feeds.Visibility
  alias Hybridsocial.Feeds

  @default_limit 20
  @max_limit 40

  @impl true
  def name, do: "chronological"

  @impl true
  def score_post(_post, _context), do: 0.0

  @impl true
  def home_feed(identity_id, opts) do
    limit = parse_limit(opts)

    # Subquery: IDs of accounts the viewer follows
    followed_ids =
      Follow
      |> where([f], f.follower_id == ^identity_id and f.status == :accepted)
      |> select([f], f.followee_id)

    # Followed hashtag IDs
    followed_tag_ids =
      FollowedTag
      |> where([ft], ft.identity_id == ^identity_id)
      |> select([ft], ft.hashtag_id)

    # Post IDs from followed hashtags
    tagged_post_ids =
      from(ph in "post_hashtags",
        where: ph.hashtag_id in subquery(followed_tag_ids),
        select: ph.post_id
      )

    # Original posts from followed accounts + own posts + followed tags
    posts_query =
      Post
      |> where(
        [p],
        p.identity_id in subquery(followed_ids) or
          p.identity_id == ^identity_id or
          p.id in subquery(tagged_post_ids)
      )
      |> where([p], is_nil(p.deleted_at))
      |> where([p], is_nil(p.parent_id))
      |> apply_cursor_filters(opts)
      |> Visibility.apply_block_filter(identity_id)
      |> Visibility.apply_mute_filter(identity_id)
      |> Visibility.apply_shadow_ban_filter(identity_id)
      # `id DESC` is the explicit tie-breaker for posts inserted in
      # the same instant; without it the row-tuple cursor below
      # couldn't deterministically pick a "next page" boundary.
      |> order_by([p], desc: p.inserted_at, desc: p.id)
      |> limit(^limit)
      |> preload([:identity, :quote])
      |> Repo.all()

    # Boosts from followed accounts
    boosts =
      Boost
      |> where([b], b.identity_id in subquery(followed_ids) or b.identity_id == ^identity_id)
      |> where([b], is_nil(b.deleted_at))
      |> join(:inner, [b], p in Post, on: b.post_id == p.id and is_nil(p.deleted_at))
      |> apply_boost_cursor_filters(opts)
      |> order_by([b], desc: b.inserted_at)
      |> limit(^limit)
      |> preload([b, p], post: {p, [:identity, :quote]})
      |> preload(:identity)
      |> Repo.all()

    # Merge posts and boosts, sort by inserted_at descending, take limit
    Feeds.merge_timeline_entries(posts_query, boosts)
    |> Enum.take(limit)
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
    |> maybe_since_id(Keyword.get(opts, :since_id))
  end

  defp maybe_max_id(query, nil), do: query

  # Row-tuple cursor: paginate strictly older than the boundary post
  # in (inserted_at DESC, id DESC) order. Plain `p.id < max_id` would
  # only work if UUIDs were time-ordered — they aren't, so it pulled
  # an arbitrary slice and the page either repeated rows or left
  # gaps. The lookup also resolves the boundary post first; if the
  # id doesn't exist (stale client cursor, boost id, …) we ignore
  # the cursor entirely instead of returning an empty page.
  defp maybe_max_id(query, max_id) do
    case lookup_post_cursor(max_id) do
      nil ->
        query

      {boundary_inserted_at, boundary_id} ->
        where(
          query,
          [p],
          fragment("(?, ?) < (?, ?)", p.inserted_at, p.id, ^boundary_inserted_at, ^boundary_id)
        )
    end
  end

  defp maybe_min_id(query, nil), do: query

  defp maybe_min_id(query, min_id) do
    case lookup_post_cursor(min_id) do
      nil ->
        query

      {boundary_inserted_at, boundary_id} ->
        where(
          query,
          [p],
          fragment("(?, ?) > (?, ?)", p.inserted_at, p.id, ^boundary_inserted_at, ^boundary_id)
        )
    end
  end

  defp maybe_since_id(query, nil), do: query

  defp maybe_since_id(query, since_id) do
    case lookup_post_cursor(since_id) do
      nil ->
        query

      {boundary_inserted_at, boundary_id} ->
        where(
          query,
          [p],
          fragment("(?, ?) > (?, ?)", p.inserted_at, p.id, ^boundary_inserted_at, ^boundary_id)
        )
    end
  end

  defp lookup_post_cursor(id) when is_binary(id) do
    case Repo.one(from p in Post, where: p.id == ^id, select: {p.inserted_at, p.id}) do
      nil -> nil
      {ia, pid} -> {ia, pid}
    end
  end

  defp lookup_post_cursor(_), do: nil

  defp apply_boost_cursor_filters(query, opts) do
    query
    |> maybe_boost_max_id(Keyword.get(opts, :max_id))
    |> maybe_boost_min_id(Keyword.get(opts, :min_id))
  end

  defp maybe_boost_max_id(query, nil), do: query
  defp maybe_boost_max_id(query, max_id), do: where(query, [b], b.id < ^max_id)

  defp maybe_boost_min_id(query, nil), do: query
  defp maybe_boost_min_id(query, min_id), do: where(query, [b], b.id > ^min_id)
end
