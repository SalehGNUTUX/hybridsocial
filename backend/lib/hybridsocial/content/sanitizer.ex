defmodule Hybridsocial.Content.Sanitizer do
  @moduledoc """
  Content sanitization for posts and DMs. Delegates markdown parsing to
  `Hybridsocial.Content.MarkdownRenderer` (Earmark + HtmlSanitizeEx), then
  applies link attributes (rel, target) for safety on external URLs.

  Level accepts `:none | :basic | :full | :full_embeds` or the string
  equivalents used by `Hybridsocial.Premium.TierLimits`. Default is
  `:basic` so callers that don't pass a level get safe behavior.
  """

  alias Hybridsocial.Content.MarkdownRenderer

  @link_attrs %{
    "rel" => "nofollow noopener noreferrer",
    "target" => "_blank"
  }

  @allowed_schemes ["http://", "https://"]

  def sanitize_post_content(content, level \\ :basic)
  def sanitize_post_content(nil, _level), do: nil
  def sanitize_post_content("", _level), do: ""

  def sanitize_post_content(content, level) when is_binary(content) do
    content
    |> MarkdownRenderer.render(level)
    |> sanitize_links()
  end

  @doc "Markdown to HTML at the given level. Defaults to :basic."
  def markdown_to_html(text, level \\ :basic) do
    MarkdownRenderer.render(text, level)
  end

  @doc """
  Applies safe link attributes. External `http(s)` links get
  `rel="nofollow noopener noreferrer"` and `target="_blank"`; internal
  links (`/foo`) are left alone. Anything else becomes `href="#"`.
  Exposed for callers that already have HTML and just want link safety.
  """
  def sanitize_links(html) do
    Regex.replace(~r/<a\s[^>]*>/u, html, fn tag ->
      href =
        case Regex.run(~r/href="([^"]*)"/, tag) do
          [_, url] -> url
          _ -> "#"
        end

      existing_attrs = preserve_attrs(tag, ["class", "title"])

      cond do
        String.starts_with?(href, @allowed_schemes) ->
          safe_href = escape_attr(href)
          attrs = Enum.map_join(@link_attrs, " ", fn {k, v} -> ~s(#{k}="#{v}") end)
          ~s(<a href="#{safe_href}" #{attrs}#{existing_attrs}>)

        String.starts_with?(href, "/") ->
          safe_href = escape_attr(href)
          ~s(<a href="#{safe_href}"#{existing_attrs}>)

        true ->
          ~s(<a href="#"#{existing_attrs}>)
      end
    end)
  end

  defp preserve_attrs(tag, attrs) do
    attrs
    |> Enum.map(fn attr ->
      case Regex.run(~r/#{attr}="([^"]*)"/, tag) do
        [_, value] -> ~s( #{attr}="#{escape_attr(value)}")
        _ -> ""
      end
    end)
    |> Enum.join()
  end

  defp escape_attr(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
