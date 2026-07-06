defmodule Hybridsocial.Media.ImageOptimizer do
  @moduledoc """
  Resize + recompress + strip metadata for image uploads. Wraps the
  libvips CLI (`vipsthumbnail`) — same toolchain CLAUDE.md picks
  for image work. Runs synchronously inside the upload pipeline,
  before the file is handed to the storage backend, so what lands
  in S3 / disk is already the optimized version.

  Defaults (overridable through opts):

    - max dimension: 2048 px on the longest side, never upscale
    - JPEG / WebP quality: 82
    - PNG: re-encoded with strip + interlace, no quality knob (lossless)
    - GIF: skipped (animation handling lives in a follow-up that
      transcodes to MP4; touching GIFs here would silently kill the
      animation)
    - SVG: skipped (vector — already small, and rasterizing would
      lose quality)

  Returns `{:ok, optimized_path, content_type, byte_size}` or
  `{:skip, original_path}` when the optimizer doesn't apply (non-
  image / vips missing / file already smaller than the threshold).
  Failures fall through as `{:skip, original_path}` rather than
  hard-erroring so a bad encode never loses the user's upload.
  """

  require Logger

  @max_dim 2048
  @jpeg_quality 82
  @webp_quality 82
  # Files smaller than this are passed through. Optimizing already-
  # tiny images burns CPU for no real win.
  @passthrough_bytes 200 * 1024

  @doc """
  Optimize the image at `path`. Returns the path to the optimized
  file (which may be the same as the input on skip), the content
  type to record, and the new byte size.
  """
  def optimize(path, content_type, opts \\ []) do
    cond do
      not image?(content_type) -> {:skip, path, content_type, file_size(path)}
      not vips_available?() -> {:skip, path, content_type, file_size(path)}
      gif?(content_type) -> {:skip, path, content_type, file_size(path)}
      svg?(content_type) -> {:skip, path, content_type, file_size(path)}
      file_size(path) < @passthrough_bytes -> {:skip, path, content_type, file_size(path)}
      true -> run(path, content_type, opts)
    end
  end

  defp run(input_path, content_type, opts) do
    max_dim = Keyword.get(opts, :max_dim, @max_dim)
    output_ext = output_extension(content_type)
    output_suffix = output_suffix(content_type)

    output_path =
      Path.join(System.tmp_dir!(), "hs_optimized_#{Ecto.UUID.generate()}.#{output_ext}")

    target = "#{output_path}#{output_suffix}"

    args = ["#{input_path}", "-s", "#{max_dim}x#{max_dim}>", "-o", target]

    case System.cmd("vipsthumbnail", args, stderr_to_stdout: true) do
      {_out, 0} ->
        case File.stat(output_path) do
          {:ok, %{size: new_size}} ->
            original_size = file_size(input_path)

            # If the "optimized" version is somehow bigger than the
            # original (small re-encoded PNGs occasionally are),
            # discard it and keep the original.
            if new_size >= original_size do
              File.rm(output_path)
              {:skip, input_path, content_type, original_size}
            else
              {:ok, output_path, content_type, new_size}
            end

          {:error, _} ->
            {:skip, input_path, content_type, file_size(input_path)}
        end

      {output, status} ->
        Logger.warning("vipsthumbnail exited #{status} on #{input_path}: #{String.trim(output)}")

        File.rm(output_path)
        {:skip, input_path, content_type, file_size(input_path)}
    end
  rescue
    e ->
      Logger.warning("ImageOptimizer crashed on #{input_path}: #{inspect(e)}")
      {:skip, input_path, content_type, file_size(input_path)}
  end

  # --- vipsthumbnail output suffix ---
  # The tool reads quality / strip flags as bracketed arguments
  # appended to the output path (e.g. `out.jpg[Q=82,strip]`).
  defp output_suffix("image/jpeg"), do: "[Q=#{@jpeg_quality},strip,optimize_coding,interlace]"
  defp output_suffix("image/jpg"), do: output_suffix("image/jpeg")
  defp output_suffix("image/webp"), do: "[Q=#{@webp_quality},strip]"
  defp output_suffix("image/png"), do: "[strip,compression=9]"
  defp output_suffix(_), do: ""

  defp output_extension("image/jpeg"), do: "jpg"
  defp output_extension("image/jpg"), do: "jpg"
  defp output_extension("image/png"), do: "png"
  defp output_extension("image/webp"), do: "webp"
  defp output_extension(_), do: "jpg"

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp image?("image/" <> _), do: true
  defp image?(_), do: false

  defp gif?("image/gif"), do: true
  defp gif?(_), do: false

  defp svg?("image/svg+xml"), do: true
  defp svg?(_), do: false

  defp vips_available? do
    # Cache the lookup since we do this on every upload. Re-checks
    # if the cache hasn't been seeded yet.
    case :persistent_term.get({__MODULE__, :vips_available}, :unknown) do
      :unknown ->
        available =
          case System.find_executable("vipsthumbnail") do
            nil -> false
            _ -> true
          end

        :persistent_term.put({__MODULE__, :vips_available}, available)

        unless available do
          Logger.warning("vipsthumbnail not on PATH — image uploads are stored at original size")
        end

        available

      v ->
        v
    end
  end
end
