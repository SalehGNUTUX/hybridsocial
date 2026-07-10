defmodule Hybridsocial.Media.SvgSanitizer do
  @moduledoc """
  Strips active/executable content from an uploaded SVG so it can be
  served as an image without becoming a stored-XSS vector.

  Conservative regex passes over the raw markup remove the known SVG
  script surfaces: `<script>` / `<foreignObject>` elements, inline
  `on*` event handlers, `javascript:` URIs, and DOCTYPE/ENTITY
  declarations (which enable XXE / billion-laughs). This is defense in
  depth on top of serving media from a separate origin.
  """

  @script ~r/<script\b[^>]*>.*?<\/script\s*>/is
  @script_selfclose ~r/<script\b[^>]*\/>/is
  @foreign_object ~r/<foreignObject\b[^>]*>.*?<\/foreignObject\s*>/is
  @on_handler ~r/\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/is
  @js_uri ~r/(href|xlink:href|src)\s*=\s*("|')\s*javascript:[^"']*(\2)/is
  @doctype ~r/<!DOCTYPE[^>]*>/is
  @entity ~r/<!ENTITY[^>]*>/is

  @doc "Return a sanitized copy of the SVG markup."
  @spec sanitize(binary()) :: binary()
  def sanitize(svg) when is_binary(svg) do
    svg
    |> strip(@script)
    |> strip(@script_selfclose)
    |> strip(@foreign_object)
    |> strip(@on_handler)
    |> neutralize_js_uri()
    |> strip(@doctype)
    |> strip(@entity)
  end

  defp strip(markup, regex), do: Regex.replace(regex, markup, "")

  # Replace a `javascript:` URI value with an inert empty anchor, keeping
  # the attribute name + quote style intact so the markup stays valid.
  defp neutralize_js_uri(markup), do: Regex.replace(@js_uri, markup, "\\1=\\2#\\3")
end
