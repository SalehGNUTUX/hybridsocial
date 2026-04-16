defmodule Hybridsocial.Content.MarkdownRendererTest do
  use ExUnit.Case, async: true

  alias Hybridsocial.Content.MarkdownRenderer

  describe "level :none" do
    test "strips all markup, keeps paragraphs and line breaks" do
      html = MarkdownRenderer.render("**bold** and *italic*", :none)
      refute html =~ "<strong>"
      refute html =~ "<em>"
      assert html =~ "<p>"
    end

    test "still escapes HTML" do
      html = MarkdownRenderer.render("<script>alert(1)</script>", :none)
      refute html =~ "<script>"
    end

    test "keeps mentions and hashtags as linked" do
      html = MarkdownRenderer.render("hey @alice check #music", :none)
      assert html =~ ~s(href="/@alice")
      assert html =~ ~s(href="/tags/music")
    end
  end

  describe "level :basic" do
    test "allows inline formatting" do
      html = MarkdownRenderer.render("**bold** *italic* `code`", :basic)
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>italic</em>"
      assert html =~ "<code>code</code>"
    end

    test "strips headings and lists" do
      html = MarkdownRenderer.render("# big\n\n- item", :basic)
      refute html =~ "<h1>"
      refute html =~ "<ul>"
      refute html =~ "<li>"
    end

    test "keeps simple links" do
      html = MarkdownRenderer.render("[text](https://example.com)", :basic)
      assert html =~ "<a"
      assert html =~ ~s(href="https://example.com")
    end

    test "rejects javascript: links" do
      html = MarkdownRenderer.render("[xss](javascript:alert(1))", :basic)
      refute html =~ "javascript:"
    end
  end

  describe "level :full" do
    test "allows headings, ordered lists, blockquotes, code fences, HR" do
      markdown = "# Heading\n\n1. First\n2. Second\n\n> quote\n\n---\n"

      html = MarkdownRenderer.render(markdown, :full)
      assert html =~ "<h1>"
      assert html =~ "<ol>"
      assert html =~ "<li>"
      assert html =~ "<blockquote>"
      assert html =~ "<hr"
    end

    test "allows fenced code blocks" do
      markdown = "```\ncode block\n```"
      html = MarkdownRenderer.render(markdown, :full)
      assert html =~ "<pre>"
    end

    test "strips tables and images (embeds tier only)" do
      table = Enum.join(["| a | b |", "|---|---|", "| 1 | 2 |"], "\n")
      img = "![alt](https://example.com/img.png)"
      html = MarkdownRenderer.render(table <> "\n\n" <> img, :full)
      refute html =~ "<table>"
      refute html =~ "<img"
    end
  end

  describe "level :full_embeds" do
    test "allows GFM tables" do
      markdown = Enum.join(["| a | b |", "|---|---|", "| 1 | 2 |"], "\n")
      html = MarkdownRenderer.render(markdown, :full_embeds)
      assert html =~ "<table>"
      assert html =~ "<thead>"
      assert html =~ "<td"
    end

    test "allows images with http(s) src" do
      markdown = "![Alt](https://example.com/pic.png)"
      html = MarkdownRenderer.render(markdown, :full_embeds)
      assert html =~ "<img"
      assert html =~ ~s(src="https://example.com/pic.png")
    end

    test "strips javascript: and data: image sources" do
      html = MarkdownRenderer.render("![x](javascript:alert(1))", :full_embeds)
      refute html =~ "javascript:"

      html2 = MarkdownRenderer.render("![x](data:text/html;base64,abc)", :full_embeds)
      refute html2 =~ "data:text"
    end

    test "allows strikethrough" do
      html = MarkdownRenderer.render("~~gone~~", :full_embeds)
      assert html =~ "<del>"
    end
  end

  describe "XSS resistance" do
    test "escapes <script> at every level" do
      payload = "<script>alert('xss')</script>"

      for level <- [:none, :basic, :full, :full_embeds] do
        html = MarkdownRenderer.render(payload, level)
        refute html =~ "<script>", "level #{level} leaked <script>"
      end
    end

    test "strips on* event handlers" do
      payload = "<a href=\"#\" onclick=\"alert(1)\">click</a>"
      html = MarkdownRenderer.render(payload, :full_embeds)
      refute html =~ "onclick"
    end

    test "strips <iframe> even in full_embeds" do
      html = MarkdownRenderer.render("<iframe src=\"evil\"></iframe>", :full_embeds)
      refute html =~ "<iframe"
    end
  end

  describe "render_trusted/1" do
    test "has the full embeds surface" do
      markdown = Enum.join(["| a | b |", "|---|---|", "| 1 | 2 |"], "\n")
      html = MarkdownRenderer.render_trusted(markdown)
      assert html =~ "<table>"
    end

    test "still strips scripts (trusted is not the same as unsafe)" do
      html = MarkdownRenderer.render_trusted("<script>alert(1)</script>")
      refute html =~ "<script>"
    end
  end

  describe "mentions and hashtags" do
    test "linked inside a paragraph at basic level" do
      html = MarkdownRenderer.render("hi @bob #topic", :basic)
      assert html =~ ~s(href="/@bob")
      assert html =~ ~s(href="/tags/topic")
    end

    test "does not double-link inside existing anchors" do
      html = MarkdownRenderer.render("[#notatag](https://example.com/#notatag)", :basic)
      refute html =~ ~s(href="/tags/notatag")
    end
  end
end
