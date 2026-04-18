defmodule Hybridsocial.Notifications.Delivery.Email do
  @moduledoc """
  Email notification delivery channel.

  Composes and sends notification emails via `Hybridsocial.Mailer`,
  rendering through `Hybridsocial.Emails.Renderer` so admins can
  rebrand the generic "@alice followed you" emails via
  `/admin/email-templates` (key: `generic_notification`).
  """

  @behaviour Hybridsocial.Notifications.Delivery

  import Swoosh.Email

  alias Hybridsocial.Repo
  alias Hybridsocial.Accounts.Identity
  alias Hybridsocial.Emails.Renderer

  require Logger

  @impl true
  def deliver(recipient_id, payload, _opts) do
    case fetch_recipient_email(recipient_id) do
      {:ok, email_address} ->
        assigns = build_assigns(payload)
        {subject, html, text} = Renderer.render("generic_notification", assigns)

        email =
          new()
          |> to(email_address)
          |> from({instance_name(), from_address()})
          |> subject(subject)
          |> text_body(text)
          |> html_body(html)

        case Hybridsocial.Mailer.deliver(email) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("Email notification delivery failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.debug("Skipping email notification: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def channel_name, do: :email

  @impl true
  def available? do
    config = Application.get_env(:hybridsocial, Hybridsocial.Mailer)
    config != nil and Keyword.get(config, :adapter) != nil
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Build the template assigns from the notification payload. `url`
  # falls back to `/notifications` so the button always points at
  # something useful even if the upstream producer forgot to set it.
  defp build_assigns(payload) do
    url = get_in(payload, [Access.key(:data, %{}), :url]) || "/notifications"

    %{
      "instance_name" => instance_name(),
      "title" => to_string(payload.title || ""),
      "body" => to_string(payload.body || ""),
      "url" => absolute_url(url),
      "app_url" => base_url()
    }
  end

  # Relative path → absolute URL so email clients (which have no
  # origin) don't give us broken links. Idempotent for already-
  # absolute URLs.
  defp absolute_url("http" <> _ = url), do: url
  defp absolute_url("/" <> _ = path), do: base_url() <> path
  defp absolute_url(other), do: base_url() <> "/" <> to_string(other)

  defp fetch_recipient_email(recipient_id) do
    identity =
      Identity
      |> Repo.get(recipient_id)
      |> Repo.preload(:user)

    case identity do
      %Identity{user: %{email: email}} when is_binary(email) and email != "" ->
        {:ok, email}

      _ ->
        {:error, :no_email}
    end
  end

  defp instance_name do
    Hybridsocial.Config.get("instance_name", "HybridSocial")
  end

  defp from_address do
    Hybridsocial.Config.get("notification_from_email", "notifications@localhost")
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
end
