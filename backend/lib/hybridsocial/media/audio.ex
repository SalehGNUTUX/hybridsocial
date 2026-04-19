defmodule Hybridsocial.Media.Audio do
  @moduledoc """
  Audio-specific validation helpers. Uses `ffprobe` (part of ffmpeg)
  to read duration and detect whether a file labelled as a video
  container actually carries only audio streams (m4a-in-mp4,
  opus-in-webm). Centralizing this means the upload pipeline can
  treat ffprobe-presence as a hard dependency in one place.
  """

  require Logger

  @doc """
  Probe a file and return `{:ok, %{duration_seconds: float,
  content_type: refined_type}}` or `{:error, reason}`.

  `initial_content_type` comes from the magic-byte scan and is
  refined here: an mp4 container that ffprobe shows as audio-only
  becomes `audio/mp4`; an ogg/webm that's audio-only is kept as
  audio/* rather than promoted to video.
  """
  def probe(path, initial_content_type)
      when is_binary(path) and is_binary(initial_content_type) do
    case run_ffprobe(path) do
      {:ok, %{"streams" => streams, "format" => format}} ->
        duration = parse_duration(format["duration"] || duration_from_streams(streams))
        refined = refine_content_type(initial_content_type, streams)
        {:ok, %{duration_seconds: duration, content_type: refined, streams: streams}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Enforce `audio_duration` tier limit. Takes the probed duration
  (seconds) and the tier's cap; `0` disables the check the same
  way `edit_window: 0` means unlimited elsewhere in this project.
  """
  def enforce_duration(duration, nil), do: enforce_duration(duration, 0)

  def enforce_duration(_duration, 0), do: :ok

  def enforce_duration(duration, max_seconds)
      when is_number(duration) and is_integer(max_seconds) do
    if duration <= max_seconds + 0.5 do
      :ok
    else
      {:error, {:audio_too_long, max_seconds: max_seconds, actual_seconds: duration}}
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
    # `System.cmd` raises if the executable isn't on PATH. Fail-closed:
    # we'd rather reject an audio upload than accept it unscanned.
    e in ErlangError ->
      Logger.error("ffprobe not available: #{inspect(e)}")
      {:error, :ffprobe_unavailable}
  end

  defp parse_duration(nil), do: 0.0

  defp parse_duration(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, _} -> seconds
      :error -> 0.0
    end
  end

  defp parse_duration(value) when is_number(value), do: value * 1.0

  # Fall back to the longest stream duration if `format.duration` is
  # missing (rare; some ogg streams).
  defp duration_from_streams(streams) when is_list(streams) do
    streams
    |> Enum.map(&(&1["duration"] || "0"))
    |> Enum.map(&parse_duration/1)
    |> Enum.max(fn -> 0.0 end)
  end

  # If the magic bytes said "video container" (mp4/webm/ogg) but
  # every stream ffprobe found is an audio stream, treat the file
  # as audio/*. This lets users upload m4a (mp4-audio), opus-in-webm,
  # etc. without the pipeline rejecting them as video over the wrong
  # tier limit.
  defp refine_content_type("video/mp4", streams) do
    if only_audio?(streams), do: "audio/mp4", else: "video/mp4"
  end

  defp refine_content_type("video/webm", streams) do
    if only_audio?(streams), do: "audio/webm", else: "video/webm"
  end

  defp refine_content_type(other, _streams), do: other

  defp only_audio?(streams) when is_list(streams) do
    Enum.any?(streams, &(&1["codec_type"] == "audio")) and
      not Enum.any?(streams, &(&1["codec_type"] == "video"))
  end
end
