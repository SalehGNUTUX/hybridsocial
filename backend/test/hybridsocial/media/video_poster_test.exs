defmodule Hybridsocial.Media.VideoPosterTest do
  @moduledoc """
  Poster-frame extraction for video uploads.

  `MediaFile.thumbnail_path` existed and was read by the serializer, but
  nothing ever wrote it — so `preview_url` was always null for video and the
  media grid rendered blank tiles. These cover the generation half.

  Skipped when ffmpeg isn't on PATH, the same way the rest of the media
  pipeline treats it as optional.
  """
  use ExUnit.Case, async: true

  alias Hybridsocial.Media.Video

  @moduletag :tmp_dir

  defp ffmpeg?, do: !!System.find_executable("ffmpeg")

  # A real 3-second clip: one second of black, then two of white. The split
  # is what lets us assert the poster is taken from *after* the opening
  # frame rather than at 0s — a lot of clips open on black or a fade, and a
  # grid of black posters looks as broken as no posters at all.
  defp make_video(dir) do
    path = Path.join(dir, "clip.mp4")

    args = [
      "-f",
      "lavfi",
      "-i",
      "color=c=black:s=320x240:d=1",
      "-f",
      "lavfi",
      "-i",
      "color=c=white:s=320x240:d=2",
      "-filter_complex",
      "[0:v][1:v]concat=n=2:v=1[out]",
      "-map",
      "[out]",
      "-pix_fmt",
      "yuv420p",
      "-y",
      path
    ]

    {_, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
    path
  end

  describe "poster/2" do
    test "extracts a non-empty JPEG from a video", %{tmp_dir: dir} do
      if ffmpeg?() do
        video = make_video(dir)

        assert {:ok, poster} = Video.poster(video)
        assert File.exists?(poster)
        assert File.stat!(poster).size > 0

        # JPEG magic bytes — proves it's a real image, not a zero-byte file
        # that happens to exist.
        assert <<0xFF, 0xD8, 0xFF, _::binary>> = File.read!(poster)

        File.rm(poster)
      end
    end

    test "seeks past the opening frame rather than grabbing frame 0", %{tmp_dir: dir} do
      if ffmpeg?() do
        video = make_video(dir)

        # Default seek is 1s, which lands in the white segment.
        assert {:ok, poster} = Video.poster(video)
        assert mean_luma(poster) > 200, "expected the white segment, got a dark frame"
        File.rm(poster)

        # Explicitly asking for frame 0 lands in the black segment — proves
        # the seek is doing something rather than the clip just being white.
        assert {:ok, first} = Video.poster(video, 0)
        assert mean_luma(first) < 60, "expected the black opening frame"
        File.rm(first)
      end
    end

    test "falls back to the first frame for a clip shorter than the seek point",
         %{tmp_dir: dir} do
      if ffmpeg?() do
        short = Path.join(dir, "short.mp4")

        {_, 0} =
          System.cmd(
            "ffmpeg",
            [
              "-f",
              "lavfi",
              "-i",
              "color=c=red:s=64x64:d=0.2",
              "-pix_fmt",
              "yuv420p",
              "-y",
              short
            ],
            stderr_to_stdout: true
          )

        # 1s seek is past the end of a 0.2s clip; must still produce a poster
        # instead of giving up.
        assert {:ok, poster} = Video.poster(short)
        assert File.stat!(poster).size > 0
        File.rm(poster)
      end
    end

    test "returns an error for a file that isn't a video", %{tmp_dir: dir} do
      if ffmpeg?() do
        junk = Path.join(dir, "not-a-video.mp4")
        File.write!(junk, "definitely not a video")

        assert {:error, :poster_failed} = Video.poster(junk)
      end
    end

    test "returns an error for a missing file" do
      if ffmpeg?() do
        assert {:error, :poster_failed} = Video.poster("/nonexistent/nope.mp4")
      end
    end
  end

  # Average luminance via ffmpeg's signalstats, so "is the poster the white
  # part or the black part" is measured rather than eyeballed.
  defp mean_luma(jpeg_path) do
    {out, 0} =
      System.cmd(
        "ffmpeg",
        ["-i", jpeg_path, "-vf", "signalstats,metadata=print", "-f", "null", "-"],
        stderr_to_stdout: true
      )

    case Regex.run(~r/lavfi\.signalstats\.YAVG=([\d.]+)/, out) do
      # Float.parse, not String.to_float: ffmpeg prints "235" as often as
      # "235.4", and String.to_float rejects the integer form.
      [_, v] -> v |> Float.parse() |> elem(0)
      _ -> flunk("could not read YAVG from ffmpeg output")
    end
  end
end
