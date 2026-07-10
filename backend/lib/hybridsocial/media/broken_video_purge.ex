defmodule Hybridsocial.Media.BrokenVideoPurge do
  @moduledoc """
  One-off maintenance: hard-delete posts whose local video file is gone
  (returns 404 from R2). A bulk import created ~thousands of video posts
  whose media rows point at `media.bassam.social/<uuid>/<file>` keys that
  were never actually uploaded, so the posts are dead everywhere.

  SAFETY:
    - Verifies each candidate over the network first; a post is deleted
      ONLY when its file is a definitive 404. Timeouts / connection errors
      / any non-404 result are treated as "keep" so a transient blip can't
      delete a good post.
    - `dry_run: true` (the default) reports counts and deletes nothing.
    - Deletion is a real hard delete: removes the media rows and the posts
      (FKs cascade reactions/bookmarks/boosts/polls/mentions/stream_views;
      reply/quote references are SET NULL) and deindexes each from search.

      Hybridsocial.Media.BrokenVideoPurge.run(limit: 50)            # dry sample
      Hybridsocial.Media.BrokenVideoPurge.run()                     # dry, full
      Hybridsocial.Media.BrokenVideoPurge.run(dry_run: false)       # execute
  """

  import Ecto.Query
  require Logger

  alias Hybridsocial.Repo
  alias Hybridsocial.Media.MediaFile
  alias Hybridsocial.Search.Indexer
  alias Hybridsocial.Social.Post

  @host_prefix "https://media.bassam.social/%"

  def run(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, true)
    concurrency = Keyword.get(opts, :concurrency, 6)

    base =
      from(m in MediaFile,
        where:
          like(m.content_type, "video/%") and is_nil(m.deleted_at) and
            not is_nil(m.remote_url) and like(m.remote_url, @host_prefix),
        select: %{id: m.id, post_id: m.post_id, url: m.remote_url}
      )

    query = if lim = opts[:limit], do: limit(base, ^lim), else: base
    candidates = Repo.all(query)
    total = length(candidates)
    Logger.info("[purge] verifying #{total} local video files, dry_run=#{dry_run}")

    confirmed =
      candidates
      |> Task.async_stream(fn c -> {c, gone?(c.url)} end,
        max_concurrency: concurrency,
        timeout: 60_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce([], fn
        {:ok, {c, true}}, acc -> [c | acc]
        _, acc -> acc
      end)

    post_ids =
      confirmed |> Enum.map(& &1.post_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Logger.info(
      "[purge] confirmed 404: #{length(confirmed)} media across #{length(post_ids)} posts"
    )

    unless dry_run, do: delete_posts(post_ids)

    result = %{
      candidates: total,
      confirmed_404_media: length(confirmed),
      posts_affected: length(post_ids),
      deleted: not dry_run
    }

    Logger.info("[purge] DONE #{inspect(result)}")
    result
  end

  # Definitively gone only on an HTTP 404. A reachable file → keep. An
  # ambiguous result (timeout / rate-limit / connection error) is retried
  # a few times with backoff so CDN throttling doesn't misclassify a
  # genuinely-missing file; if it stays ambiguous we keep it (never delete
  # on uncertainty).
  defp gone?(url, attempts \\ 3) do
    case probe_status(url) do
      :not_found ->
        true

      :ok ->
        false

      :ambiguous when attempts > 1 ->
        Process.sleep(400)
        gone?(url, attempts - 1)

      :ambiguous ->
        false
    end
  end

  defp probe_status(url) do
    args = [
      "-v",
      "error",
      "-rw_timeout",
      "15000000",
      "-show_entries",
      "format=duration",
      "-of",
      "csv=p=0",
      url
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, _} -> if String.contains?(out, "404"), do: :not_found, else: :ambiguous
    end
  rescue
    _ -> :ambiguous
  end

  defp delete_posts(post_ids) do
    post_ids
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      # Use the schema modules (not string table names) so Ecto encodes
      # the binary_id UUIDs correctly. delete_all is a hard DELETE with no
      # callbacks; the DB-level FKs cascade/null the dependents.
      Repo.transaction(fn ->
        Repo.delete_all(from(m in MediaFile, where: m.post_id in ^chunk))
        Repo.delete_all(from(p in Post, where: p.id in ^chunk))
      end)

      Enum.each(chunk, fn id ->
        try do
          Indexer.remove_post(id)
        rescue
          _ -> :ok
        end
      end)

      Logger.info("[purge] hard-deleted #{length(chunk)} posts")
    end)
  end
end
