defmodule HybridsocialWeb.Api.V1.InstanceController do
  use HybridsocialWeb, :controller

  def show(conn, _params) do
    json(conn, Hybridsocial.Instance.info())
  end

  def info(conn, _params) do
    provider = Hybridsocial.Auth.Captcha.provider()
    site_key = Hybridsocial.Auth.Captcha.site_key()
    reg_mode = Hybridsocial.Config.get("registration_mode", "open")

    json(conn, %{
      # Provider-agnostic captcha config the frontend widget reads.
      captcha_provider: provider || "none",
      captcha_site_key: site_key,
      # Back-compat: older frontends only understood Turnstile.
      turnstile_enabled: provider == "turnstile",
      turnstile_site_key: if(provider == "turnstile", do: site_key, else: ""),
      registration_mode: reg_mode,
      # Shown on the email-confirmation gate so a stuck user knows where to
      # get help. Admin-set (Instance > General); empty when unconfigured.
      contact_email: Hybridsocial.Config.get("contact_email", ""),
      version: Hybridsocial.Instance.version(),
      # Build identity so admins can confirm exactly which commit is running
      # (deploys are rsync + rebuild, so the semver alone isn't enough).
      build: %{
        sha: Hybridsocial.Instance.build_sha(),
        date: Hybridsocial.Instance.build_date()
      },
      # Upstream source — admins can point this at a fork in config,
      # otherwise defaults to the canonical repo. Used by the footer
      # "view source" link.
      source_url: Hybridsocial.Config.get("source_url", "https://github.com/qfiber/hybridsocial")
    })
  end

  def online_count(conn, _params) do
    import Ecto.Query

    cutoff = DateTime.add(DateTime.utc_now(), -300, :second)

    count =
      from(u in "users", where: u.last_login_at > ^cutoff, select: count(u.identity_id))
      |> Hybridsocial.Repo.one() || 0

    json(conn, %{count: count})
  end
end
