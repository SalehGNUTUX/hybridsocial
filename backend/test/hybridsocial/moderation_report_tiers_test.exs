defmodule Hybridsocial.ModerationReportTiersTest do
  @moduledoc """
  Two-tier reporting (#86 item 3).

  The property under test throughout is that a group cannot make a complaint
  disappear: not by sitting on it, not by the reporter mis-routing it, and not
  by the category being something a group has no standing to decide.
  """
  use Hybridsocial.DataCase, async: false

  alias Hybridsocial.{Groups, Moderation, Repo, Social.Posts}
  alias Hybridsocial.Moderation.Report

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Hybridsocial.Repo, {:shared, self()})
    start_supervised!(Hybridsocial.Config.Store)

    owner = create_user("rt_owner", "rt_owner@test.com")
    member = create_user("rt_member", "rt_member@test.com")
    reporter = create_user("rt_reporter", "rt_reporter@test.com")
    outsider = create_user("rt_outsider", "rt_outsider@test.com")

    {:ok, group} =
      Groups.create_group(owner.id, %{
        "name" => "Reported Group",
        "handle" => "reportedgroup",
        "visibility" => "public",
        "join_policy" => "open"
      })

    {:ok, _} = Groups.join_group(group.id, member.id)
    {:ok, _} = Groups.join_group(group.id, reporter.id)

    {:ok, post} =
      Posts.create_post(member.id, %{
        "content" => "offending post",
        "visibility" => "group",
        "group_id" => group.id
      })

    %{
      owner: owner,
      member: member,
      reporter: reporter,
      outsider: outsider,
      group: group,
      post: post
    }
  end

  defp report_attrs(ctx, overrides) do
    Map.merge(
      %{
        "reported_id" => ctx.member.id,
        "target_type" => "post",
        "target_id" => ctx.post.id,
        "category" => "spam",
        "description" => "please look at this"
      },
      overrides
    )
  end

  defp age_report(report, hours) do
    at = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
    report |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end

  describe "routing" do
    test "a group-tier report about that group's post stays group-tier", ctx do
      {:ok, report} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => ctx.group.id})
        )

      assert report.tier == "group"
      assert report.group_id == ctx.group.id
    end

    test "an instance-tier report is unaffected", ctx do
      {:ok, report} = Moderation.create_report(ctx.reporter.id, report_attrs(ctx, %{}))
      assert report.tier == "instance"
      assert is_nil(report.group_id)
    end

    # The reporter is not making a legal classification under stress; the
    # instance carries these regardless of which button was pressed.
    for category <- ~w(illegal hate_speech) do
      test "a #{category} report is forced to the instance tier", ctx do
        {:ok, report} =
          Moderation.create_report(
            ctx.reporter.id,
            report_attrs(ctx, %{
              "tier" => "group",
              "group_id" => ctx.group.id,
              "category" => unquote(category)
            })
          )

        assert report.tier == "instance"
        # The group still sees it as context — only ownership moved.
        assert report.group_id == ctx.group.id
      end
    end

    test "a group-tier report aimed at a group the post isn't in falls back to instance", ctx do
      {:ok, other} =
        Groups.create_group(ctx.outsider.id, %{
          "name" => "Unrelated",
          "handle" => "unrelatedgroup",
          "visibility" => "public",
          "join_policy" => "open"
        })

      {:ok, report} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => other.id})
        )

      # Otherwise anyone could spam an unrelated group's queue.
      assert report.tier == "instance"
    end

    test "a group-tier report with no group_id is rejected", ctx do
      assert {:error, changeset} =
               Moderation.create_report(ctx.reporter.id, report_attrs(ctx, %{"tier" => "group"}))

      assert %{group_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "the instance queue" do
    test "excludes fresh group-tier reports", ctx do
      {:ok, report} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => ctx.group.id})
        )

      refute report.id in Enum.map(Moderation.list_reports(), & &1.id)
    end

    test "includes instance-tier reports", ctx do
      {:ok, report} = Moderation.create_report(ctx.reporter.id, report_attrs(ctx, %{}))
      assert report.id in Enum.map(Moderation.list_reports(), & &1.id)
    end

    test "includes an escalated group report", ctx do
      {:ok, report} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => ctx.group.id})
        )

      {:ok, _} = Moderation.escalate_report(report.id, ctx.reporter.id)

      assert report.id in Enum.map(Moderation.list_reports(), & &1.id)
    end

    # The anti-capture rule: a group that simply never acts cannot bury it.
    test "includes a group report left untouched past the window", ctx do
      {:ok, report} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => ctx.group.id})
        )

      refute report.id in Enum.map(Moderation.list_reports(), & &1.id)

      age_report(report, Moderation.group_report_escalation_hours() + 1)

      assert report.id in Enum.map(Moderation.list_reports(), & &1.id),
             "a group sitting on a report must not keep it from instance staff forever"
    end

    test "the window is config-backed", ctx do
      Hybridsocial.Config.set("group_report_escalation_hours", 1)
      assert Moderation.group_report_escalation_hours() == 1

      {:ok, report} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => ctx.group.id})
        )

      age_report(report, 2)
      assert report.id in Enum.map(Moderation.list_reports(), & &1.id)
    end
  end

  describe "the group queue" do
    setup ctx do
      {:ok, report} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => ctx.group.id})
        )

      Map.put(ctx, :report, report)
    end

    test "a group moderator sees it", ctx do
      assert {:ok, reports} = Moderation.list_group_reports(ctx.group.id, ctx.owner.id)
      assert ctx.report.id in Enum.map(reports, & &1.id)
    end

    test "a plain member does not", ctx do
      assert {:error, :forbidden} = Moderation.list_group_reports(ctx.group.id, ctx.member.id)
    end

    test "a non-member does not", ctx do
      assert {:error, :forbidden} = Moderation.list_group_reports(ctx.group.id, ctx.outsider.id)
    end
  end

  describe "escalation" do
    setup ctx do
      {:ok, report} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => ctx.group.id})
        )

      Map.put(ctx, :report, report)
    end

    test "the reporter can escalate their own complaint", ctx do
      assert {:ok, escalated} = Moderation.escalate_report(ctx.report.id, ctx.reporter.id)
      assert escalated.tier == "instance"
      assert escalated.escalated_by == ctx.reporter.id
      assert escalated.escalated_at
    end

    test "a group moderator can hand it up", ctx do
      assert {:ok, escalated} = Moderation.escalate_report(ctx.report.id, ctx.owner.id)
      assert escalated.tier == "instance"
    end

    test "an uninvolved user cannot", ctx do
      assert {:error, :forbidden} = Moderation.escalate_report(ctx.report.id, ctx.outsider.id)
    end

    test "the reported user cannot escalate to bury it elsewhere", ctx do
      assert {:error, :forbidden} = Moderation.escalate_report(ctx.report.id, ctx.member.id)
    end

    test "escalating twice is a no-op success", ctx do
      {:ok, once} = Moderation.escalate_report(ctx.report.id, ctx.reporter.id)
      assert {:ok, twice} = Moderation.escalate_report(ctx.report.id, ctx.reporter.id)
      assert twice.escalated_at == once.escalated_at
    end

    test "a missing report 404s", ctx do
      assert {:error, :not_found} =
               Moderation.escalate_report(Ecto.UUID.generate(), ctx.reporter.id)
    end
  end

  describe "group_report_overview/1 — metadata for staff" do
    test "counts open group reports without exposing their contents", ctx do
      {:ok, fresh} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => ctx.group.id})
        )

      {:ok, old} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => ctx.group.id})
        )

      age_report(old, Moderation.group_report_escalation_hours() + 1)

      row = Enum.find(Moderation.group_report_overview(), &(&1.group_id == ctx.group.id))

      assert row.open == 2
      assert row.overdue == 1
      assert row.oldest_at

      # No content leaks through this endpoint.
      refute Map.has_key?(row, :description)
      refute Map.has_key?(row, :category)
      assert fresh.id
    end

    test "ignores resolved reports", ctx do
      {:ok, report} =
        Moderation.create_report(
          ctx.reporter.id,
          report_attrs(ctx, %{"tier" => "group", "group_id" => ctx.group.id})
        )

      report |> Report.resolve_changeset("handled") |> Repo.update!()

      refute Enum.find(Moderation.group_report_overview(), &(&1.group_id == ctx.group.id))
    end
  end
end
