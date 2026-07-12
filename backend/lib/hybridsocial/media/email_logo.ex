defmodule Hybridsocial.Media.EmailLogo do
  @moduledoc """
  Derives an email-safe raster (PNG) from an instance's logo.

  Email clients (Gmail, Outlook) don't render SVG, so whatever an admin
  configures — SVG or raster — we rasterize and bound it to a PNG via libvips
  and store it through the media storage backend. The caller points the
  `email_logo_url` config at the result.

  Fully per-instance and admin-configurable: nothing is hardcoded. Any operator
  running HybridSocial gets an email logo derived from *their* logo, either at
  upload time (`derive/1`) or lazily from the configured URL (`derive_from_url/1`,
  used for backfill + the self-heal in `Hybridsocial.Emails`).
  """
  require Logger

  alias Hybridsocial.Media.Storage

  # Bounding box for the header logo; portrait or landscape both fit. Rendered
  # at ~2x the ~48px display height so it stays crisp on retina clients.
  @size "800x240"
  @png_suffix "[strip,compression=9]"

  @doc "Derive from an uploaded file (the admin logo-upload flow)."
  def derive(%Plug.Upload{path: src, content_type: content_type}) do
    rasterize_and_store(src, ext_for(content_type))
  end

  def derive(_), do: {:error, :invalid_upload}

  @doc """
  Derive from an already-stored logo URL (backfill / self-heal). Fetches the
  bytes, then rasterizes. Best-effort: returns `{:error, reason}` on any hitch.
  """
  def derive_from_url(url) when is_binary(url) and url != "" do
    case Hybridsocial.HTTP.get(url) do
      {:ok, %{status_code: 200, body: body}} when is_binary(body) and byte_size(body) > 0 ->
        ext = url_ext(url)
        src = tmp("email_logo_src", ext)
        File.write!(src, body)

        try do
          rasterize_and_store(src, ext)
        after
          File.rm(src)
        end

      other ->
        Logger.warning("[email_logo] fetch of #{url} failed: #{inspect(other)}")
        {:error, :fetch_failed}
    end
  rescue
    e ->
      Logger.warning("[email_logo] derive_from_url failed: #{inspect(e)}")
      {:error, :exception}
  end

  def derive_from_url(_), do: {:error, :invalid_url}

  # ── internals ─────────────────────────────────────────────────────

  defp rasterize_and_store(src_path, in_ext) do
    input = tmp("email_logo_in", in_ext)
    output = tmp("email_logo_out", "png")

    try do
      File.cp!(src_path, input)

      case System.cmd(
             "vipsthumbnail",
             [input, "--size", @size, "-o", output <> @png_suffix],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          if File.exists?(output), do: store(output), else: {:error, :no_output}

        {msg, code} ->
          Logger.warning("[email_logo] vipsthumbnail exit #{code}: #{String.trim(msg)}")
          {:error, :rasterize_failed}
      end
    rescue
      e ->
        Logger.warning("[email_logo] rasterize failed: #{inspect(e)}")
        {:error, :exception}
    after
      File.rm(input)
      File.rm(output)
    end
  end

  # No owner / media row: the email logo is an instance asset referenced by the
  # `email_logo_url` config (which the R2 orphan sweep keeps), so we store it
  # straight through the backend. Both backends ignore the identity arg.
  defp store(png_path) do
    upload = %Plug.Upload{path: png_path, content_type: "image/png", filename: "email-logo.png"}

    case Storage.store(upload, nil) do
      {:ok, storage_path} -> {:ok, Storage.url(storage_path)}
      {:error, _} = err -> err
    end
  end

  defp tmp(prefix, ext) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}.#{ext}")
  end

  defp url_ext(url) do
    case url
         |> URI.parse()
         |> Map.get(:path)
         |> to_string()
         |> Path.extname()
         |> String.trim_leading(".") do
      "" -> "bin"
      ext -> String.downcase(ext)
    end
  end

  defp ext_for("image/svg+xml"), do: "svg"
  defp ext_for("image/png"), do: "png"
  defp ext_for("image/jpeg"), do: "jpg"
  defp ext_for("image/webp"), do: "webp"
  defp ext_for("image/gif"), do: "gif"
  defp ext_for(_), do: "bin"
end
