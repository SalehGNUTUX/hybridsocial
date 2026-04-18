defmodule Hybridsocial.Emails.Templates do
  @moduledoc """
  Admin-managed email templates. The catalog is authoritative — each
  entry declares its key, display name, the variables it accepts, and
  a sample-data map the admin preview uses. Keys that aren't in the
  catalog are rejected so an admin can't create arbitrary templates
  that no emitter ever reads.
  """

  alias Hybridsocial.Repo
  alias Hybridsocial.Emails.{Template, Defaults}

  # Each entry:
  #   key:         DB key + code-side identifier
  #   name:        shown in admin UI
  #   description: short hint in admin UI
  #   variables:   map of variable name => short description (for UI chips)
  #   sample:      preview data used by the admin "Preview" action
  @catalog [
    %{
      key: "confirmation",
      name: "Email confirmation",
      description: "Sent after registration with a link to verify the user's email.",
      variables: %{
        "instance_name" => "Instance display name",
        "user.display_name" => "Recipient's display name",
        "user.handle" => "Recipient's handle",
        "confirm_url" => "Absolute URL to the confirmation link"
      },
      sample: %{
        "instance_name" => "HybridSocial",
        "user" => %{"display_name" => "Sample User", "handle" => "sample"},
        "confirm_url" => "https://example.com/auth/confirm?token=abc123"
      }
    },
    %{
      key: "password_reset",
      name: "Password reset",
      description: "Sent when a user (or admin on their behalf) requests a password reset.",
      variables: %{
        "instance_name" => "Instance display name",
        "user.display_name" => "Recipient's display name",
        "user.handle" => "Recipient's handle",
        "reset_url" => "Absolute URL to the reset form"
      },
      sample: %{
        "instance_name" => "HybridSocial",
        "user" => %{"display_name" => "Sample User", "handle" => "sample"},
        "reset_url" => "https://example.com/auth/reset-password?token=abc123"
      }
    },
    %{
      key: "moderation_queue",
      name: "Moderation queue alert",
      description: "Alerts staff when a new item lands in the moderation queue.",
      variables: %{
        "instance_name" => "Instance display name",
        "item.item_type" => "Type of flagged item (post, account, etc.)",
        "item.severity" => "low / medium / high",
        "item.source" => "Where the flag came from",
        "item.reason" => "Why it was flagged",
        "queue_url" => "Absolute URL to the admin queue"
      },
      sample: %{
        "instance_name" => "HybridSocial",
        "item" => %{
          "item_type" => "post",
          "severity" => "high",
          "source" => "content filter",
          "reason" => "matched the `spam-url` rule"
        },
        "queue_url" => "https://example.com/admin/moderation-queue"
      }
    },
    %{
      key: "login_notification",
      name: "New login notification",
      description: "Alerts a user to a new sign-in from an unfamiliar device or location.",
      variables: %{
        "instance_name" => "Instance display name",
        "user.display_name" => "Recipient's display name",
        "ip" => "IP address of the login",
        "user_agent" => "Browser / app identifier"
      },
      sample: %{
        "instance_name" => "HybridSocial",
        "user" => %{"display_name" => "Sample User", "handle" => "sample"},
        "ip" => "203.0.113.42",
        "user_agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
      }
    },
    %{
      key: "notification_digest",
      name: "Notification digest",
      description: "Summarises recent in-app notifications for users who opted in.",
      variables: %{
        "instance_name" => "Instance display name",
        "user.display_name" => "Recipient's display name",
        "count" => "Number of notifications summarised",
        "summary_html" => "Pre-rendered HTML list of notifications",
        "app_url" => "Absolute URL back to the app"
      },
      sample: %{
        "instance_name" => "HybridSocial",
        "user" => %{"display_name" => "Sample User", "handle" => "sample"},
        "count" => 3,
        "summary_html" => "<ul><li>@alice followed you</li><li>@bob replied to your post</li><li>@carol mentioned you</li></ul>",
        "app_url" => "https://example.com"
      }
    }
  ]

  @doc "Static catalog of editable templates."
  def catalog, do: @catalog

  def catalog_keys, do: Enum.map(@catalog, & &1.key)

  def catalog_entry(key) when is_binary(key) do
    Enum.find(@catalog, &(&1.key == key))
  end

  @doc "Returns stored overrides or nil per catalog key."
  def get(key) when is_binary(key), do: Repo.get(Template, key)

  @doc """
  Returns `{subject, html_body, enabled?}` from the stored override if
  present + enabled, else the hardcoded default shipped with the code.
  """
  def resolve(key) when is_binary(key) do
    case get(key) do
      %Template{enabled: true, subject: s, html_body: h} when is_binary(s) and is_binary(h) ->
        {s, h, true}

      _ ->
        {default_subject, default_html} = Defaults.for(key)
        {default_subject, default_html, false}
    end
  end

  @doc """
  Upsert an admin override. Sanitises the HTML aggressively and
  rejects unknown keys. The caller's identity_id is stamped on the
  row for audit purposes — same rationale as `created_by` on other
  admin-editable rows.
  """
  def upsert(key, attrs, updated_by) when is_binary(key) do
    if catalog_entry(key) == nil do
      {:error, :unknown_template}
    else
      sanitized =
        attrs
        |> Map.put("key", key)
        |> Map.put("updated_by", updated_by)
        |> Map.update("html_body", "", &sanitize_html/1)

      case get(key) do
        nil -> %Template{key: key}
        existing -> existing
      end
      |> Template.changeset(sanitized)
      |> Repo.insert_or_update()
    end
  end

  @doc "Remove the override entirely so the hardcoded default is used."
  def reset(key) when is_binary(key) do
    case get(key) do
      nil -> :ok
      template -> Repo.delete(template) |> case do
        {:ok, _} -> :ok
        err -> err
      end
    end
  end

  @doc "Returns admin-facing list: catalog merged with stored overrides."
  def list_for_admin do
    overrides = Template |> Repo.all() |> Map.new(&{&1.key, &1})

    Enum.map(@catalog, fn entry ->
      stored = Map.get(overrides, entry.key)
      {default_subject, default_html} = Defaults.for(entry.key)

      %{
        key: entry.key,
        name: entry.name,
        description: entry.description,
        variables: entry.variables,
        default_subject: default_subject,
        default_html: default_html,
        subject: (stored && stored.subject) || default_subject,
        html_body: (stored && stored.html_body) || default_html,
        enabled: stored == nil or stored.enabled,
        customized: stored != nil,
        updated_at: stored && stored.updated_at
      }
    end)
  end

  # HtmlSanitizeEx ships a strict scrubber that drops <script>,
  # <iframe>, event handlers, and javascript: URLs — all the things we
  # don't want an admin to paste in and then broadcast to every user
  # via transactional email. `html5` keeps the tags we actually need
  # (div/p/a/img/table/style-attribute) for email styling.
  defp sanitize_html(html) when is_binary(html) do
    HtmlSanitizeEx.html5(html)
  end

  defp sanitize_html(_), do: ""
end
