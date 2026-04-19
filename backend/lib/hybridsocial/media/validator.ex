defmodule Hybridsocial.Media.Validator do
  @moduledoc """
  Validates media files by checking magic bytes and file size.
  """

  # Default file size limits in bytes
  @default_image_limit 10 * 1024 * 1024
  @default_video_limit 100 * 1024 * 1024

  @doc """
  Validates the content type of a file by checking its magic bytes.
  Returns {:ok, content_type} or {:error, :invalid_content_type}.

  Audio containers are disambiguated further than pure magic bytes
  can manage (mp4/m4a shares `ftyp` with mp4 video, ogg carries
  both Opus + Vorbis), so the caller may need to refine with
  ffprobe after this passes. For classification purposes we return
  the container family here and let the pipeline decide.
  """
  def validate_content_type(binary_data) when is_binary(binary_data) do
    cond do
      jpeg?(binary_data) -> {:ok, "image/jpeg"}
      png?(binary_data) -> {:ok, "image/png"}
      gif?(binary_data) -> {:ok, "image/gif"}
      webp?(binary_data) -> {:ok, "image/webp"}
      # mp4-family magic bytes — needs ffprobe to distinguish
      # video/mp4 from audio/mp4 (m4a). Default-classify as video
      # here; `refine_mp4_family/2` downgrades to audio/mp4 when
      # ffprobe reports no video stream.
      mp4?(binary_data) -> {:ok, "video/mp4"}
      webm?(binary_data) -> {:ok, "video/webm"}
      # Audio containers — some overlap with video (ogg, webm) is
      # resolved via ffprobe later.
      mp3?(binary_data) -> {:ok, "audio/mpeg"}
      wav?(binary_data) -> {:ok, "audio/wav"}
      flac?(binary_data) -> {:ok, "audio/flac"}
      ogg?(binary_data) -> {:ok, "audio/ogg"}
      aac?(binary_data) -> {:ok, "audio/aac"}
      true -> {:error, :invalid_content_type}
    end
  end

  @audio_content_types ~w(audio/mpeg audio/wav audio/x-wav audio/flac audio/ogg audio/aac audio/mp4 audio/webm)

  @doc "Whether `content_type` is in the audio allowlist."
  def audio?(content_type) when is_binary(content_type) do
    content_type in @audio_content_types
  end

  def audio?(_), do: false

  @doc "Canonical list of accepted audio content types."
  def audio_content_types, do: @audio_content_types

  @doc """
  Validates the file size against configurable limits per content type.
  Returns :ok or {:error, :file_too_large}.
  """
  def validate_file_size(size, content_type, opts \\ []) do
    limit = size_limit(content_type, opts)

    if size <= limit do
      :ok
    else
      {:error, :file_too_large}
    end
  end

  @doc """
  Strips metadata from a file (EXIF, etc.).
  Currently a no-op; actual stripping requires libvips.
  """
  def strip_metadata(_file_path) do
    :ok
  end

  # Magic byte checks

  # JPEG: FF D8 FF
  defp jpeg?(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: true
  defp jpeg?(_), do: false

  # PNG: 89 50 4E 47 0D 0A 1A 0A
  defp png?(<<0x89, 0x50, 0x4E, 0x47, _rest::binary>>), do: true
  defp png?(_), do: false

  # GIF: 47 49 46 38
  defp gif?(<<0x47, 0x49, 0x46, 0x38, _rest::binary>>), do: true
  defp gif?(_), do: false

  # WebP: RIFF....WEBP
  defp webp?(
         <<0x52, 0x49, 0x46, 0x46, _size::binary-size(4), 0x57, 0x45, 0x42, 0x50, _rest::binary>>
       ),
       do: true

  defp webp?(_), do: false

  # MP4: ftyp at offset 4
  defp mp4?(<<_size::binary-size(4), 0x66, 0x74, 0x79, 0x70, _rest::binary>>), do: true
  defp mp4?(_), do: false

  # WebM: 1A 45 DF A3
  defp webm?(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>), do: true
  defp webm?(_), do: false

  # MP3 framing. Two valid starts: an ID3v2 tag ("ID3" at offset 0),
  # or a raw MPEG audio frame header (0xFF, 0xFB/F3/F2/FA/E3/E2 for
  # the common v1/v2 L3 variants). We check a few of the most
  # common bitrate-flag combinations; the rest are rejected so
  # we're not permissive with arbitrary 0xFF-prefixed garbage.
  defp mp3?(<<"ID3", _rest::binary>>), do: true
  defp mp3?(<<0xFF, b, _rest::binary>>) when b in [0xFB, 0xF3, 0xF2, 0xFA, 0xE3, 0xE2], do: true
  defp mp3?(_), do: false

  # WAV: RIFF....WAVE
  defp wav?(
         <<0x52, 0x49, 0x46, 0x46, _size::binary-size(4), 0x57, 0x41, 0x56, 0x45, _rest::binary>>
       ),
       do: true

  defp wav?(_), do: false

  # FLAC: "fLaC" at offset 0
  defp flac?(<<"fLaC", _rest::binary>>), do: true
  defp flac?(_), do: false

  # Ogg container: "OggS" at offset 0. May carry Opus, Vorbis, or
  # FLAC-in-Ogg; ffprobe disambiguates downstream.
  defp ogg?(<<"OggS", _rest::binary>>), do: true
  defp ogg?(_), do: false

  # ADTS AAC: sync word 0xFFF in the first 12 bits. The low nibble
  # of byte 1 is FFF0..FFFF (version + layer + CRC absent bit).
  defp aac?(<<0xFF, b, _rest::binary>>) when b in [0xF1, 0xF9], do: true
  defp aac?(_), do: false

  defp size_limit("image/" <> _, opts) do
    case Keyword.get(opts, :image_size_mb) do
      nil -> @default_image_limit
      mb -> mb * 1024 * 1024
    end
  end

  defp size_limit("video/" <> _, opts) do
    case Keyword.get(opts, :video_size_mb) do
      nil -> @default_video_limit
      mb -> mb * 1024 * 1024
    end
  end

  defp size_limit(_, _opts), do: @default_image_limit
end
