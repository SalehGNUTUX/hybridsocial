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
        duration = parse_duration(format["duration"] || duration_from_streams(streams))
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
end
