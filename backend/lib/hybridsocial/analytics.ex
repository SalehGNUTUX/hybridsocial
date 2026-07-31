defmodule Hybridsocial.Analytics do
  @moduledoc """
  Analytics data for admin charts — user growth, post volume, federation activity,
  storage usage, engagement metrics. All queries are time-bucketed by day.
  """

  import Ecto.Query
  alias Hybridsocial.Repo

  @doc "User registrations per day for the last N days."
  def user_growth(days \\ 30) do
    cutoff = Date.add(Date.utc_today(), -days)

    from(u in "users",
      where: fragment("?::date >= ?", u.inserted_at, ^cutoff),
      group_by: fragment("?::date", u.inserted_at),
      select: %{date: fragment("?::date", u.inserted_at), count: count(u.identity_id)},
      order_by: fragment("?::date", u.inserted_at)
    )
    |> Repo.all()
  end

  # Posts live in one table regardless of origin — federation writes every
  # ingested remote post there too. On a well-connected instance the remote
  # rows outnumber local ones ~100:1, so an unscoped count answers "how busy
  # is the fediverse", not "how busy is this instance". Every admin-facing
  # metric therefore has to say which one it means.
  defp posts_scoped(cutoff, local?) do
    from(p in "posts",
      join: i in "identities",
      on: i.id == p.identity_id,
      where:
        fragment("?::date >= ?", p.inserted_at, ^cutoff) and is_nil(p.deleted_at) and
          i.is_local == ^local?
    )
  end

  @doc """
  Posts authored on THIS instance per day, for the last N days.

  Federated posts are excluded — see `federated_post_volume/1` for those.
  """
  def post_volume(days \\ 30) do
    cutoff = Date.add(Date.utc_today(), -days)

    posts_scoped(cutoff, true)
    |> group_by([p], fragment("?::date", p.inserted_at))
    |> select([p], %{date: fragment("?::date", p.inserted_at), count: count(p.id)})
    |> order_by([p], fragment("?::date", p.inserted_at))
    |> Repo.all()
  end

  @doc """
  Remote posts ingested from other instances per day, for the last N days.

  Bucketed by `inserted_at` — when we received it, not when the author
  published it — so a backfill shows up on the day it ran.
  """
  def federated_post_volume(days \\ 30) do
    cutoff = Date.add(Date.utc_today(), -days)

    posts_scoped(cutoff, false)
    |> group_by([p], fragment("?::date", p.inserted_at))
    |> select([p], %{date: fragment("?::date", p.inserted_at), count: count(p.id)})
    |> order_by([p], fragment("?::date", p.inserted_at))
    |> Repo.all()
  end

  @doc """
  Local accounts that posted, per day, for the last N days.

  Each day is a distinct count for that day alone. Summing these does NOT
  give the number of people active over the window — someone who posted on
  ten days is in ten buckets. Use `active_users_distinct/1` for the total.
  """
  def active_users(days \\ 30) do
    cutoff = Date.add(Date.utc_today(), -days)

    posts_scoped(cutoff, true)
    |> group_by([p], fragment("?::date", p.inserted_at))
    |> select([p], %{
      date: fragment("?::date", p.inserted_at),
      count: count(p.identity_id, :distinct)
    })
    |> order_by([p], fragment("?::date", p.inserted_at))
    |> Repo.all()
  end

  @doc """
  How many distinct local accounts posted at least once across the whole
  window — the honest headline figure for `active_users/1`.
  """
  def active_users_distinct(days \\ 30) do
    cutoff = Date.add(Date.utc_today(), -days)

    posts_scoped(cutoff, true)
    |> select([p], count(p.identity_id, :distinct))
    |> Repo.one() || 0
  end

  @doc "Reactions per day."
  def reactions_per_day(days \\ 30) do
    cutoff = Date.add(Date.utc_today(), -days)

    from(r in "reactions",
      where: fragment("?::date >= ?", r.inserted_at, ^cutoff),
      group_by: fragment("?::date", r.inserted_at),
      select: %{date: fragment("?::date", r.inserted_at), count: count(r.id)},
      order_by: fragment("?::date", r.inserted_at)
    )
    |> Repo.all()
  end

  @doc "New follows per day."
  def follows_per_day(days \\ 30) do
    cutoff = Date.add(Date.utc_today(), -days)

    from(f in "follows",
      where: fragment("?::date >= ?", f.inserted_at, ^cutoff),
      group_by: fragment("?::date", f.inserted_at),
      select: %{date: fragment("?::date", f.inserted_at), count: count(f.id)},
      order_by: fragment("?::date", f.inserted_at)
    )
    |> Repo.all()
  end

  @doc "Storage usage summary."
  def storage_stats do
    media =
      from(m in "media", select: %{count: count(m.id), total_bytes: sum(m.file_size)})
      |> Repo.one()

    %{
      media_count: media[:count] || 0,
      total_bytes: media[:total_bytes] || 0
    }
  end

  @doc "Federation stats — remote actors cached."
  def federation_stats do
    remote_actors = from(ra in "remote_actors", select: count(ra.id)) |> Repo.one() || 0

    # Local identities also carry an `ap_actor_url` (it's how peers address
    # them), so presence of that column says nothing about origin — this
    # counted every local account as remote too. `is_local` is the marker.
    remote_identities =
      from(i in "identities", where: i.is_local == false, select: count(i.id))
      |> Repo.one() || 0

    %{
      remote_actors: remote_actors,
      remote_identities: remote_identities
    }
  end

  @doc "Summary stats for the dashboard."
  def summary do
    total_users = from(u in "users", select: count(u.identity_id)) |> Repo.one() || 0

    # Local posts only — this card sits next to "Total Users" (local) and a
    # separate "Remote Users", so a blended figure here read as ours.
    total_posts =
      from(p in "posts",
        join: i in "identities",
        on: i.id == p.identity_id,
        where: is_nil(p.deleted_at) and i.is_local == true,
        select: count(p.id)
      )
      |> Repo.one() || 0

    federated_posts =
      from(p in "posts",
        join: i in "identities",
        on: i.id == p.identity_id,
        where: is_nil(p.deleted_at) and i.is_local == false,
        select: count(p.id)
      )
      |> Repo.one() || 0

    total_reactions = from(r in "reactions", select: count(r.id)) |> Repo.one() || 0

    today = Date.utc_today()

    posts_today =
      from(p in "posts",
        join: i in "identities",
        on: i.id == p.identity_id,
        where:
          fragment("?::date = ?", p.inserted_at, ^today) and is_nil(p.deleted_at) and
            i.is_local == true,
        select: count(p.id)
      )
      |> Repo.one() || 0

    registrations_today =
      from(u in "users",
        where: fragment("?::date = ?", u.inserted_at, ^today),
        select: count(u.identity_id)
      )
      |> Repo.one() || 0

    %{
      total_users: total_users,
      total_posts: total_posts,
      federated_posts: federated_posts,
      total_reactions: total_reactions,
      posts_today: posts_today,
      registrations_today: registrations_today,
      storage: storage_stats(),
      federation: federation_stats()
    }
  end
end
