defmodule Hybridsocial.Emails do
  @moduledoc """
  Email builder module. Each function composes a Swoosh.Email for a
  specific transactional event, using `Hybridsocial.Emails.Renderer`
  to substitute variables into the (possibly admin-customised)
  template. Subjects and bodies live in `Emails.Defaults` as
  hardcoded fallbacks; admin overrides are stored in the
  `email_templates` table and merged transparently.
  """

  import Swoosh.Email

  alias Hybridsocial.Emails.Renderer

  @default_from {"HybridSocial", "noreply@hybridsocial.local"}

  # ── Builders ──────────────────────────────────────────────────────

  @doc "Email confirmation with a token link."
  def confirmation_email(user) do
    assigns = %{
      "instance_name" => instance_name(),
      "user" => user_assigns(user),
      "confirm_url" => "#{base_url()}/auth/confirm?token=#{user.confirmation_token}"
    }

    render("confirmation", user, assigns)
  end

  @doc "Password reset with a token link."
  def password_reset_email(user) do
    assigns = %{
      "instance_name" => instance_name(),
      "user" => user_assigns(user),
      "reset_url" => "#{base_url()}/auth/reset-password?token=#{user.reset_token}"
    }

    render("password_reset", user, assigns)
  end

  @doc """
  Alerts a staff member that a new item landed in the moderation
  queue. Throttled per-recipient by the caller.
  """
  def moderation_queue_email(to_email, _staff_identity, item) do
    assigns = %{
      "instance_name" => instance_name(),
      "item" => %{
        "item_type" => to_string(item.item_type),
        "severity" => to_string(item.severity || "medium"),
        "source" => to_string(item.source),
        "reason" => to_string(item.reason)
      },
      "queue_url" => "#{base_url()}/admin/moderation-queue"
    }

    {subject, html, text} = Renderer.render("moderation_queue", assigns)

    new()
    |> to(to_email)
    |> from(from_address())
    |> subject(subject)
    |> html_body(html)
    |> text_body(text)
  end

  @doc "Login notification alerting the user of a new sign-in."
  def login_notification_email(user, ip, user_agent) do
    assigns = %{
      "instance_name" => instance_name(),
      "user" => user_assigns(user),
      "ip" => to_string(ip),
      "user_agent" => to_string(user_agent)
    }

    render("login_notification", user, assigns)
  end

  @doc "Notification digest summarising recent notifications."
  def notification_digest_email(user, notifications) do
    count = length(notifications)
    summary_html = notifications_to_html(notifications)

    assigns = %{
      "instance_name" => instance_name(),
      "user" => user_assigns(user),
      "count" => count,
      "summary_html" => summary_html,
      "app_url" => base_url()
    }

    render("notification_digest", user, assigns)
  end

  # ── Helpers ───────────────────────────────────────────────────────

  # User-targeted emails all share the same shape: recipient pulled
  # from the `user` struct, sender from instance settings, subject +
  # html + text from the Renderer.
  defp render(key, user, assigns) do
    {subject, html, text} = Renderer.render(key, assigns)

    new()
    |> to({user_display_name(user), user_email(user)})
    |> from(from_address())
    |> subject(subject)
    |> html_body(html)
    |> text_body(text)
  end

  defp user_assigns(user) do
    %{
      "display_name" => user_display_name(user),
      "handle" => Map.get(user, :handle) || ""
    }
  end

  defp from_address do
    contact_email = Hybridsocial.Config.get("contact_email", "")
    instance_name = instance_name()

    if contact_email != "" do
      {instance_name, contact_email}
    else
      @default_from
    end
  end

  defp instance_name do
    Hybridsocial.Config.get("instance_name", "HybridSocial")
  end

  defp base_url do
    endpoint_config = Application.get_env(:hybridsocial, HybridsocialWeb.Endpoint, [])
    url_config = Keyword.get(endpoint_config, :url, [])
    host = Keyword.get(url_config, :host, "localhost")
    scheme = Keyword.get(url_config, :scheme, "https")
    port = Keyword.get(url_config, :port, 443)

    case {scheme, port} do
      {"https", 443} -> "#{scheme}://#{host}"
      {"http", 80} -> "#{scheme}://#{host}"
      _ -> "#{scheme}://#{host}:#{port}"
    end
  end

  defp user_display_name(user) do
    cond do
      Map.has_key?(user, :display_name) and user.display_name ->
        user.display_name

      Map.has_key?(user, :handle) and user.handle ->
        user.handle

      true ->
        "User"
    end
  end

  defp user_email(user), do: user.email

  defp notifications_to_html(notifications) do
    items =
      notifications
      |> Enum.map(fn n ->
        type = n[:type] || n["type"] || "unknown"
        "<li>#{escape(to_string(type))} notification</li>"
      end)
      |> Enum.join("")

    "<ul style=\"padding-left:20px;margin:0 0 16px 0;\">#{items}</ul>"
  end

  defp escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
