defmodule Hybridsocial.Moderation do
  @moduledoc """
  The Moderation context. Manages reports, audit log, content filters,
  banned domains, and moderation webhooks.
  """
  import Ecto.Query
  alias Hybridsocial.Repo

  alias Hybridsocial.Moderation.{
    Report,
    AuditLog,
    ContentFilter,
    BannedDomain,
    Webhook,
    WebhookDelivery,
    IpBan,
    EmailDomainBan,
    Appeal,
    ModerationNote,
    QueuedItem,
    MediaHashBan,
    Takedown
  }

  alias Hybridsocial.Accounts.Identity

  # ── Reports ──────────────────────────────────────────────────────────

  def create_report(reporter_id, attrs) do
    result =
      %Report{}
      |> Report.changeset(Map.put(attrs, "reporter_id", reporter_id))
      |> Repo.insert()

    with {:ok, report} <- result do
      # Keep the denormalized open-report counter on posts in sync so
      # the admin moderation shield badge is O(1) to read on timeline
      # fetches. Non-post reports (account reports) are tracked via
      # the reports index and don't need the counter.
      if report.target_type == "post" and is_binary(report.target_id) do
        bump_post_open_report_count(report.target_id, 1)
      end
    end

    result
  end

  defp bump_post_open_report_count(post_id, delta) when is_integer(delta) do
    # GREATEST(..., 0) clamps the count so a stale state (e.g. a
    # backfill that missed a row, or manual SQL surgery in ops) can't
    # drive it negative after a resolve.
    from(p in Hybridsocial.Social.Post,
      where: p.id == ^post_id,
      update: [
        set: [
          open_report_count:
            fragment(
              "GREATEST(COALESCE(?, 0) + ?, 0)",
              p.open_report_count,
              ^delta
            )
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  def get_report(id) do
    case Repo.get(Report, id) do
      nil -> nil
      report -> Repo.preload(report, [:reporter, :reported])
    end
  end

  def list_reports(opts \\ []) do
    Report
    |> filter_reports_by_status(opts[:status])
    |> order_by([r], desc: r.inserted_at)
    |> paginate(opts)
    |> Repo.all()
    |> Repo.preload([:reporter, :reported])
  end

  @doc """
  Hard-deletes resolved + dismissed reports whose `resolved_at` is
  older than `retention_days` days. Pending reports are never pruned
  — they still need moderator action. Returns the number of rows
  removed.
  """
  def prune_closed_reports(retention_days)
      when is_integer(retention_days) and retention_days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    {n, _} =
      Report
      |> where([r], r.status in ["resolved", "dismissed"])
      |> where([r], not is_nil(r.resolved_at))
      |> where([r], r.resolved_at < ^cutoff)
      |> Repo.delete_all()

    n
  end

  defp filter_reports_by_status(query, nil), do: query
  defp filter_reports_by_status(query, status), do: where(query, [r], r.status == ^status)

  def assign_report(report_id, moderator_id) do
    case Repo.get(Report, report_id) do
      nil ->
        {:error, :not_found}

      report ->
        report
        |> Report.assign_changeset(moderator_id)
        |> Repo.update()
    end
  end

  def resolve_report(report_id, moderator_id, action_taken) do
    case Repo.get(Report, report_id) do
      nil ->
        {:error, :not_found}

      report ->
        was_pending? = report.status == "pending"

        Ecto.Multi.new()
        |> Ecto.Multi.update(:report, Report.resolve_changeset(report, action_taken))
        |> Ecto.Multi.run(:audit, fn _repo, _changes ->
          log(moderator_id, "report.resolved", "report", report_id, %{action_taken: action_taken})
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{report: resolved}} ->
            if was_pending? and resolved.target_type == "post" and
                 is_binary(resolved.target_id) do
              bump_post_open_report_count(resolved.target_id, -1)
            end

            {:ok, resolved}

          {:error, _, changeset, _} ->
            {:error, changeset}
        end
    end
  end

  def dismiss_report(report_id, moderator_id) do
    case Repo.get(Report, report_id) do
      nil ->
        {:error, :not_found}

      report ->
        was_pending? = report.status == "pending"

        Ecto.Multi.new()
        |> Ecto.Multi.update(:report, Report.dismiss_changeset(report))
        |> Ecto.Multi.run(:audit, fn _repo, _changes ->
          log(moderator_id, "report.dismissed", "report", report_id, %{})
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{report: dismissed}} ->
            if was_pending? and dismissed.target_type == "post" and
                 is_binary(dismissed.target_id) do
              bump_post_open_report_count(dismissed.target_id, -1)
            end

            {:ok, dismissed}

          {:error, _, changeset, _} ->
            {:error, changeset}
        end
    end
  end

  # ── Audit Log ────────────────────────────────────────────────────────

  def log(actor_id, action, target_type \\ nil, target_id \\ nil, details \\ %{}, ip \\ nil) do
    %AuditLog{}
    |> AuditLog.changeset(%{
      actor_id: actor_id,
      action: action,
      target_type: target_type,
      target_id: target_id,
      details: details,
      ip_address: ip
    })
    |> Repo.insert()
  end

  def list_audit_log(opts \\ []) do
    AuditLog
    |> filter_audit_by_action(opts[:action])
    |> filter_audit_by_actor(opts[:actor_id])
    |> filter_audit_by_date_range(opts[:from], opts[:to])
    |> order_by([a], desc: a.created_at)
    |> paginate(opts)
    |> Repo.all()
    |> Repo.preload(:actor)
  end

  defp filter_audit_by_action(query, nil), do: query
  defp filter_audit_by_action(query, action), do: where(query, [a], a.action == ^action)

  defp filter_audit_by_actor(query, nil), do: query
  defp filter_audit_by_actor(query, actor_id), do: where(query, [a], a.actor_id == ^actor_id)

  defp filter_audit_by_date_range(query, nil, nil), do: query

  defp filter_audit_by_date_range(query, from, nil) do
    where(query, [a], a.created_at >= ^from)
  end

  defp filter_audit_by_date_range(query, nil, to) do
    where(query, [a], a.created_at <= ^to)
  end

  defp filter_audit_by_date_range(query, from, to) do
    where(query, [a], a.created_at >= ^from and a.created_at <= ^to)
  end

  # ── Takedowns (moderation removal + notice + appeal window) ───────────
  #
  # Records that staff removed a piece of content for a reason, notifies the
  # owner (in-app + email) with that reason and the appeal window, and gives
  # the auto-purge worker a `purge_after` deadline. The content itself is
  # soft-deleted by its own context (Groups/Pages/Posts); this only layers the
  # notice + appeal lifecycle on top.

  @default_takedown_days 60

  @doc """
  Creates a takedown record and notifies the content owner. `attrs` needs
  `:target_type`, `:target_id`, `:owner_id`, `:moderator_id`, `:reason`, and
  optional `:category`. `purge_after` is derived from `takedown_retention_days`.
  """
  def create_takedown(attrs) do
    days = takedown_retention_days()

    purge_after =
      DateTime.utc_now()
      |> DateTime.add(days * 86_400, :second)
      |> DateTime.truncate(:microsecond)

    result =
      %Takedown{}
      |> Takedown.changeset(Map.put(attrs, :purge_after, purge_after))
      |> Repo.insert()

    with {:ok, takedown} <- result do
      notify_content_owner(takedown, days)
      {:ok, takedown}
    end
  end

  @doc "The appeal window, in days, before an un-appealed takedown is purged."
  def takedown_retention_days do
    case Hybridsocial.Config.get("takedown_retention_days", @default_takedown_days) do
      n when is_integer(n) and n > 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} when n > 0 -> n
          _ -> @default_takedown_days
        end

      _ ->
        @default_takedown_days
    end
  end

  # No owner to notify (e.g. an orphaned identity) — nothing to do.
  defp notify_content_owner(%Takedown{owner_id: nil}, _days), do: :ok
  defp notify_content_owner(%Takedown{moderator_id: nil}, _days), do: :ok

  defp notify_content_owner(%Takedown{} = takedown, days) do
    # In-app notification — the bell/SSE "internal message". Actor is the
    # moderator so it isn't self-skipped.
    Hybridsocial.Notifications.create_notification(%{
      recipient_id: takedown.owner_id,
      actor_id: takedown.moderator_id,
      type: "moderation_takedown",
      target_type: notification_target_type(takedown.target_type),
      target_id: takedown.target_id
    })

    # Email is sent directly (the notification email channel is opt-out by
    # default) and fire-and-forget so it never blocks the takedown.
    send_takedown_email(takedown, days)
    :ok
  end

  # media/account_badge aren't linkable notification targets; leave nil.
  defp notification_target_type(t) when t in ~w(group page post), do: t
  defp notification_target_type(_), do: nil

  defp send_takedown_email(%Takedown{owner_id: owner_id} = takedown, days) do
    Task.Supervisor.start_child(Hybridsocial.TaskSupervisor, fn ->
      with identity when not is_nil(identity) <- Hybridsocial.Accounts.get_identity(owner_id),
           user when not is_nil(user) <- Hybridsocial.Accounts.get_user_by_identity(owner_id),
           true <- is_binary(user.email) and user.email != "" do
        identity
        |> Map.from_struct()
        |> Map.put(:email, user.email)
        |> Hybridsocial.Emails.content_removed_email(%{
          target_label: takedown_label(takedown.target_type),
          reason: takedown.reason,
          appeal_days: days
        })
        |> Hybridsocial.Mailer.deliver()
      end
    end)
  end

  defp takedown_label("group"), do: "group"
  defp takedown_label("page"), do: "page"
  defp takedown_label("post"), do: "post"
  defp takedown_label("media"), do: "media"
  defp takedown_label("account_badge"), do: "verification badge"
  defp takedown_label(_), do: "content"

  @verified_badge_tiers ~w(verified_starter verified_creator verified_pro)

  @doc """
  Opens a takedown notice when staff revoke a verified badge — i.e. a downgrade
  from a verified tier to a non-verified one. A no-op for grants, upgrades, or
  moves between non-verified tiers, and when no reason is given. The revoked-
  from tier is stored in `category` so a later restore can re-grant it.
  """
  def open_badge_takedown(identity_id, admin_id, old_tier, new_tier, reason) do
    if old_tier in @verified_badge_tiers and new_tier not in @verified_badge_tiers and
         is_binary(reason) and reason != "" do
      create_takedown(%{
        target_type: "account_badge",
        target_id: identity_id,
        owner_id: identity_id,
        moderator_id: admin_id,
        reason: reason,
        category: old_tier
      })
    else
      {:ok, :noop}
    end
  end

  # ── Content Filters ──────────────────────────────────────────────────

  def create_filter(attrs) do
    %ContentFilter{}
    |> ContentFilter.changeset(attrs)
    |> Repo.insert()
  end

  def list_filters(opts \\ []) do
    ContentFilter
    |> filter_by_scope(opts[:scope])
    |> order_by([f], desc: f.inserted_at)
    |> Repo.all()
  end

  defp filter_by_scope(query, nil), do: query

  defp filter_by_scope(query, scope) when scope in ["local", "remote"] do
    where(query, [f], f.scope == "all" or f.scope == ^scope)
  end

  defp filter_by_scope(query, _), do: query

  def update_filter(id, attrs) do
    case Repo.get(ContentFilter, id) do
      nil -> {:error, :not_found}
      filter -> filter |> ContentFilter.changeset(attrs) |> Repo.update()
    end
  end

  def delete_filter(id) do
    case Repo.get(ContentFilter, id) do
      nil -> {:error, :not_found}
      filter -> Repo.delete(filter)
    end
  end

  def check_content(text, scope \\ "all") do
    Hybridsocial.Moderation.FilterResolver.impl().check(text, %{context: "posts", scope: scope})
  end

  @doc """
  Checks content and automatically queues for review if flagged.
  Returns the filter result unchanged; queuing is a side-effect.
  """
  def check_content_and_queue(text, item_type, item_id, scope \\ "all") do
    result = check_content(text, scope)

    case result do
      {:flag, reason} ->
        queue_for_review(%{
          "item_type" => item_type,
          "item_id" => item_id,
          "source" => "content_filter",
          "reason" => reason,
          "severity" => "medium"
        })

        result

      _ ->
        result
    end
  end

  # ── Banned Domains ───────────────────────────────────────────────────

  def ban_domain(domain, type, reason, admin_id) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:banned_domain, fn _ ->
      %BannedDomain{}
      |> BannedDomain.changeset(%{
        domain: domain,
        type: type,
        reason: reason,
        created_by: admin_id
      })
    end)
    |> Ecto.Multi.run(:audit, fn _repo, _changes ->
      log(admin_id, "domain.banned", "domain", nil, %{domain: domain, type: type, reason: reason})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{banned_domain: banned_domain}} -> {:ok, banned_domain}
      {:error, _, changeset, _} -> {:error, changeset}
    end
  end

  def unban_domain(domain, admin_id) do
    case Repo.get(BannedDomain, String.downcase(domain)) do
      nil ->
        {:error, :not_found}

      banned_domain ->
        Ecto.Multi.new()
        |> Ecto.Multi.delete(:banned_domain, banned_domain)
        |> Ecto.Multi.run(:audit, fn _repo, _changes ->
          log(admin_id, "domain.unbanned", "domain", nil, %{domain: domain})
        end)
        |> Repo.transaction()
        |> case do
          {:ok, _} -> :ok
          {:error, _, reason, _} -> {:error, reason}
        end
    end
  end

  def list_banned_domains do
    BannedDomain
    |> order_by([d], asc: d.domain)
    |> Repo.all()
  end

  def domain_banned?(domain, type) do
    domain = String.downcase(domain)

    BannedDomain
    |> where([d], d.domain == ^domain)
    |> where([d], d.type == ^type or d.type == "both")
    |> Repo.exists?()
  end

  # ── IP Bans ────────────────────────────────────────────────────────────

  def list_ip_bans do
    IpBan
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  def create_ip_ban(attrs) do
    %IpBan{}
    |> IpBan.changeset(attrs)
    |> Repo.insert()
  end

  def delete_ip_ban(id) do
    case Repo.get(IpBan, id) do
      nil -> {:error, :not_found}
      ip_ban -> Repo.delete(ip_ban)
    end
  end

  @doc """
  Checks if an IP address matches any active (non-expired) ban, including CIDR ranges.
  """
  def ip_banned?(ip_string) when is_binary(ip_string) do
    now = DateTime.utc_now()

    IpBan
    |> where([b], is_nil(b.expires_at) or b.expires_at > ^now)
    |> Repo.all()
    |> Enum.any?(fn ban -> ip_matches_ban?(ip_string, ban) end)
  end

  defp ip_matches_ban?(ip_string, %IpBan{ip_address: ban_ip, subnet_mask: nil}) do
    ip_string == ban_ip
  end

  defp ip_matches_ban?(ip_string, %IpBan{ip_address: ban_ip, subnet_mask: mask}) do
    with {:ok, client_addr} <- :inet.parse_address(to_charlist(ip_string)),
         {:ok, ban_addr} <- :inet.parse_address(to_charlist(ban_ip)),
         {prefix_len, ""} <- Integer.parse(mask) do
      ip_in_cidr?(client_addr, ban_addr, prefix_len)
    else
      _ -> false
    end
  end

  defp ip_in_cidr?(client, network, prefix_len) do
    client_bits = ip_to_bits(client)
    network_bits = ip_to_bits(network)

    if byte_size(client_bits) == byte_size(network_bits) do
      <<client_prefix::bitstring-size(prefix_len), _::bitstring>> = client_bits
      <<network_prefix::bitstring-size(prefix_len), _::bitstring>> = network_bits
      client_prefix == network_prefix
    else
      false
    end
  end

  defp ip_to_bits({a, b, c, d}) do
    <<a::8, b::8, c::8, d::8>>
  end

  defp ip_to_bits({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  # ── Email Domain Bans ─────────────────────────────────────────────────

  def list_email_domain_bans do
    EmailDomainBan
    |> order_by([b], asc: b.domain)
    |> Repo.all()
  end

  def create_email_domain_ban(attrs) do
    %EmailDomainBan{}
    |> EmailDomainBan.changeset(attrs)
    |> Repo.insert()
  end

  def delete_email_domain_ban(id) do
    case Repo.get(EmailDomainBan, id) do
      nil -> {:error, :not_found}
      ban -> Repo.delete(ban)
    end
  end

  def email_domain_banned?(domain) when is_binary(domain) do
    domain = String.downcase(domain)

    EmailDomainBan
    |> where([b], b.domain == ^domain)
    |> Repo.exists?()
  end

  # ── Webhooks ─────────────────────────────────────────────────────────

  def create_webhook(attrs) do
    %Webhook{}
    |> Webhook.changeset(attrs)
    |> Repo.insert()
  end

  def list_webhooks do
    Webhook
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end

  def update_webhook(id, attrs) do
    case Repo.get(Webhook, id) do
      nil -> {:error, :not_found}
      webhook -> webhook |> Webhook.changeset(attrs) |> Repo.update()
    end
  end

  def delete_webhook(id) do
    case Repo.get(Webhook, id) do
      nil -> {:error, :not_found}
      webhook -> Repo.delete(webhook)
    end
  end

  @doc """
  Known webhook events. Kept as a static catalog so the admin UI can
  render checkboxes instead of forcing admins to hand-type event
  strings, and so callers get a compile-time crash on typos via
  `Enum.member?/2` in tests.
  """
  def known_events do
    [
      "post.created",
      "post.deleted",
      "user.registered",
      "user.suspended",
      "user.unsuspended",
      "report.filed",
      "report.resolved",
      "appeal.filed",
      "moderation.queued",
      "federation.instance_blocked"
    ]
  end

  @doc """
  Enqueues a webhook delivery for every enabled webhook that subscribes
  to `event`. An empty `events` array on a webhook means "all events".
  The `WebhookDeliveryWorker` drains the queue and retries with
  exponential backoff on non-2xx so a flapping receiver doesn't
  silently lose events.
  """
  def fire_webhook(event, payload) when is_binary(event) do
    now = DateTime.utc_now()

    Webhook
    |> where([w], w.enabled == true)
    |> Repo.all()
    |> Enum.filter(fn w -> w.events == [] or event in w.events end)
    |> Enum.each(fn webhook ->
      %WebhookDelivery{}
      |> WebhookDelivery.changeset(%{
        webhook_id: webhook.id,
        event: event,
        payload: payload,
        status: "pending",
        attempts: 0,
        next_attempt_at: now
      })
      |> Repo.insert()
    end)

    :ok
  end

  def list_recent_deliveries(webhook_id, limit \\ 20) do
    WebhookDelivery
    |> where([d], d.webhook_id == ^webhook_id)
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # ── Appeals ──────────────────────────────────────────────────────────

  def create_appeal(attrs) do
    identity_id = attrs["identity_id"] || attrs[:identity_id]
    action_type = attrs["action_type"] || attrs[:action_type]

    # Enforce: one pending appeal per action_type per user
    existing =
      Appeal
      |> where([a], a.identity_id == ^identity_id)
      |> where([a], a.action_type == ^action_type)
      |> where([a], a.status == "pending")
      |> Repo.exists?()

    if existing do
      {:error, :already_pending}
    else
      %Appeal{}
      |> Appeal.changeset(attrs)
      |> Repo.insert()
    end
  end

  def get_appeal(id) do
    case Repo.get(Appeal, id) do
      nil -> nil
      appeal -> Repo.preload(appeal, [:identity, :reviewer])
    end
  end

  def list_appeals(opts \\ []) do
    Appeal
    |> filter_appeals_by_status(opts[:status])
    |> filter_appeals_by_identity(opts[:identity_id])
    |> order_by([a], desc: a.inserted_at)
    |> paginate(opts)
    |> Repo.all()
    |> Repo.preload([:identity, :reviewer])
  end

  defp filter_appeals_by_status(query, nil), do: query
  defp filter_appeals_by_status(query, status), do: where(query, [a], a.status == ^status)

  defp filter_appeals_by_identity(query, nil), do: query
  defp filter_appeals_by_identity(query, id), do: where(query, [a], a.identity_id == ^id)

  @doc """
  Hard-deletes approved + rejected appeals whose `reviewed_at` is
  older than `retention_days` days. Pending appeals are never
  pruned — they still need admin action. Returns the row count.
  """
  def prune_closed_appeals(retention_days)
      when is_integer(retention_days) and retention_days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    {n, _} =
      Appeal
      |> where([a], a.status in ["approved", "rejected"])
      |> where([a], not is_nil(a.reviewed_at))
      |> where([a], a.reviewed_at < ^cutoff)
      |> Repo.delete_all()

    n
  end

  def approve_appeal(appeal_id, admin_id, response \\ nil) do
    case get_appeal(appeal_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status != "pending" ->
        {:error, :already_reviewed}

      appeal ->
        Ecto.Multi.new()
        |> Ecto.Multi.update(
          :appeal,
          Appeal.review_changeset(appeal, %{
            status: "approved",
            reviewed_by: admin_id,
            reviewed_at: DateTime.utc_now(),
            response: response
          })
        )
        |> Ecto.Multi.run(:reverse_action, fn _repo, %{appeal: approved_appeal} ->
          reverse_moderation_action(approved_appeal)
        end)
        |> Ecto.Multi.run(:audit, fn _repo, %{appeal: approved_appeal} ->
          log(admin_id, "appeal.approved", "appeal", approved_appeal.id, %{
            action_type: approved_appeal.action_type,
            identity_id: approved_appeal.identity_id
          })
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{appeal: appeal}} -> {:ok, Repo.preload(appeal, [:identity, :reviewer])}
          {:error, _, reason, _} -> {:error, reason}
        end
    end
  end

  def reject_appeal(appeal_id, admin_id, response \\ nil) do
    case get_appeal(appeal_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status != "pending" ->
        {:error, :already_reviewed}

      appeal ->
        Ecto.Multi.new()
        |> Ecto.Multi.update(
          :appeal,
          Appeal.review_changeset(appeal, %{
            status: "rejected",
            reviewed_by: admin_id,
            reviewed_at: DateTime.utc_now(),
            response: response
          })
        )
        |> Ecto.Multi.run(:audit, fn _repo, %{appeal: rejected_appeal} ->
          log(admin_id, "appeal.rejected", "appeal", rejected_appeal.id, %{
            action_type: rejected_appeal.action_type,
            identity_id: rejected_appeal.identity_id
          })
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{appeal: appeal}} -> {:ok, Repo.preload(appeal, [:identity, :reviewer])}
          {:error, _, reason, _} -> {:error, reason}
        end
    end
  end

  defp reverse_moderation_action(%Appeal{action_type: "suspension", identity_id: identity_id}) do
    case Repo.get(Identity, identity_id) do
      nil -> {:ok, :no_op}
      identity -> Hybridsocial.Accounts.unsuspend_identity(identity)
    end
  end

  defp reverse_moderation_action(%Appeal{action_type: "silencing", identity_id: identity_id}) do
    case Repo.get(Identity, identity_id) do
      nil ->
        {:ok, :no_op}

      identity ->
        identity
        |> Ecto.Changeset.change(is_silenced: false)
        |> Repo.update()
    end
  end

  defp reverse_moderation_action(%Appeal{action_type: "shadow_ban", identity_id: identity_id}) do
    case Repo.get(Identity, identity_id) do
      nil ->
        {:ok, :no_op}

      identity ->
        identity
        |> Ecto.Changeset.change(is_shadow_banned: false)
        |> Repo.update()
    end
  end

  # For post_removal and warning, there's no automatic reversal
  defp reverse_moderation_action(_appeal), do: {:ok, :no_op}

  # ── Moderation Notes ────────────────────────────────────────────────

  def create_moderation_note(attrs) do
    %ModerationNote{}
    |> ModerationNote.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, note} -> {:ok, Repo.preload(note, [:author, :target_identity])}
      error -> error
    end
  end

  def list_moderation_notes(target_identity_id) do
    ModerationNote
    |> where([n], n.target_identity_id == ^target_identity_id)
    |> order_by([n], desc: n.inserted_at)
    |> Repo.all()
    |> Repo.preload([:author, :target_identity])
  end

  def delete_moderation_note(id) do
    case Repo.get(ModerationNote, id) do
      nil -> {:error, :not_found}
      note -> Repo.delete(note)
    end
  end

  # ── Moderation Queue ──────────────────────────────────────────────────

  @doc """
  Adds an item to the moderation review queue.
  Attrs should include: item_type, item_id, source, reason, and optionally severity.
  """
  def queue_for_review(attrs) do
    result =
      %QueuedItem{}
      |> QueuedItem.changeset(attrs)
      |> Repo.insert()

    with {:ok, item} <- result do
      # 1) Realtime push to every open admin panel via SSE.
      Phoenix.PubSub.broadcast(
        Hybridsocial.PubSub,
        "moderation",
        %{
          event: "queued",
          payload: %{
            id: item.id,
            item_type: item.item_type,
            item_id: item.item_id,
            source: item.source,
            reason: item.reason,
            severity: item.severity,
            status: item.status,
            inserted_at: item.inserted_at
          }
        }
      )

      # 2) Fire-and-forget email notify (throttled per staff member).
      Task.Supervisor.start_child(Hybridsocial.TaskSupervisor, fn ->
        notify_staff_by_email(item)
      end)

      # 3) External integrations (Slack/Matrix/on-call pager etc.)
      fire_webhook("moderation.queued", %{
        id: item.id,
        item_type: item.item_type,
        item_id: item.item_id,
        source: item.source,
        reason: item.reason,
        severity: item.severity
      })
    end

    result
  end

  @doc """
  Emails every staff member who has opted in to the
  `moderation_queue` notification preference. Throttled to at most
  one email per recipient per throttle window (default 10 min)
  via a Valkey key so a filter-rule mistake that flags 500 items
  in a minute doesn't produce 500 inboxes of 500 emails.
  """
  def notify_staff_by_email(%QueuedItem{} = item) do
    require Logger
    alias Hybridsocial.{Accounts.Identity, Accounts.User, Auth.RBAC, Notifications, Cache}

    throttle_sec =
      case Hybridsocial.Config.get("moderation_email_throttle_seconds", 600) do
        n when is_integer(n) and n > 0 -> n
        _ -> 600
      end

    staff_ids =
      from(r in Hybridsocial.Auth.IdentityRole,
        distinct: true,
        select: r.identity_id,
        where: is_nil(r.expires_at) or r.expires_at > ^DateTime.utc_now()
      )
      |> Repo.all()

    for identity_id <- staff_ids do
      if Notifications.should_notify?(identity_id, "moderation_queue", :email) and
           RBAC.staff?(identity_id) do
        throttle_key = "mod_email:#{identity_id}"

        case Cache.get(throttle_key) do
          nil ->
            # Set the throttle flag BEFORE dispatching to avoid a
            # race where two near-simultaneous inserts both race past
            # the check.
            Cache.set(throttle_key, "1", throttle_sec)

            with %Identity{} = identity <- Repo.get(Identity, identity_id),
                 %User{email: email} when is_binary(email) and email != "" <-
                   Repo.get_by(User, identity_id: identity_id) do
              try do
                Hybridsocial.Emails.moderation_queue_email(email, identity, item)
                |> Hybridsocial.Mailer.deliver()
              rescue
                e ->
                  Logger.warning(
                    "moderation email failed for #{identity_id}: #{Exception.message(e)}"
                  )
              end
            end

          _ ->
            :ok
        end
      end
    end
  end

  @doc """
  Lists moderation queue items with optional filters for status, item_type, and severity.
  """
  def list_queue(opts \\ []) do
    QueuedItem
    |> filter_queue_by_status(opts[:status])
    |> filter_queue_by_item_type(opts[:item_type])
    |> filter_queue_by_severity(opts[:severity])
    |> order_by([q], desc: q.inserted_at)
    |> paginate(opts)
    |> Repo.all()
  end

  defp filter_queue_by_status(query, nil), do: query
  defp filter_queue_by_status(query, status), do: where(query, [q], q.status == ^status)

  defp filter_queue_by_item_type(query, nil), do: query
  defp filter_queue_by_item_type(query, type), do: where(query, [q], q.item_type == ^type)

  defp filter_queue_by_severity(query, nil), do: query
  defp filter_queue_by_severity(query, severity), do: where(query, [q], q.severity == ^severity)

  @doc """
  Retrieves a single queued item by ID.
  """
  def get_queued_item(id) do
    Repo.get(QueuedItem, id)
  end

  @doc """
  Approves a queued item (content stays visible).
  """
  def approve_queued_item(item_id, reviewer_id) do
    case Repo.get(QueuedItem, item_id) do
      nil ->
        {:error, :not_found}

      %QueuedItem{status: "pending"} = item ->
        item
        |> QueuedItem.approve_changeset(reviewer_id)
        |> Repo.update()

      %QueuedItem{status: "escalated"} = item ->
        item
        |> QueuedItem.approve_changeset(reviewer_id)
        |> Repo.update()

      _item ->
        {:error, :already_reviewed}
    end
  end

  @doc """
  Rejects a queued item (content is deleted/hidden).
  For posts, performs a soft delete. For accounts, suspends.
  """
  def reject_queued_item(item_id, reviewer_id, reason \\ "") do
    case Repo.get(QueuedItem, item_id) do
      nil ->
        {:error, :not_found}

      %QueuedItem{status: status} = item when status in ["pending", "escalated"] ->
        Ecto.Multi.new()
        |> Ecto.Multi.update(:item, QueuedItem.reject_changeset(item, reviewer_id))
        |> Ecto.Multi.run(:enforce, fn _repo, _changes ->
          enforce_queue_rejection(item, reviewer_id, reason)
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{item: item}} -> {:ok, item}
          {:error, _, reason, _} -> {:error, reason}
        end

      _item ->
        {:error, :already_reviewed}
    end
  end

  defp enforce_queue_rejection(%QueuedItem{item_type: "post", item_id: post_id}, admin_id, reason) do
    Hybridsocial.Social.Posts.admin_delete_post(post_id, admin_id, reason)
  end

  defp enforce_queue_rejection(
         %QueuedItem{item_type: "account", item_id: identity_id},
         admin_id,
         _reason
       ) do
    case Repo.get(Identity, identity_id) do
      nil ->
        {:ok, :no_op}

      identity ->
        case Hybridsocial.Accounts.suspend_identity(identity) do
          {:ok, updated} ->
            log(admin_id, "account.suspended", "identity", identity_id, %{
              source: "moderation_queue"
            })

            {:ok, updated}

          error ->
            error
        end
    end
  end

  defp enforce_queue_rejection(_item, _admin_id, _reason), do: {:ok, :no_op}

  @doc """
  Escalates a queued item to a higher-level moderator.
  """
  def escalate_queued_item(item_id, admin_id) do
    case Repo.get(QueuedItem, item_id) do
      nil ->
        {:error, :not_found}

      %QueuedItem{status: "pending"} = item ->
        case item |> QueuedItem.escalate_changeset() |> Repo.update() do
          {:ok, updated} ->
            log(admin_id, "queue_item.escalated", "queued_item", item_id, %{
              item_type: item.item_type,
              item_id: item.item_id
            })

            {:ok, updated}

          error ->
            error
        end

      _item ->
        {:error, :cannot_escalate}
    end
  end

  @doc """
  Returns counts of queued items grouped by status for the dashboard.
  """
  def queue_stats do
    QueuedItem
    |> group_by([q], q.status)
    |> select([q], {q.status, count(q.id)})
    |> Repo.all()
    |> Map.new()
  end

  # ── Media Hash Bans ─────────────────────────────────────────────────

  @doc "Lists all media hash bans, ordered by most recent first."
  def list_media_hash_bans do
    MediaHashBan
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  @doc "Creates a media hash ban."
  def create_media_hash_ban(attrs) do
    %MediaHashBan{}
    |> MediaHashBan.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Deletes a media hash ban by ID."
  def delete_media_hash_ban(id) do
    case Repo.get(MediaHashBan, id) do
      nil -> {:error, :not_found}
      ban -> Repo.delete(ban)
    end
  end

  @doc "Returns true if the given hash is in the ban list (SHA256 match)."
  def media_hash_banned?(hash) when is_binary(hash) do
    hash = String.downcase(hash)

    MediaHashBan
    |> where([b], b.hash == ^hash)
    |> Repo.exists?()
  end

  # ── Pagination Helper ────────────────────────────────────────────────

  defp paginate(query, opts) do
    limit = opts[:limit] || 20
    offset = opts[:offset] || 0

    query
    |> limit(^limit)
    |> offset(^offset)
  end
end
