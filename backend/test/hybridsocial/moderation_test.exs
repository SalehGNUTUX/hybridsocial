defmodule Hybridsocial.ModerationTest do
  use Hybridsocial.DataCase

  alias Hybridsocial.Moderation

  defp create_identity(handle, email) do
    {:ok, identity} =
      Hybridsocial.Accounts.register_user(%{
        "handle" => handle,
        "email" => email,
        "password" => "password1234567890",
        "password_confirmation" => "password1234567890"
      })

    identity
  end

  # ── Reports ──────────────────────────────────────────────────────────

  describe "reports" do
    setup do
      reporter = create_identity("reporter1", "reporter1@example.com")
      reported = create_identity("reported1", "reported1@example.com")
      moderator = create_identity("moderator1", "moderator1@example.com")
      %{reporter: reporter, reported: reported, moderator: moderator}
    end

    test "create_report/2 creates a report", %{reporter: reporter, reported: reported} do
      attrs = %{
        "reported_id" => reported.id,
        "category" => "spam",
        "description" => "This is spam"
      }

      assert {:ok, report} = Moderation.create_report(reporter.id, attrs)
      assert report.category == "spam"
      assert report.status == "pending"
      assert report.reporter_id == reporter.id
      assert report.reported_id == reported.id
    end

    test "create_report/2 fails with invalid category", %{reporter: reporter, reported: reported} do
      attrs = %{
        "reported_id" => reported.id,
        "category" => "invalid"
      }

      assert {:error, changeset} = Moderation.create_report(reporter.id, attrs)
      assert errors_on(changeset)[:category]
    end

    test "get_report/1 returns report with preloads", %{reporter: reporter, reported: reported} do
      {:ok, report} =
        Moderation.create_report(reporter.id, %{
          "reported_id" => reported.id,
          "category" => "harassment"
        })

      fetched = Moderation.get_report(report.id)
      assert fetched.id == report.id
      assert fetched.reporter.id == reporter.id
      assert fetched.reported.id == reported.id
    end

    test "list_reports/1 returns paginated reports", %{reporter: reporter, reported: reported} do
      for i <- 1..3 do
        Moderation.create_report(reporter.id, %{
          "reported_id" => reported.id,
          "category" => "spam",
          "description" => "Report #{i}"
        })
      end

      reports = Moderation.list_reports(limit: 2)
      assert length(reports) == 2

      all_reports = Moderation.list_reports()
      assert length(all_reports) == 3
    end

    test "list_reports/1 filters by status", %{
      reporter: reporter,
      reported: reported,
      moderator: moderator
    } do
      {:ok, report} =
        Moderation.create_report(reporter.id, %{
          "reported_id" => reported.id,
          "category" => "spam"
        })

      Moderation.resolve_report(report.id, moderator.id, "warned user")

      pending = Moderation.list_reports(status: "pending")
      assert length(pending) == 0

      resolved = Moderation.list_reports(status: "resolved")
      assert length(resolved) == 1
    end

    test "assign_report/2 assigns a moderator", %{
      reporter: reporter,
      reported: reported,
      moderator: moderator
    } do
      {:ok, report} =
        Moderation.create_report(reporter.id, %{
          "reported_id" => reported.id,
          "category" => "spam"
        })

      assert {:ok, updated} = Moderation.assign_report(report.id, moderator.id)
      assert updated.assigned_to == moderator.id
      assert updated.status == "investigating"
    end

    test "resolve_report/3 resolves report and creates audit log", %{
      reporter: reporter,
      reported: reported,
      moderator: moderator
    } do
      {:ok, report} =
        Moderation.create_report(reporter.id, %{
          "reported_id" => reported.id,
          "category" => "spam"
        })

      assert {:ok, resolved} = Moderation.resolve_report(report.id, moderator.id, "warned user")
      assert resolved.status == "resolved"
      assert resolved.action_taken == "warned user"
      assert resolved.resolved_at != nil

      entries = Moderation.list_audit_log(action: "report.resolved")
      assert length(entries) == 1
      assert hd(entries).actor_id == moderator.id
    end

    test "dismiss_report/2 dismisses report and creates audit log", %{
      reporter: reporter,
      reported: reported,
      moderator: moderator
    } do
      {:ok, report} =
        Moderation.create_report(reporter.id, %{
          "reported_id" => reported.id,
          "category" => "spam"
        })

      assert {:ok, dismissed} = Moderation.dismiss_report(report.id, moderator.id)
      assert dismissed.status == "dismissed"

      entries = Moderation.list_audit_log(action: "report.dismissed")
      assert length(entries) == 1
    end
  end

  # ── Audit Log ────────────────────────────────────────────────────────

  describe "audit log" do
    setup do
      actor = create_identity("actor1", "actor1@example.com")
      %{actor: actor}
    end

    test "log/6 creates an audit log entry", %{actor: actor} do
      assert {:ok, entry} =
               Moderation.log(
                 actor.id,
                 "test.action",
                 "identity",
                 actor.id,
                 %{foo: "bar"},
                 "127.0.0.1"
               )

      assert entry.action == "test.action"
      assert entry.actor_id == actor.id
      assert entry.target_type == "identity"
      assert entry.details == %{foo: "bar"} || entry.details == %{"foo" => "bar"}
      assert entry.ip_address == "127.0.0.1"
      assert entry.created_at != nil
    end

    test "list_audit_log/1 filters by action", %{actor: actor} do
      Moderation.log(actor.id, "action.one", nil, nil, %{})
      Moderation.log(actor.id, "action.two", nil, nil, %{})

      entries = Moderation.list_audit_log(action: "action.one")
      assert length(entries) == 1
      assert hd(entries).action == "action.one"
    end

    test "list_audit_log/1 filters by actor_id", %{actor: actor} do
      other = create_identity("other1", "other1@example.com")

      Moderation.log(actor.id, "test.action", nil, nil, %{})
      Moderation.log(other.id, "test.action", nil, nil, %{})

      entries = Moderation.list_audit_log(actor_id: actor.id)
      assert length(entries) == 1
    end

    test "audit log entries are immutable (no updated_at)" do
      fields = Hybridsocial.Moderation.AuditLog.__schema__(:fields)
      refute :updated_at in fields
    end
  end

  # ── Content Filters ──────────────────────────────────────────────────

  describe "content filters" do
    test "create_filter/1 creates a filter" do
      assert {:ok, filter} =
               Moderation.create_filter(%{
                 "type" => "word",
                 "pattern" => "badword",
                 "action" => "reject"
               })

      assert filter.type == "word"
      assert filter.pattern == "badword"
      assert filter.action == "reject"
    end

    test "create_filter/1 fails without required fields" do
      assert {:error, changeset} = Moderation.create_filter(%{})
      assert errors_on(changeset)[:type]
      assert errors_on(changeset)[:pattern]
      assert errors_on(changeset)[:action]
    end

    test "create_filter/1 requires replacement for replace action" do
      assert {:error, changeset} =
               Moderation.create_filter(%{
                 "type" => "word",
                 "pattern" => "badword",
                 "action" => "replace"
               })

      assert errors_on(changeset)[:replacement]
    end

    test "list_filters/0 returns all filters" do
      Moderation.create_filter(%{"type" => "word", "pattern" => "bad", "action" => "reject"})

      Moderation.create_filter(%{
        "type" => "phrase",
        "pattern" => "bad phrase",
        "action" => "flag"
      })

      filters = Moderation.list_filters()
      assert length(filters) == 2
    end

    test "update_filter/2 updates a filter" do
      {:ok, filter} =
        Moderation.create_filter(%{"type" => "word", "pattern" => "bad", "action" => "reject"})

      assert {:ok, updated} = Moderation.update_filter(filter.id, %{"action" => "flag"})
      assert updated.action == "flag"
    end

    test "delete_filter/1 deletes a filter" do
      {:ok, filter} =
        Moderation.create_filter(%{"type" => "word", "pattern" => "bad", "action" => "reject"})

      assert {:ok, _} = Moderation.delete_filter(filter.id)
      assert Moderation.list_filters() == []
    end

    test "check_content/1 returns {:ok, text} when no filters match" do
      Moderation.create_filter(%{"type" => "word", "pattern" => "badword", "action" => "reject"})

      assert {:ok, "hello world"} = Moderation.check_content("hello world")
    end

    test "check_content/1 returns {:reject, reason} for reject filter" do
      Moderation.create_filter(%{"type" => "word", "pattern" => "badword", "action" => "reject"})

      assert {:reject, _reason} = Moderation.check_content("this is badword here")
    end

    test "check_content/1 returns {:flag, reason} for flag filter" do
      Moderation.create_filter(%{"type" => "word", "pattern" => "suspicious", "action" => "flag"})

      assert {:flag, _reason} = Moderation.check_content("this is suspicious content")
    end

    test "check_content/1 returns {:replace, new_text} for replace filter" do
      Moderation.create_filter(%{
        "type" => "word",
        "pattern" => "badword",
        "action" => "replace",
        "replacement" => "***"
      })

      assert {:ok, new_text} = Moderation.check_content("this is badword here")
      assert new_text == "this is *** here"
    end

    test "check_content/1 handles phrase filters" do
      Moderation.create_filter(%{
        "type" => "phrase",
        "pattern" => "bad phrase",
        "action" => "reject"
      })

      assert {:reject, _} = Moderation.check_content("this contains bad phrase inside")
    end

    test "check_content/1 handles regex filters" do
      Moderation.create_filter(%{
        "type" => "regex",
        "pattern" => "\\d{3}-\\d{3}-\\d{4}",
        "action" => "flag"
      })

      assert {:flag, _} = Moderation.check_content("call me at 555-123-4567")
      assert {:ok, _} = Moderation.check_content("no phone numbers here")
    end
  end

  # ── Banned Domains ───────────────────────────────────────────────────

  describe "banned domains" do
    setup do
      admin = create_identity("admin1", "admin1@example.com")
      %{admin: admin}
    end

    test "ban_domain/4 bans a domain and creates audit log", %{admin: admin} do
      assert {:ok, banned} = Moderation.ban_domain("spam.com", "email", "Spam domain", admin.id)
      assert banned.domain == "spam.com"
      assert banned.type == "email"

      entries = Moderation.list_audit_log(action: "domain.banned")
      assert length(entries) == 1
    end

    test "unban_domain/2 unbans a domain and creates audit log", %{admin: admin} do
      Moderation.ban_domain("spam.com", "email", "Spam domain", admin.id)
      assert :ok = Moderation.unban_domain("spam.com", admin.id)

      entries = Moderation.list_audit_log(action: "domain.unbanned")
      assert length(entries) == 1
    end

    test "unban_domain/2 returns error for unknown domain", %{admin: admin} do
      assert {:error, :not_found} = Moderation.unban_domain("unknown.com", admin.id)
    end

    test "list_banned_domains/0 returns all banned domains", %{admin: admin} do
      Moderation.ban_domain("spam.com", "email", "reason", admin.id)
      Moderation.ban_domain("evil.org", "federation", "reason", admin.id)

      domains = Moderation.list_banned_domains()
      assert length(domains) == 2
    end

    test "domain_banned?/2 checks if domain is banned", %{admin: admin} do
      Moderation.ban_domain("spam.com", "email", "reason", admin.id)
      Moderation.ban_domain("evil.org", "both", "reason", admin.id)

      assert Moderation.domain_banned?("spam.com", "email")
      refute Moderation.domain_banned?("spam.com", "federation")
      assert Moderation.domain_banned?("evil.org", "email")
      assert Moderation.domain_banned?("evil.org", "federation")
      refute Moderation.domain_banned?("good.com", "email")
    end
  end

  # ── Takedown appeals (Phase 2: appeal restores the content) ──────────

  describe "takedown appeals" do
    setup do
      owner = create_identity("td_owner", "td_owner@example.com")
      staff = create_identity("td_staff", "td_staff@example.com")
      {:ok, _} = Hybridsocial.Auth.RBAC.assign_role(staff.id, "moderator", staff.id)
      %{owner: owner, staff: staff}
    end

    defp staff_takedown_group(owner, staff) do
      {:ok, group} = Hybridsocial.Groups.create_group(owner.id, %{"name" => "Appealed group"})
      {:ok, _} = Hybridsocial.Groups.delete_group(group.id, staff.id, reason: "review")
      [takedown] = Moderation.list_takedowns_for_owner(owner.id)
      {group, takedown}
    end

    test "the owner can appeal, which pauses the purge window", %{owner: owner, staff: staff} do
      {_group, takedown} = staff_takedown_group(owner, staff)
      assert takedown.status == "active"

      assert {:ok, appeal} =
               Moderation.create_takedown_appeal(owner.id, takedown.id, "It was a misunderstanding")

      assert appeal.action_type == "content_takedown"
      assert appeal.takedown_id == takedown.id
      assert Moderation.get_takedown(takedown.id).status == "appealed"
    end

    test "a non-owner cannot appeal", %{owner: owner, staff: staff} do
      {_group, takedown} = staff_takedown_group(owner, staff)
      other = create_identity("td_other", "td_other@example.com")

      assert {:error, :forbidden} =
               Moderation.create_takedown_appeal(other.id, takedown.id, "let me in")
    end

    test "approving the appeal restores the content and marks it restored",
         %{owner: owner, staff: staff} do
      {group, takedown} = staff_takedown_group(owner, staff)
      assert Hybridsocial.Groups.get_group(group.id) == nil

      {:ok, appeal} = Moderation.create_takedown_appeal(owner.id, takedown.id, "please restore")
      assert {:ok, _} = Moderation.approve_appeal(appeal.id, staff.id)

      assert Hybridsocial.Groups.get_group(group.id) != nil
      assert Moderation.get_takedown(takedown.id).status == "restored"
    end

    test "rejecting the appeal leaves the content down and reactivates the window",
         %{owner: owner, staff: staff} do
      {group, takedown} = staff_takedown_group(owner, staff)
      {:ok, appeal} = Moderation.create_takedown_appeal(owner.id, takedown.id, "please reconsider")

      assert {:ok, _} = Moderation.reject_appeal(appeal.id, staff.id, "denied")

      assert Hybridsocial.Groups.get_group(group.id) == nil
      assert Moderation.get_takedown(takedown.id).status == "active"
    end
  end

  # ── Auto-purge: reminders + permanent deletion ───────────────────────

  describe "takedown auto-purge" do
    setup do
      owner = create_identity("purge_owner", "purge_owner@example.com")
      staff = create_identity("purge_staff", "purge_staff@example.com")
      {:ok, _} = Hybridsocial.Auth.RBAC.assign_role(staff.id, "moderator", staff.id)
      %{owner: owner, staff: staff}
    end

    test "send_purge_reminders warns an owner near the deadline, exactly once",
         %{owner: owner, staff: staff} do
      {:ok, group} = Hybridsocial.Groups.create_group(owner.id, %{"name" => "Nearly gone"})
      soon = DateTime.add(DateTime.utc_now(), 2 * 86_400, :second)
      td = insert_takedown(owner, staff, group.id, soon)

      assert Moderation.send_purge_reminders(7) == 1
      assert Moderation.get_takedown(td.id).reminded_at
      # A second pass doesn't re-remind.
      assert Moderation.send_purge_reminders(7) == 0
    end

    test "send_purge_reminders ignores takedowns still far from the deadline",
         %{owner: owner, staff: staff} do
      {:ok, group} = Hybridsocial.Groups.create_group(owner.id, %{"name" => "Plenty of time"})
      far = DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
      insert_takedown(owner, staff, group.id, far)

      assert Moderation.send_purge_reminders(7) == 0
    end

    test "purge_expired_takedowns permanently deletes the content and marks it purged",
         %{owner: owner, staff: staff} do
      {:ok, group} = Hybridsocial.Groups.create_group(owner.id, %{"name" => "Doomed"})
      past = DateTime.add(DateTime.utc_now(), -86_400, :second)
      td = insert_takedown(owner, staff, group.id, past)

      assert Moderation.purge_expired_takedowns() == 1
      # Hard-deleted, not just soft-deleted.
      assert Hybridsocial.Repo.get(Hybridsocial.Groups.Group, group.id) == nil
      assert Moderation.get_takedown(td.id).status == "purged"
    end

    test "purge_expired_takedowns leaves a takedown whose window hasn't passed",
         %{owner: owner, staff: staff} do
      {:ok, group} = Hybridsocial.Groups.create_group(owner.id, %{"name" => "Safe"})
      future = DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
      insert_takedown(owner, staff, group.id, future)

      assert Moderation.purge_expired_takedowns() == 0
      assert Hybridsocial.Repo.get(Hybridsocial.Groups.Group, group.id) != nil
    end

    test "purge_expired_takedowns skips an appealed takedown",
         %{owner: owner, staff: staff} do
      {:ok, group} = Hybridsocial.Groups.create_group(owner.id, %{"name" => "Under appeal"})
      past = DateTime.add(DateTime.utc_now(), -86_400, :second)
      td = insert_takedown(owner, staff, group.id, past)
      td |> Hybridsocial.Moderation.Takedown.status_changeset("appealed") |> Hybridsocial.Repo.update!()

      assert Moderation.purge_expired_takedowns() == 0
      assert Hybridsocial.Repo.get(Hybridsocial.Groups.Group, group.id) != nil
    end
  end

  defp insert_takedown(owner, staff, group_id, purge_after) do
    %Hybridsocial.Moderation.Takedown{}
    |> Hybridsocial.Moderation.Takedown.changeset(%{
      "target_type" => "group",
      "target_id" => group_id,
      "owner_id" => owner.id,
      "moderator_id" => staff.id,
      "reason" => "policy violation",
      "purge_after" => purge_after
    })
    |> Hybridsocial.Repo.insert!()
  end
end
