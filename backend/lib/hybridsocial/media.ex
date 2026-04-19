defmodule Hybridsocial.Media do
  @moduledoc """
  The Media context. Manages file uploads, validation, storage, and retrieval.
  """
  import Ecto.Query

  alias Hybridsocial.Antivirus
  alias Hybridsocial.Repo
  alias Hybridsocial.Media.{MediaFile, Storage, Validator, Hash, Filter, Audio}

  @doc """
  Uploads a file: validates magic bytes, validates size, stores to disk, creates DB record.
  Returns {:ok, media} or {:error, reason}.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def upload(identity_id, %Plug.Upload{path: path, filename: filename} = upload) do
    with {:ok, binary_data} <- File.read(path),
         {:ok, content_type} <- Validator.validate_content_type(binary_data),
         file_size <- byte_size(binary_data),
         :ok <- Validator.validate_file_size(file_size, content_type),
         :ok <- Antivirus.scan(binary_data),
         :ok <- Hash.check_upload(path),
         :ok <- Validator.strip_metadata(path),
         {:ok, filtered} <-
           Filter.filter(%{path: path, filename: filename, content_type: content_type}),
         {:ok, storage_path} <-
           Storage.store(
             %{upload | content_type: content_type, filename: filtered.filename},
             identity_id
           ) do
      attrs = %{
        identity_id: identity_id,
        content_type: content_type,
        file_size: file_size,
        storage_path: storage_path,
        processing_status: "ready",
        metadata: %{"original_filename" => filename}
      }

      %MediaFile{}
      |> MediaFile.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Uploads a file with optional alt_text.
  """
  def upload(identity_id, %Plug.Upload{} = upload, alt_text) when is_binary(alt_text) do
    case upload(identity_id, upload) do
      {:ok, media} ->
        media
        |> MediaFile.update_alt_text_changeset(%{alt_text: alt_text})
        |> Repo.update()

      error ->
        error
    end
  end

  def upload(identity_id, %Plug.Upload{} = upload, _alt_text) do
    upload(identity_id, upload)
  end

  @doc """
  Audio-specific upload path. Runs the magic-byte + AV + storage
  pipeline like `upload/2`, plus ffprobe to measure duration, refine
  the content type (m4a-in-mp4 etc.), and reject the file if it
  exceeds the caller's `audio_duration` tier limit.

  `limits` is the tier map from `TierLimits.limits_for/1`; the caller
  (MediaController) has already checked `audio_allowed` and
  `audio_size_mb`. This function is the one that enforces duration,
  since that requires decoding the file.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def upload_audio(
        identity_id,
        %Plug.Upload{path: path, filename: filename} = upload,
        alt_text,
        limits
      ) do
    with {:ok, binary_data} <- File.read(path),
         {:ok, magic_type} <- Validator.validate_content_type(binary_data),
         {:ok, probe} <- Audio.probe(path, magic_type),
         :ok <- audio_allowlist_check(probe.content_type),
         :ok <- Audio.enforce_duration(probe.duration_seconds, limits[:audio_duration]),
         :ok <- Antivirus.scan(binary_data),
         :ok <- Hash.check_upload(path),
         {:ok, filtered} <-
           Filter.filter(%{path: path, filename: filename, content_type: probe.content_type}),
         {:ok, storage_path} <-
           Storage.store(
             %{upload | content_type: probe.content_type, filename: filtered.filename},
             identity_id
           ) do
      attrs = %{
        identity_id: identity_id,
        content_type: probe.content_type,
        file_size: byte_size(binary_data),
        storage_path: storage_path,
        processing_status: "ready",
        duration: probe.duration_seconds,
        metadata: %{
          "original_filename" => filename,
          "streams" => summarize_streams(probe.streams)
        },
        alt_text: alt_text
      }

      %MediaFile{}
      |> MediaFile.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  # ffprobe refined the content type; reject anything not in the
  # explicit audio allowlist. This catches files that had audio
  # magic bytes but decoded into something weird (corrupt ogg
  # streams, audio/mp4 with video the probe missed, etc.).
  defp audio_allowlist_check(content_type) do
    if Validator.audio?(content_type) do
      :ok
    else
      {:error, :invalid_content_type}
    end
  end

  # Keep only the codec/sample-rate/bitrate fields we need to render
  # the player; drop the rest. ffprobe emits a lot of noise per
  # stream (side data, dispositions, color metadata for video) that
  # bloats the metadata blob for no user-visible benefit.
  defp summarize_streams(streams) when is_list(streams) do
    Enum.map(streams, fn s ->
      %{
        "codec_name" => s["codec_name"],
        "codec_type" => s["codec_type"],
        "sample_rate" => s["sample_rate"],
        "channels" => s["channels"],
        "bit_rate" => s["bit_rate"]
      }
    end)
  end

  defp summarize_streams(_), do: []

  @doc """
  Gets a media record by ID, excluding soft-deleted records.
  """
  def get_media(id) do
    MediaFile
    |> where([m], is_nil(m.deleted_at))
    |> Repo.get(id)
  end

  @doc """
  Gets a media record by ID, excluding soft-deleted records. Raises if not found.
  """
  def get_media!(id) do
    MediaFile
    |> where([m], is_nil(m.deleted_at))
    |> Repo.get!(id)
  end

  @doc """
  Updates the alt text for a media record. Verifies ownership.
  """
  def update_alt_text(media_id, identity_id, alt_text) do
    case get_media(media_id) do
      nil ->
        {:error, :not_found}

      %MediaFile{identity_id: ^identity_id} = media ->
        media
        |> MediaFile.update_alt_text_changeset(%{alt_text: alt_text})
        |> Repo.update()

      %MediaFile{} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Soft-deletes a media record. Verifies ownership.
  The actual file cleanup can be scheduled separately.
  """
  def delete_media(media_id, identity_id) do
    case get_media(media_id) do
      nil ->
        {:error, :not_found}

      %MediaFile{identity_id: ^identity_id} = media ->
        media
        |> MediaFile.soft_delete_changeset()
        |> Repo.update()

      %MediaFile{} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Returns the public URL for a media record.
  Uses the media_host config setting if available for URL generation.
  """
  def media_url(%MediaFile{storage_path: path}) when is_binary(path) and path != "" do
    Storage.url(path)
  end

  # Remote attachment not yet cached locally — serve via the media
  # proxy when enabled (hides origin from the browser), otherwise
  # fall back to the raw remote URL so the image at least loads.
  def media_url(%MediaFile{remote_url: remote_url})
      when is_binary(remote_url) and remote_url != "" do
    Hybridsocial.Media.MediaProxy.url(remote_url) || remote_url
  end

  def media_url(_), do: nil
end
