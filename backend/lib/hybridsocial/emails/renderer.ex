defmodule Hybridsocial.Emails.Renderer do
  @moduledoc """
  Renders an email template to a `{subject, html, text}` tuple.

  Variables are `{{name}}` or `{{object.field}}` — a tiny Liquid-ish
  subset, evaluated via regex over the string. We deliberately do NOT
  use `EEx.eval_string/2` or any general-purpose template engine on
  admin-supplied input: that would make RCE one escape away. All
  substitution is pure string replacement and any missing variable
  collapses to empty string (not `{{var}}`), so nothing embarrassing
  leaks to users if an admin removes a variable the code still
  passes.

  Substituted values are HTML-escaped (via `Plug.HTML.html_escape/1`),
  except for variables whose name ends with `_html` — those are
  trusted pre-rendered HTML (like `summary_html` for the digest).
  """

  alias Hybridsocial.Emails.Templates

  @doc """
  Render the template by key. `assigns` is a map keyed by string —
  keys can be flat (`"instance_name"`) or nested via dot paths inside
  the template (`{{user.handle}}` resolves `assigns["user"]["handle"]`).

  Returns `{subject, html, text}`. The text body is auto-derived from
  the HTML via `HtmlSanitizeEx.strip_tags/1` so we always send a
  multipart message (some clients + spam filters penalise HTML-only).
  """
  def render(key, assigns) when is_binary(key) and is_map(assigns) do
    {subject_tpl, html_tpl, _customized?} = Templates.resolve(key)

    subject = substitute(subject_tpl, assigns, mode: :text)
    html = substitute(html_tpl, assigns, mode: :html)
    text = html_to_text(html)

    {subject, html, text}
  end

  # ── Substitution ──────────────────────────────────────────────────

  # Matches {{ identifier }} or {{ a.b.c }}. Whitespace inside braces
  # is tolerated. Any identifier the assigns don't define resolves
  # to empty string, same as most template engines.
  @var_pattern ~r/\{\{\s*([a-zA-Z_][a-zA-Z0-9_.]*)\s*\}\}/

  defp substitute(template, assigns, opts) when is_binary(template) do
    mode = Keyword.get(opts, :mode, :text)

    Regex.replace(@var_pattern, template, fn _match, path ->
      value = lookup(assigns, path)
      format_value(value, path, mode)
    end)
  end

  defp lookup(assigns, path) when is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce(assigns, fn segment, acc ->
      cond do
        is_map(acc) -> Map.get(acc, segment) || Map.get(acc, String.to_atom(segment))
        true -> nil
      end
    end)
  end

  defp format_value(nil, _path, _mode), do: ""
  defp format_value(value, _path, :text) when is_binary(value), do: value
  defp format_value(value, _path, :text), do: to_string(value)

  defp format_value(value, path, :html) do
    cond do
      # Convention: a variable named `*_html` carries pre-sanitized,
      # pre-rendered HTML that should pass through unescaped.
      String.ends_with?(path, "_html") and is_binary(value) ->
        value

      is_binary(value) ->
        html_escape(value)

      true ->
        value |> to_string() |> html_escape()
    end
  end

  # Minimal HTML escape — avoids pulling in Plug/Phoenix.HTML here
  # (this module is called from email builders, not request handlers).
  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  # ── HTML → text ───────────────────────────────────────────────────

  # HtmlSanitizeEx.strip_tags/1 drops every tag and leaves just the
  # text content. We then normalize whitespace — tables render as a
  # run of spaces otherwise, which looks bad in text-only clients.
  defp html_to_text(html) when is_binary(html) do
    html
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
