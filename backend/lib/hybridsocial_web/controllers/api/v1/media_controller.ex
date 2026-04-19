defmodule HybridsocialWeb.Api.V1.MediaController do
  use HybridsocialWeb, :controller

  alias Hybridsocial.Media

  @doc """
  POST /api/v1/media - Upload a media file.
  Accepts multipart with `file` field and optional `alt_text`.
  """
  def create(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    identity = conn.assigns.current_identity
    identity_id = identity.id
    alt_text = params["alt_text"]
    limits = Hybridsocial.Premium.TierLimits.limits_for(identity)

    file_size = File.stat!(upload.path).size
    content_type = upload.content_type || ""

    # Audio uploads have their own tier gate (allowed? + size + duration)
    # plus an ffprobe refinement step. Keep that path distinct from the
    # image/video size check so the error messages stay precise.
    if audio_upload?(content_type, upload) do
      handle_audio_upload(conn, identity_id, upload, alt_text, limits)
    else
      handle_visual_upload(
        conn,
        identity_id,
        upload,
        alt_text,
        limits,
        content_type,
        file_size
      )
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "media.file_required"})
  end

  defp handle_visual_upload(conn, identity_id, upload, alt_text, limits, content_type, file_size) do
    is_video = String.starts_with?(content_type, "video/")

    max_bytes =
      if is_video,
        do: (limits[:video_size_mb] || 40) * 1_048_576,
        else: (limits[:image_size_mb] || 10) * 1_048_576

    if file_size > max_bytes do
      max_mb = if is_video, do: limits[:video_size_mb] || 40, else: limits[:image_size_mb] || 10

      conn
      |> put_status(:request_entity_too_large)
      |> json(%{error: "media.file_too_large", max_mb: max_mb})
    else
      result = Media.upload(identity_id, upload, alt_text)
      render_upload_result(conn, result, identity_id, content_type, file_size)
    end
  end

  defp handle_audio_upload(conn, identity_id, upload, alt_text, limits) do
    file_size = File.stat!(upload.path).size

    with :ok <- check_audio_allowed(limits),
         :ok <- check_audio_size(file_size, limits) do
      result = Media.upload_audio(identity_id, upload, alt_text, limits)
      render_upload_result(conn, result, identity_id, upload.content_type || "audio/*", file_size)
    else
      {:error, :audio_not_allowed} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "media.audio_not_allowed",
          message: "Your current tier does not allow audio uploads."
        })

      {:error, {:audio_too_large, max_mb: max_mb}} ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: "media.audio_too_large", max_mb: max_mb})
    end
  end

  # Either the browser sent an `audio/*` content type, OR the filename
  # looks like an audio file. Extension check is a coarse filter — the
  # definitive rejection comes from magic-byte + ffprobe validation
  # inside `Media.upload_audio`.
  defp audio_upload?(content_type, %Plug.Upload{filename: filename}) do
    String.starts_with?(content_type, "audio/") or
      audio_extension?(filename)
  end

  defp audio_extension?(nil), do: false

  defp audio_extension?(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    ext in [".mp3", ".wav", ".ogg", ".oga", ".opus", ".flac", ".aac", ".m4a", ".weba"]
  end

  defp check_audio_allowed(limits) do
    if limits[:audio_allowed] == true, do: :ok, else: {:error, :audio_not_allowed}
  end

  defp check_audio_size(size, limits) do
    max_mb = limits[:audio_size_mb] || 10
    max_bytes = max_mb * 1_048_576

    if size <= max_bytes, do: :ok, else: {:error, {:audio_too_large, max_mb: max_mb}}
  end

  # Split out so credo's cyclomatic-complexity cap stays under 15 —
  # each error clause counts as a branch.
  defp render_upload_result(conn, {:ok, media}, _identity_id, _content_type, _file_size) do
    conn |> put_status(:created) |> json(render_media(media))
  end

  defp render_upload_result(conn, {:error, :invalid_content_type}, _, _, _) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "media.invalid_content_type"})
  end

  defp render_upload_result(conn, {:error, :file_too_large}, _, _, _) do
    conn |> put_status(:request_entity_too_large) |> json(%{error: "media.file_too_large"})
  end

  defp render_upload_result(
         conn,
         {:error, {:audio_too_long, max_seconds: max, actual_seconds: actual}},
         _,
         _,
         _
       ) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "media.audio_too_long",
      max_seconds: max,
      actual_seconds: Float.round(actual * 1.0, 2)
    })
  end

  defp render_upload_result(conn, {:error, :ffprobe_failed}, _, _, _) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "media.audio_invalid",
      message: "The audio file could not be decoded. Try a different format."
    })
  end

  defp render_upload_result(conn, {:error, :ffprobe_unavailable}, _, _, _) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: "media.audio_scanner_unavailable",
      message: "Audio validation is temporarily unavailable. Please try again shortly."
    })
  end

  # ClamAV matched a signature. Log + rate-limit-track + tell the
  # uploader specifically — a generic "upload failed" hides the fact
  # that their file was infected, which might mean their machine is
  # compromised.
  defp render_upload_result(
         conn,
         {:error, {:infected, signature}},
         identity_id,
         content_type,
         file_size
       ) do
    Hybridsocial.Media.InfectedTracker.record(identity_id, signature, content_type, file_size)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "media.infected",
      signature: signature,
      message:
        "This file was rejected because our antivirus scanner flagged it as infected. If you believe this is a false positive, contact the instance admins."
    })
  end

  # Scanner configured but unreachable. Fail-closed — don't let
  # unscanned bytes through — but tell the caller it's a service
  # issue, not their file.
  defp render_upload_result(conn, {:error, :unreachable}, _, _, _) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: "media.scanner_unreachable",
      message: "The antivirus scanner is currently unavailable. Please try again shortly."
    })
  end

  defp render_upload_result(conn, {:error, %Ecto.Changeset{} = changeset}, _, _, _) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "media.upload_failed", details: format_errors(changeset)})
  end

  defp render_upload_result(conn, {:error, _reason}, _, _, _) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "media.upload_failed"})
  end

  @doc """
  GET /api/v1/media/:id - Show a media record.
  """
  def show(conn, %{"id" => id}) do
    case Media.get_media(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "media.not_found"})

      media ->
        conn
        |> put_status(:ok)
        |> json(render_media(media))
    end
  end

  @doc """
  PUT /api/v1/media/:id - Update a media record (alt text only).
  """
  def update(conn, %{"id" => id} = params) do
    identity_id = conn.assigns.current_identity.id
    alt_text = params["alt_text"] || ""

    case Media.update_alt_text(id, identity_id, alt_text) do
      {:ok, media} ->
        conn
        |> put_status(:ok)
        |> json(render_media(media))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "media.not_found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "media.unauthorized"})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "media.update_failed"})
    end
  end

  defp render_media(media) do
    url = Media.media_url(media)

    %{
      id: media.id,
      content_type: media.content_type,
      # Broad class derived from content_type. The frontend / composer
      # preview switches on this rather than content_type directly so
      # new mime subtypes (e.g. image/avif, image/heic) don't need a
      # client-side update to render a thumbnail.
      type: media_type(media.content_type),
      file_size: media.file_size,
      alt_text: media.alt_text,
      description: media.alt_text,
      blurhash: media.blurhash,
      width: media.width,
      height: media.height,
      duration: media.duration,
      processing_status: media.processing_status,
      url: url,
      preview_url: url,
      inserted_at: media.inserted_at
    }
  end

  defp media_type("image/" <> _), do: "image"
  defp media_type("video/" <> _), do: "video"
  defp media_type("audio/" <> _), do: "audio"
  defp media_type(_), do: "unknown"

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
