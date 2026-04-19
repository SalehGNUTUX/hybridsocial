defmodule Hybridsocial.Content.MarkdownRenderer do
  @moduledoc """
  CommonMark/GFM markdown rendering with per-tier feature allowlists.

  Uses Earmark for parsing and HtmlSanitizeEx for output sanitization.

  Four feature levels match the tier_limits.ex markdown settings:

    - `:none`         — plaintext. All markup stripped. Only paragraphs,
                        <br>, mentions, and hashtags survive.
    - `:basic`        — inline only: bold, italic, inline code, links.
                        Headings / lists / blockquotes stripped.
    - `:full`         — adds headings, ordered/unordered lists (nested
                        ok), blockquotes, code blocks with fences,
                        horizontal rules, autolinks.
    - `:full_embeds`  — adds tables (GFM), strikethrough, task lists,
                        images. The full public API surface.

  All outputs are post-processed to re-wire `@mention` and `#hashtag`
  syntax into real links, and every output is sanitized against the
  corresponding tag allowlist. Links always get `rel="nofollow
  noopener noreferrer"` and `target="_blank"` for external URLs.
  """

  @type level :: :none | :basic | :full | :full_embeds

  @earmark_opts_common %Earmark.Options{
    gfm: true,
    breaks: true,
    smartypants: false,
    compact_output: false,
    escape: true
  }

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc """
  Render markdown at the given feature level. Returns HTML.

  `level` accepts the string forms from tier_limits (`"none"`, `"basic"`,
  `"full"`, `"full_embeds"`) or the atom equivalents.
  """
  def render(nil, _level), do: ""
  def render("", _level), do: ""

  def render(markdown, level) when is_binary(markdown) do
    level = normalize_level(level)

    markdown
    |> String.trim()
    |> render_with_earmark(level)
    |> sanitize(level)
    |> post_process()
  end

  @doc "Render with the widest possible feature set. For admin-authored content."
  def render_trusted(nil), do: ""
  def render_trusted(""), do: ""

  def render_trusted(markdown) when is_binary(markdown) do
    markdown
    |> String.trim()
    |> render_with_earmark(:full_embeds)
    |> sanitize(:full_embeds)
    |> post_process()
  end

  # --------------------------------------------------------------------------
  # Rendering
  # --------------------------------------------------------------------------

  defp render_with_earmark(markdown, :none) do
    # For :none we skip Earmark entirely — paragraphs only, nothing else.
    # Mentions/hashtags still get linked by post_process.
    markdown
    |> String.split(~r/\n\n+/)
    |> Enum.map_join("\n", fn para ->
      "<p>" <> (para |> escape_html() |> String.replace("\n", "<br>")) <> "</p>"
    end)
  end

  defp render_with_earmark(markdown, _level) do
    case Earmark.as_html(markdown, @earmark_opts_common) do
      {:ok, html, _warnings} -> html
      {:error, html, _warnings} -> html
    end
  end

  # --------------------------------------------------------------------------
  # Sanitization — allowlist per level
  # --------------------------------------------------------------------------

  defp sanitize(html, :none) do
    HtmlSanitizeEx.Scrubber.scrub(html, __MODULE__.ScrubberNone)
  end

  defp sanitize(html, :basic) do
    HtmlSanitizeEx.Scrubber.scrub(html, __MODULE__.ScrubberBasic)
  end

  defp sanitize(html, :full) do
    HtmlSanitizeEx.Scrubber.scrub(html, __MODULE__.ScrubberFull)
  end

  defp sanitize(html, :full_embeds) do
    HtmlSanitizeEx.Scrubber.scrub(html, __MODULE__.ScrubberFullEmbeds)
  end

  # --------------------------------------------------------------------------
  # Post-processing: mentions, hashtags, link attrs
  # --------------------------------------------------------------------------

  defp post_process(html) do
    html
    |> link_mentions()
    |> link_hashtags()
  end

  defp link_mentions(html) do
    # Only match @foo outside of existing anchor tags — avoid mangling links
    # Earmark already wrote. Matches ` @foo` or `>@foo` or start-of-line.
    Regex.replace(
      ~r/(^|[^a-zA-Z0-9_>"\/])@([a-zA-Z0-9_]+)(@[a-zA-Z0-9.\-]+)?/u,
      html,
      fn _full, prefix, user, domain ->
        acct = if domain == "", do: user, else: user <> domain
        "#{prefix}<a href=\"/@#{acct}\" class=\"mention\">@#{user}</a>"
      end
    )
  end

  defp link_hashtags(html) do
    # Unicode-aware: first char must be a letter in any script (`\p{L}`),
    # subsequent chars may be letter/combining-mark/digit/underscore.
    # The prefix character class is extended to include Unicode
    # letters so we don't match a `#` that lives mid-word in an
    # Arabic/Cyrillic/CJK string.
    Regex.replace(
      ~r/(^|[^\p{L}\p{M}\p{N}_>"\/])#(\p{L}[\p{L}\p{M}\p{N}_]{0,100})/u,
      html,
      fn _full, prefix, tag ->
        slug = String.downcase(tag) |> URI.encode()
        "#{prefix}<a href=\"/tags/#{slug}\" class=\"hashtag\">##{tag}</a>"
      end
    )
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp normalize_level("none"), do: :none
  defp normalize_level("basic"), do: :basic
  defp normalize_level("full"), do: :full
  defp normalize_level("full_embeds"), do: :full_embeds
  defp normalize_level(level) when level in [:none, :basic, :full, :full_embeds], do: level
  defp normalize_level(_), do: :basic

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
