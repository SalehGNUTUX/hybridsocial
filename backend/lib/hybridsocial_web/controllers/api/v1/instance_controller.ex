defmodule HybridsocialWeb.Api.V1.InstanceController do
  use HybridsocialWeb, :controller

  def show(conn, _params) do
    json(conn, Hybridsocial.Instance.info())
  end

  def info(conn, _params) do
    turnstile_key = Hybridsocial.Config.Store.get("turnstile_site_key", "")
    reg_mode = Hybridsocial.Config.get("registration_mode", "open")

    json(conn, %{
      turnstile_enabled: turnstile_key != "",
      turnstile_site_key: turnstile_key,
      registration_mode: reg_mode,
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
