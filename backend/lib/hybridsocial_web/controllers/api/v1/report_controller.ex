defmodule HybridsocialWeb.Api.V1.ReportController do
  use HybridsocialWeb, :controller

  alias Hybridsocial.{Accounts, Moderation, Social}
  alias Hybridsocial.Accounts.Identity
  alias Hybridsocial.Federation.{ActivityBuilder, LocalUrl, Publisher}

  require Logger

  def create(conn, params) do
    reporter_id = conn.assigns.current_identity.id
    forward? = truthy?(params["forward"])
    block? = truthy?(params["block_account"])

    attrs =
      params
      |> Map.drop(["forward", "block_account"])
      |> Map.put("federated", forward?)

    case Moderation.create_report(reporter_id, attrs) do
      {:ok, report} ->
        reported = report.reported_id && Accounts.get_identity(report.reported_id)

        Moderation.fire_webhook("report.filed", %{
          id: report.id,
          reporter_id: reporter_id,
          reported_id: report.reported_id,
          target_type: report.target_type,
          target_id: report.target_id,
          category: report.category,
          forwarded: forward?
        })

        # Async staff fan-out — already rate-limited per-recipient in
        # the dispatcher. Preload both sides of the report so the
        # email template can render reporter/reported handles without
        # a second DB hit per admin.
        Task.Supervisor.start_child(Hybridsocial.TaskSupervisor, fn ->
          preloaded = Hybridsocial.Repo.preload(report, [:reporter, :reported])

          Hybridsocial.Notifications.StaffEmail.dispatch(
            "admin_new_report",
            "reports.manage",
            fn to, staff_identity ->
              Hybridsocial.Emails.admin_new_report_email(to, staff_identity, preloaded)
            end
          )
        end)

        # Optional: reporter asked us to also block the reported user
        # locally. Fire-and-forget — a failed block doesn't invalidate
        # the report itself.
        if block? and reported do
          try do
            Social.block(reporter_id, reported.id)
          rescue
            e -> Logger.warning("report block failed: #{Exception.message(e)}")
          end
        end

        # Optional: federate the report as an ActivityPub Flag to the
        # origin instance so their moderators see it too. Only makes
        # sense when the reported account actually lives remotely.
        if (forward? and reported) && remote?(reported) do
          Task.Supervisor.start_child(Hybridsocial.TaskSupervisor, fn ->
            forward_to_origin(report, reported)
          end)
        end

        conn
        |> put_status(:created)
        |> json(%{
          id: report.id,
          category: report.category,
          status: report.status,
          forwarded: (forward? and reported) && remote?(reported),
          blocked: block?,
          message: "report.created"
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp remote?(%Identity{} = identity), do: not LocalUrl.local_identity?(identity)
  defp remote?(_), do: false

  defp forward_to_origin(report, reported) do
    post_ap_id =
      if report.target_type == "post" do
        Hybridsocial.Repo.get(Hybridsocial.Social.Post, report.target_id) &&
          Hybridsocial.Repo.get(Hybridsocial.Social.Post, report.target_id).ap_id
      end

    inbox =
      case Hybridsocial.Repo.get_by(Hybridsocial.Federation.RemoteActor,
             ap_id: reported.ap_actor_url
           ) do
        nil -> reported.inbox_url
        ra -> ra.shared_inbox_url || ra.inbox_url
      end

    if is_binary(inbox) and inbox != "" do
      activity = ActivityBuilder.build_flag(report, reported.ap_actor_url, post_ap_id)

      case Publisher.deliver_as_instance(activity, inbox) do
        {:ok, _} ->
          Logger.info("report #{report.id} forwarded to #{inbox}")

        {:error, reason} ->
          Logger.warning("report #{report.id} forward failed: #{inspect(reason)}")
      end
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
