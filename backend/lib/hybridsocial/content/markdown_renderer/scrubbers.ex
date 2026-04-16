defmodule Hybridsocial.Content.MarkdownRenderer.ScrubberNone do
  @moduledoc """
  Paragraphs + line breaks only. For free-tier posts.
  Mentions/hashtags still get linked by post-processing outside the scrubber.
  """

  use HtmlSanitizeEx

  allow_tag_with_these_attributes("p", [])
  allow_tag_with_these_attributes("br", [])
  allow_tag_with_these_attributes("a", ["href", "class"])
end

defmodule Hybridsocial.Content.MarkdownRenderer.ScrubberBasic do
  @moduledoc """
  Inline formatting only: bold, italic, inline code, links.
  Headings / lists / blockquotes / tables / images stripped.
  """

  use HtmlSanitizeEx

  allow_tag_with_these_attributes("p", [])
  allow_tag_with_these_attributes("br", [])
  allow_tag_with_these_attributes("strong", [])
  allow_tag_with_these_attributes("em", [])
  allow_tag_with_these_attributes("b", [])
  allow_tag_with_these_attributes("i", [])
  allow_tag_with_these_attributes("code", [])

  allow_tag_with_uri_attributes("a", ["href"], ["http", "https"])
  allow_tag_with_these_attributes("a", ["class", "rel", "target", "title"])
end

defmodule Hybridsocial.Content.MarkdownRenderer.ScrubberFull do
  @moduledoc """
  Adds headings, lists (ordered + unordered + nested), blockquotes,
  code blocks with fences, horizontal rules. No tables, no images.
  """

  use HtmlSanitizeEx

  allow_tag_with_these_attributes("p", [])
  allow_tag_with_these_attributes("br", [])
  allow_tag_with_these_attributes("h1", [])
  allow_tag_with_these_attributes("h2", [])
  allow_tag_with_these_attributes("h3", [])
  allow_tag_with_these_attributes("h4", [])
  allow_tag_with_these_attributes("h5", [])
  allow_tag_with_these_attributes("h6", [])
  allow_tag_with_these_attributes("ul", [])
  allow_tag_with_these_attributes("ol", ["start"])
  allow_tag_with_these_attributes("li", [])
  allow_tag_with_these_attributes("blockquote", [])
  allow_tag_with_these_attributes("pre", [])
  allow_tag_with_these_attributes("hr", [])
  allow_tag_with_these_attributes("div", ["class"])

  allow_tag_with_these_attributes("strong", [])
  allow_tag_with_these_attributes("em", [])
  allow_tag_with_these_attributes("b", [])
  allow_tag_with_these_attributes("i", [])
  allow_tag_with_these_attributes("code", ["class"])
  allow_tag_with_these_attributes("span", ["class"])

  allow_tag_with_uri_attributes("a", ["href"], ["http", "https"])
  allow_tag_with_these_attributes("a", ["class", "rel", "target", "title"])
end

defmodule Hybridsocial.Content.MarkdownRenderer.ScrubberFullEmbeds do
  @moduledoc """
  Widest allowlist: everything in :full plus GFM tables, strikethrough,
  task lists, and images (http/https sources only, no inline data: URIs).
  For verified_pro posts and admin-authored site pages.
  """

  use HtmlSanitizeEx

  allow_tag_with_these_attributes("p", [])
  allow_tag_with_these_attributes("br", [])
  allow_tag_with_these_attributes("h1", [])
  allow_tag_with_these_attributes("h2", [])
  allow_tag_with_these_attributes("h3", [])
  allow_tag_with_these_attributes("h4", [])
  allow_tag_with_these_attributes("h5", [])
  allow_tag_with_these_attributes("h6", [])
  allow_tag_with_these_attributes("ul", [])
  allow_tag_with_these_attributes("ol", ["start"])
  allow_tag_with_these_attributes("li", ["class"])
  allow_tag_with_these_attributes("blockquote", [])
  allow_tag_with_these_attributes("pre", [])
  allow_tag_with_these_attributes("hr", [])
  allow_tag_with_these_attributes("div", ["class"])

  allow_tag_with_these_attributes("del", [])
  allow_tag_with_these_attributes("s", [])
  allow_tag_with_these_attributes("table", [])
  allow_tag_with_these_attributes("thead", [])
  allow_tag_with_these_attributes("tbody", [])
  allow_tag_with_these_attributes("tr", [])
  allow_tag_with_these_attributes("th", ["align"])
  allow_tag_with_these_attributes("td", ["align"])
  allow_tag_with_these_attributes("input", ["type", "checked", "disabled"])

  allow_tag_with_these_attributes("strong", [])
  allow_tag_with_these_attributes("em", [])
  allow_tag_with_these_attributes("b", [])
  allow_tag_with_these_attributes("i", [])
  allow_tag_with_these_attributes("code", ["class"])
  allow_tag_with_these_attributes("span", ["class"])

  allow_tag_with_uri_attributes("a", ["href"], ["http", "https"])
  allow_tag_with_these_attributes("a", ["class", "rel", "target", "title"])

  allow_tag_with_uri_attributes("img", ["src"], ["http", "https"])
  allow_tag_with_these_attributes("img", ["alt", "title", "width", "height"])
end
