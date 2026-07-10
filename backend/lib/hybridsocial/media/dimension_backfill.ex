defmodule Hybridsocial.Media.DimensionBackfill do
  @moduledoc """
  One-off backfill for video media that predate dimension capture.

  The streams (reels) feed only surfaces videos whose width/height are
  known (it must prove a clip is vertical). Videos uploaded before the
  pipeline recorded dimensions have NULL width/height and are therefore
  invisible in streams. This probes each such video's header (cheap:
  dimensions + header duration, no full-file packet scan) and fills in
  the media record so the live streams query can include the eligible
  (public, local, vertical, long-enough) ones.

  Idempotent + resumable: only selects rows still missing dimensions, so
  re-running continues where a prior run left off.

      Hybridsocial.Media.DimensionBackfill.run()               # everything
      Hybridsocial.Media.DimensionBackfill.run(limit: 50)      # a test batch
      Hybridsocial.Media.DimensionBackfill.run(concurrency: 6)
  """

  import Ecto.Query
  require Logger

  alias Hybridsocial.Media
  alias Hybridsocial.Media.MediaFile
  alias Hybridsocial.Repo

  # ffprobe network read timeout (µs) so a stalled fetch can't hang a slot.
  @rw_timeout_us "30000000"

  def run(opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, 4)

    base =
      from(m in MediaFile,
        where:
          like(m.content_type, "video/%") and is_nil(m.deleted_at) and
            (is_nil(m.width) or is_nil(m.height)),
        order_by: [asc: m.inserted_at]
      )

    query = if lim = opts[:limit], do: limit(base, ^lim), else: base
    media = Repo.all(query)
    total = length(media)
    Logger.info("[dim-backfill] start: #{total} videos, concurrency=#{concurrency}")

    {updated, failed, _n} =
      media
      |> Task.async_stream(&probe_and_update/1,
        max_concurrency: concurrency,
        timeout: 90_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce({0, 0, 0}, fn result, {ok, fail, n} ->
        n = n + 1
        if rem(n, 200) == 0, do: Logger.info("[dim-backfill] #{n}/#{total} (#{ok} updated)")

        case result do
          {:ok, :ok} -> {ok + 1, fail, n}
          _ -> {ok, fail + 1, n}
        end
      end)

    Logger.info("[dim-backfill] done: #{updated} updated, #{failed} failed/skipped of #{total}")
    %{total: total, updated: updated, failed: failed}
  end

  defp probe_and_update(%MediaFile{} = media) do
    with url when is_binary(url) <- Media.media_url(media),
         {:ok, w, h, duration} <- probe_dims(url) do
      media
      |> Ecto.Changeset.change(%{width: w, height: h, duration: media.duration || duration})
      |> Repo.update()

      :ok
    else
      _ -> :error
    end
  rescue
    e ->
      Logger.debug("[dim-backfill] #{media.id} error: #{inspect(e)}")
      :error
  end

  # Header-only probe: dimensions of the first video stream + the format
  # duration tag. No packet scan, so remote fetches stay to header + moov.
  defp probe_dims(url) do
    args = [
      "-v",
      "error",
      "-rw_timeout",
      @rw_timeout_us,
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=width,height:format=duration",
      "-of",
      "json",
      url
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, %{"streams" => [%{"width" => w, "height" => h} | _]} = data}
          when is_integer(w) and is_integer(h) and w > 0 and h > 0 ->
            {:ok, w, h, data |> get_in(["format", "duration"]) |> parse_float()}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(_), do: nil
end
