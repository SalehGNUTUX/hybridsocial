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

    {with_placeholders, hashtags} =
      markdown
      |> String.trim()
      |> suppress_indented_code()
      |> stash_hashtags()

    with_placeholders
    |> render_with_earmark(level)
    |> sanitize(level)
    |> restore_hashtags(hashtags)
    |> post_process()
  end

  @doc "Render with the widest possible feature set. For admin-authored content."
  def render_trusted(nil), do: ""
  def render_trusted(""), do: ""

  def render_trusted(markdown) when is_binary(markdown) do
    {with_placeholders, hashtags} =
      markdown
      |> String.trim()
      |> suppress_indented_code()
      |> stash_hashtags()

    with_placeholders
    |> render_with_earmark(:full_embeds)
    |> sanitize(:full_embeds)
    |> restore_hashtags(hashtags)
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

  # Earmark sees `_` as italic, so a hashtag like `#foo_bar_baz` would
  # come out of the renderer as `#foo<em>bar</em>baz` and the
  # post-process regex would never match the full tag. To dodge that
  # we lift hashtags out of the source *before* Earmark runs, swap in
  # a marker that has no markdown-special characters, then splice the
  # rendered anchors back in after sanitization.
  # The prefix class also excludes `[` so a hashtag used as markdown link
  # text — `[#tag](url)` — is left for Earmark to render as the link; stashing
  # it would splice a `/tags/…` anchor inside the link's <a>, nesting anchors.
  @hashtag_re ~r/(^|[^\p{L}\p{M}\p{N}_>"\/\[])#(\p{L}[\p{L}\p{M}\p{N}_]{0,100})/u

  defp stash_hashtags(text) do
    # Walk the regex matches in order, replacing each `prefix#tag`
    # with `prefix<<<HASHTAGn>>>`. The marker has no markdown-special
    # characters so Earmark passes it through untouched, and the tag
    # text — which may contain underscores — never reaches the
    # emphasis parser.
    matches = Regex.scan(@hashtag_re, text, return: :index)

    {out, last_off, tags, _idx} =
      Enum.reduce(matches, {"", 0, [], 0}, fn match, {acc, off, tags, idx} ->
        [{full_off, full_len}, _, {tag_off, tag_len}] = match
        prefix_len = full_len - 1 - tag_len
        head = binary_part(text, off, full_off - off)
        prefix = binary_part(text, full_off, prefix_len)
        tag = binary_part(text, tag_off, tag_len)
        marker = "<<<HASHTAG#{idx}>>>"
        {acc <> head <> prefix <> marker, full_off + full_len, [{idx, tag} | tags], idx + 1}
      end)

    body = out <> binary_part(text, last_off, byte_size(text) - last_off)
    {body, tags |> Enum.reverse() |> Enum.into(%{})}
  end

  defp restore_hashtags(html, hashtags) when map_size(hashtags) == 0, do: html

  defp restore_hashtags(html, hashtags) do
    Regex.replace(~r/&lt;&lt;&lt;HASHTAG(\d+)&gt;&gt;&gt;|<<<HASHTAG(\d+)>>>/, html, fn _full,
                                                                                        idx_a,
                                                                                        idx_b ->
      idx = String.to_integer(if idx_a == "", do: idx_b, else: idx_a)

      case Map.get(hashtags, idx) do
        nil ->
          ""

        tag ->
          slug = String.downcase(tag) |> URI.encode()
          "<a href=\"/tags/#{slug}\" class=\"hashtag\">##{tag}</a>"
      end
    end)
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

  # CommonMark turns any line indented by 4+ spaces (or a tab) into an
  # indented code block — `<pre><code>…</code></pre>`, monospace font,
  # no inline formatting. On a social feed that's almost never what the
  # author wanted: a user pasting Arabic / multilingual text from
  # another editor often picks up stray leading whitespace and the
  # whole paragraph silently switches to a monospace code block. Users
  # who actually want code blocks reach for fenced ``` syntax.
  #
  # We walk lines, track whether we're inside a fenced code block
  # (toggled by ``` or ~~~ at the start of a line, after up to 3
  # spaces of indent), and outside of fences clamp leading whitespace
  # to 3 spaces. List markers typically sit within 0–3 spaces, so list
  # continuations keep their visual indentation; only the >=4-space
  # rule that triggers indented code blocks is suppressed.
  defp suppress_indented_code(text) do
    {out, _in_fence} =
      text
      |> String.split("\n")
      |> Enum.map_reduce(false, fn line, in_fence ->
        cond do
          fence_line?(line) ->
            {line, not in_fence}

          in_fence ->
            {line, in_fence}

          true ->
            {clamp_leading_spaces(line, 3), in_fence}
        end
      end)

    Enum.join(out, "\n")
  end

  defp fence_line?(line) do
    Regex.match?(~r/^ {0,3}(```|~~~)/, line)
  end

  defp clamp_leading_spaces(line, max) do
    case Regex.run(~r/^( +)(.*)$/s, line) do
      [_, leading, rest] when byte_size(leading) > max ->
        String.duplicate(" ", max) <> rest

      _ ->
        line
    end
  end

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
