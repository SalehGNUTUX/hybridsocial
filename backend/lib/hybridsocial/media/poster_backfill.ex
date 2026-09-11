defmodule Hybridsocial.Media.PosterBackfill do
  @moduledoc """
  One-off backfill of poster frames for videos uploaded before posters
  existed.

  `MediaFile.thumbnail_path` was declared, read by the serializer and cleaned
  up on delete, but nothing ever wrote it — so every video had a null
  `preview_url` and the media grid rendered a blank tile. Generation is now in
  the upload pipeline; this fills in everything already stored.

  Idempotent + resumable: only selects videos still missing a thumbnail, so a
  re-run continues where a prior run left off and re-running after a partial
  failure is safe.

      Hybridsocial.Media.PosterBackfill.run()              # everything
      Hybridsocial.Media.PosterBackfill.run(limit: 20)     # a test batch
      Hybridsocial.Media.PosterBackfill.run(concurrency: 2)

  Deliberately not a periodic worker: it's a migration of existing rows, not
  recurring work, and each item costs an ffmpeg decode. Run it once from a
  release shell after deploying.
  """

  import Ecto.Query
  require Logger

  alias Hybridsocial.Media
  alias Hybridsocial.Media.{MediaFile, Storage, Video}
  alias Hybridsocial.Repo

  def run(opts \\ []) do
    # Lower default concurrency than the dimension backfill: that one is a
    # header read, this decodes a frame per file.
    concurrency = Keyword.get(opts, :concurrency, 2)

    base =
      from(m in MediaFile,
        where:
          like(m.content_type, "video/%") and is_nil(m.deleted_at) and
            (is_nil(m.thumbnail_path) or m.thumbnail_path == ""),
        order_by: [desc: m.inserted_at]
      )

    query = if lim = opts[:limit], do: limit(base, ^lim), else: base
    media = Repo.all(query)
    total = length(media)
    Logger.info("[poster-backfill] start: #{total} videos, concurrency=#{concurrency}")

    {updated, failed, _n} =
      media
      |> Task.async_stream(&poster_and_update/1,
        max_concurrency: concurrency,
        timeout: 120_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce({0, 0, 0}, fn result, {ok, fail, n} ->
        n = n + 1
        if rem(n, 50) == 0, do: Logger.info("[poster-backfill] #{n}/#{total} (#{ok} updated)")

        case result do
          {:ok, :ok} -> {ok + 1, fail, n}
          _ -> {ok, fail + 1, n}
        end
      end)

    Logger.info(
      "[poster-backfill] done: #{updated} updated, #{failed} failed/skipped of #{total}"
    )

    %{total: total, updated: updated, failed: failed}
  end

  defp poster_and_update(%MediaFile{} = media) do
    with url when is_binary(url) <- source_url(media),
         {:ok, poster_path} <- Video.poster(url),
         {:ok, stored} <- store_poster(poster_path, media.identity_id) do
      media
      |> Ecto.Changeset.change(%{thumbnail_path: stored})
      |> Repo.update()

      :ok
    else
      _ -> :error
    end
  rescue
    e ->
      Logger.debug("[poster-backfill] #{media.id} error: #{inspect(e)}")
      :error
  end

  # Where ffmpeg should read the video from.
  #
  # `Media.media_url/1` is the right answer for a *browser* — for remote media
  # it returns our `/proxy/media/...` URL so the viewer's IP never reaches the
  # origin. It's the wrong answer for a server-side job: the box would fetch
  # its own public hostname, back out through Cloudflare and in again, which
  # is both pointless and unreliable from inside the network (hairpin NAT).
  # That's what made the first backfill run fail every row in under a second.
  #
  # So go to the origin directly when there is one, and fall back to
  # `media_url/1` for locally-stored blobs.
  defp source_url(%MediaFile{remote_url: url}) when is_binary(url) and url != "", do: url
  defp source_url(%MediaFile{} = media), do: Media.media_url(media)

  defp store_poster(poster_path, identity_id) do
    upload = %Plug.Upload{path: poster_path, content_type: "image/jpeg", filename: "poster.jpg"}
    Storage.store(upload, identity_id)
  after
    File.rm(poster_path)
  end
end
