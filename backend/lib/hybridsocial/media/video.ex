defmodule Hybridsocial.Media.Video do
  @moduledoc """
  Video metadata extraction. Wraps `ffprobe` to read duration plus
  width/height/framerate from the first video stream so the player
  has enough info to size the embed correctly and show the runtime
  before the file finishes loading. Mirrors `Media.Audio.probe/2`
  but for video — the two run independently in the upload pipeline.

  Returns `{:ok, %{duration_seconds, width, height, framerate}}` or
  `{:error, reason}`. Any ffprobe failure (binary missing, malformed
  output, etc.) bubbles up — the caller decides whether to reject
  the upload or store it without metadata.
  """

  require Logger

  def probe(path) when is_binary(path) do
    case run_ffprobe(path) do
      {:ok, %{"streams" => streams, "format" => format}} ->
        # Fast-path: header carries the duration (most uploads).
        duration_from_header =
          parse_duration(format["duration"] || duration_from_streams(streams))

        # Slow-path: WebM files written by Chrome's MediaRecorder /
        # streaming muxers commonly omit the duration tag. Fall back
        # to a full-file scan that computes duration from the last
        # packet's PTS. Only runs when the fast-path failed (0.0)
        # so happy-path uploads stay cheap.
        duration =
          if duration_from_header > 0.0 do
            duration_from_header
          else
            scan_duration(path)
          end

        video = first_video_stream(streams)

        {:ok,
         %{
           duration_seconds: duration,
           width: video && video["width"],
           height: video && video["height"],
           framerate: video && parse_fps(video["avg_frame_rate"] || video["r_frame_rate"]),
           streams: streams
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Full-file scan for containers without a duration header. Reads
  # every packet, prints `pkt_pts_time` for the last one — that's the
  # duration. Slow on large files but accurate where the metadata
  # path is empty.
  defp scan_duration(path) do
    args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "packet=pts_time",
      "-of",
      "csv=p=0",
      path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} ->
        case last_numeric_line(output) do
          d when d > 0.0 -> d
          _ -> scan_duration_audio(path)
        end

      _ ->
        scan_duration_audio(path)
    end
  rescue
    _ -> 0.0
  end

  defp scan_duration_audio(path) do
    args = [
      "-v",
      "error",
      "-select_streams",
      "a:0",
      "-show_entries",
      "packet=pts_time",
      "-of",
      "csv=p=0",
      path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} -> last_numeric_line(output)
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  end

  # ffprobe with stderr_to_stdout intersperses warning lines (e.g.
  # `[opus @ …] Error parsing Opus packet header.`) into the packet
  # output. Filter to lines that parse as floats and take the last
  # one — that's the timestamp we want.
  defp last_numeric_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(0.0, fn line ->
      stripped = line |> String.trim() |> String.trim_trailing(",")

      case Float.parse(stripped) do
        {value, ""} when value > 0 -> value
        _ -> nil
      end
    end)
  end

  defp run_ffprobe(path) do
    args = [
      "-v",
      "error",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams",
      path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, :ffprobe_parse_error}
        end

      {stderr, _nonzero} ->
        Logger.debug("ffprobe failed: #{String.slice(stderr, 0, 200)}")
        {:error, :ffprobe_failed}
    end
  rescue
    # No ffprobe on PATH — log + return; the caller is expected to
    # store the upload anyway since duration is informational, not
    # security-critical.
    e in ErlangError ->
      Logger.warning("ffprobe not available for video probe: #{inspect(e)}")
      {:error, :ffprobe_unavailable}
  end

  defp first_video_stream(streams) when is_list(streams) do
    Enum.find(streams, fn s -> s["codec_type"] == "video" end)
  end

  defp first_video_stream(_), do: nil

  defp parse_duration(nil), do: 0.0

  defp parse_duration(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, _} -> seconds
      :error -> 0.0
    end
  end

  defp parse_duration(value) when is_number(value), do: value * 1.0

  defp duration_from_streams(streams) when is_list(streams) do
    streams
    |> Enum.map(&(&1["duration"] || "0"))
    |> Enum.map(&parse_duration/1)
    |> Enum.max(fn -> 0.0 end)
  end

  # ffprobe returns the framerate as a fraction string ("30000/1001").
  # Resolve to a float so the API can ship it as a single number.
  defp parse_fps(nil), do: nil

  defp parse_fps(value) when is_binary(value) do
    case String.split(value, "/", parts: 2) do
      [num, den] ->
        with {n, _} <- Float.parse(num),
             {d, _} <- Float.parse(den),
             true <- d > 0 do
          n / d
        else
          _ -> nil
        end

      _ ->
        case Float.parse(value) do
          {f, _} -> f
          :error -> nil
        end
    end
  end

  defp parse_fps(_), do: nil

  @doc """
  Extracts a poster frame from a video, returning `{:ok, jpeg_path}`.

  Videos had no server-side poster: `thumbnail_path` was declared on
  `MediaFile`, read by the serializer and cleaned up on delete, but nothing
  ever wrote it. So `preview_url` was always null for video and the media
  grid fell back to a bare `<video preload="metadata">`, which loads metadata
  without painting a frame — every video tile rendered blank.

  Seeks to `at_seconds` (1s by default) rather than frame 0: the first frame
  of a clip is very often black or a fade-in, which makes a grid of posters
  look just as broken as no posters at all. Falls back to frame 0 for clips
  shorter than the seek point.

  Best-effort by design, like `probe/1` — a missing ffmpeg or an undecodable
  file must never fail the upload itself.
  """
  def poster(path, at_seconds \\ 1) when is_binary(path) do
    out = Path.join(System.tmp_dir!(), "poster_#{:erlang.unique_integer([:positive])}.jpg")

    case extract_frame(path, at_seconds, out) do
      :ok ->
        {:ok, out}

      :error when at_seconds > 0 ->
        # Clip shorter than the seek point — take the very first frame.
        case extract_frame(path, 0, out) do
          :ok -> {:ok, out}
          :error -> cleanup_and_error(out)
        end

      :error ->
        cleanup_and_error(out)
    end
  end

  defp extract_frame(path, at_seconds, out) do
    args = [
      # -ss before -i seeks by keyframe, which is much cheaper than decoding
      # up to the timestamp and is plenty accurate for a thumbnail.
      "-ss",
      to_string(at_seconds),
      "-i",
      path,
      "-frames:v",
      "1",
      # Cap the long edge: a poster only ever renders in a grid tile, and a
      # 4K still would cost more to serve than the tile is worth.
      "-vf",
      "scale='min(640,iw)':'min(640,ih)':force_original_aspect_ratio=decrease",
      "-q:v",
      "4",
      "-y",
      out
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> if File.exists?(out) and File.stat!(out).size > 0, do: :ok, else: :error
      {_out, _code} -> :error
    end
  rescue
    e ->
      Logger.warning("video poster extraction failed: #{Exception.message(e)}")
      :error
  end

  defp cleanup_and_error(out) do
    File.rm(out)
    {:error, :poster_failed}
  end
end
