defmodule HybridsocialWeb.Api.V1.Admin.EmailTemplatesController do
  use HybridsocialWeb, :controller

  alias Hybridsocial.Auth.RBAC
  alias Hybridsocial.Emails.{Templates, Defaults}
  alias Hybridsocial.Moderation

  defp require_permission(conn, permission) do
    identity = conn.assigns.current_identity

    if RBAC.has_permission?(identity.id, permission) do
      :ok
    else
      {:error, permission}
    end
  end

  defp deny(conn, permission) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "permission.denied", required: permission})
  end

  # GET /api/v1/admin/email_templates
  def index(conn, _params) do
    with :ok <- require_permission(conn, "settings.view") do
      json(conn, %{data: Templates.list_for_admin()})
    else
      {:error, perm} -> deny(conn, perm)
    end
  end

  # PUT /api/v1/admin/email_templates/:key
  def update(conn, %{"key" => key} = params) do
    with :ok <- require_permission(conn, "settings.manage") do
      admin_id = conn.assigns.current_identity.id

      attrs = %{
        "subject" => params["subject"],
        "html_body" => params["html_body"],
        "enabled" => Map.get(params, "enabled", true)
      }

      case Templates.upsert(key, attrs, admin_id) do
        {:ok, template} ->
          Moderation.log(admin_id, "email_template.updated", "email_template", key, %{
            enabled: template.enabled
          })

          json(conn, %{data: serialize(template)})

        {:error, :unknown_template} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "email_template.unknown", key: key})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "validation.failed", details: format_errors(changeset)})
      end
    else
      {:error, perm} -> deny(conn, perm)
    end
  end

  # POST /api/v1/admin/email_templates/:key/reset
  # Removes the override so the hardcoded default takes over.
  def reset(conn, %{"key" => key}) do
    with :ok <- require_permission(conn, "settings.manage") do
      admin_id = conn.assigns.current_identity.id

      case Templates.reset(key) do
        :ok ->
          Moderation.log(admin_id, "email_template.reset", "email_template", key, %{})
          json(conn, %{message: "email_template.reset"})

        err ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "email_template.reset_failed", details: inspect(err)})
      end
    else
      {:error, perm} -> deny(conn, perm)
    end
  end

  # POST /api/v1/admin/email_templates/:key/preview
  # Admin-only preview: renders the (possibly draft) template with
  # the catalog's sample assigns and returns {subject, html, text}.
  # If the request body includes `subject`/`html_body`, we render
  # that instead of the saved version — lets the UI preview
  # unsaved edits without persisting.
  def preview(conn, %{"key" => key} = params) do
    with :ok <- require_permission(conn, "settings.view") do
      case Templates.catalog_entry(key) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "email_template.unknown", key: key})

        entry ->
          {subject, html, text} = preview_render(entry, params)
          json(conn, %{subject: subject, html: html, text: text})
      end
    else
      {:error, perm} -> deny(conn, perm)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp preview_render(entry, params) do
    # Use draft subject/html if provided, otherwise resolve the
    # saved template (or the default if none). The draft HTML goes
    # through the same sanitizer as a real save so admins can't
    # preview something that would be stripped on write.
    draft_subject = params["subject"]
    draft_html = params["html_body"]

    {base_subject, base_html} =
      if is_binary(draft_subject) and is_binary(draft_html) do
        {draft_subject, HtmlSanitizeEx.html5(draft_html)}
      else
        case Templates.resolve(entry.key) do
          {s, h, _} when is_binary(s) and is_binary(h) -> {s, h}
          _ -> Defaults.for(entry.key)
        end
      end

    # Real instance name + logo header override the placeholder sample so the
    # preview matches what recipients actually receive; per-recipient fields
    # (user.handle, confirm_url, …) stay as sample data.
    assigns = Map.merge(entry.sample, Hybridsocial.Emails.global_assigns())

    rendered_html = substitute(base_html, assigns, :html)
    rendered_subject = substitute(base_subject, assigns, :text)

    rendered_text =
      rendered_html
      |> HtmlSanitizeEx.strip_tags()
      |> String.replace(~r/[ \t]+/, " ")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    {rendered_subject, rendered_html, rendered_text}
  end

  # Mirror of Renderer's substitution for the preview path — we
  # didn't want to export the private helpers there, and the preview
  # flow needs to accept draft input that may not be saved.
  defp substitute(template, assigns, mode) do
    # Delegates to Renderer.render/2 by constructing a temporary map.
    # We still want the same `_html` pass-through behaviour, and
    # Renderer already codifies that; simplest route is to ask
    # Renderer to render a one-off "template" by temporarily reading
    # the draft via a pseudo key, but that requires touching the DB.
    # Easier: reimplement the tiny regex pass inline — it's 10 lines.
    pattern = ~r/\{\{\s*([a-zA-Z_][a-zA-Z0-9_.]*)\s*\}\}/

    Regex.replace(pattern, template, fn _match, path ->
      value = lookup(assigns, path)
      format_value(value, path, mode)
    end)
  end

  defp lookup(assigns, path) do
    path
    |> String.split(".")
    |> Enum.reduce(assigns, fn segment, acc ->
      if is_map(acc), do: Map.get(acc, segment), else: nil
    end)
  end

  defp format_value(nil, _path, _mode), do: ""
  defp format_value(v, _path, :text) when is_binary(v), do: v
  defp format_value(v, _path, :text), do: to_string(v)

  defp format_value(v, path, :html) do
    cond do
      String.ends_with?(path, "_html") and is_binary(v) -> v
      is_binary(v) -> html_escape(v)
      true -> v |> to_string() |> html_escape()
    end
  end

  defp html_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp serialize(template) do
    %{
      key: template.key,
      subject: template.subject,
      html_body: template.html_body,
      enabled: template.enabled,
      updated_at: template.updated_at,
      updated_by: template.updated_by
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
