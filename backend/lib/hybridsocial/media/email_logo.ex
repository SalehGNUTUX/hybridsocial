defmodule Hybridsocial.Media.EmailLogo do
  @moduledoc """
  Derives an email-safe raster (PNG) from an uploaded instance logo.

  Email clients (Gmail, Outlook) don't render SVG, so whatever an admin
  uploads — SVG or a raster — we rasterize and bound it to a PNG via libvips,
  store it through the normal media pipeline, and return its URL. The caller
  points the `email_logo_url` config at it.

  This keeps branding fully per-instance and admin-configurable: nothing is
  hardcoded. Any operator running HybridSocial gets an email logo derived from
  whatever they upload, with no platform-baked assets.
  """
  require Logger

  alias Hybridsocial.Media

  # Bounding box for the header logo; portrait or landscape both fit. Rendered
  # at ~2x the ~48px display height so it stays crisp on retina clients.
  @size "800x240"
  @png_suffix "[strip,compression=9]"

  @doc """
  Rasterize `upload` to a bounded PNG, store it, and return `{:ok, url}`.

  Best-effort: on any failure returns `{:error, reason}` so the caller can
  leave `email_logo_url` untouched (emails then fall back to the instance name
  as text). Never raises.
  """
  def derive(identity_id, %Plug.Upload{path: src, content_type: content_type}) do
    input = tmp("email_logo_in", ext_for(content_type))
    output = tmp("email_logo_out", "png")

    try do
      File.cp!(src, input)

      case System.cmd(
             "vipsthumbnail",
             [input, "--size", @size, "-o", output <> @png_suffix],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          if File.exists?(output), do: store(identity_id, output), else: {:error, :no_output}

        {msg, code} ->
          Logger.warning("[email_logo] vipsthumbnail exit #{code}: #{String.trim(msg)}")
          {:error, :rasterize_failed}
      end
    rescue
      e ->
        Logger.warning("[email_logo] derive failed: #{inspect(e)}")
        {:error, :exception}
    after
      File.rm(input)
      File.rm(output)
    end
  end

  def derive(_identity_id, _), do: {:error, :invalid_upload}

  defp store(identity_id, png_path) do
    upload = %Plug.Upload{path: png_path, content_type: "image/png", filename: "email-logo.png"}

    case Media.upload(identity_id, upload, nil) do
      {:ok, media} -> {:ok, Media.media_url(media)}
      {:error, _} = err -> err
    end
  end

  defp tmp(prefix, ext) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}.#{ext}")
  end

  defp ext_for("image/svg+xml"), do: "svg"
  defp ext_for("image/png"), do: "png"
  defp ext_for("image/jpeg"), do: "jpg"
  defp ext_for("image/webp"), do: "webp"
  defp ext_for("image/gif"), do: "gif"
  defp ext_for(_), do: "bin"
end
