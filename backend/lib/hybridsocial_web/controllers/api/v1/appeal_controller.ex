defmodule HybridsocialWeb.Api.V1.AppealController do
  use HybridsocialWeb, :controller

  alias Hybridsocial.Moderation

  # ── User-facing: submit and list own appeals ────────────────────────

  def create(conn, params) do
    identity_id = conn.assigns.current_identity.id

    attrs = %{
      "identity_id" => identity_id,
      "action_type" => params["action_type"],
      "reason" => params["reason"]
    }

    case Moderation.create_appeal(attrs) do
      {:ok, appeal} ->
        Moderation.fire_webhook("appeal.filed", %{
          id: appeal.id,
          identity_id: identity_id,
          action_type: appeal.action_type
        })

        Task.Supervisor.start_child(Hybridsocial.TaskSupervisor, fn ->
          preloaded = Hybridsocial.Repo.preload(appeal, :identity)

          Hybridsocial.Notifications.StaffEmail.dispatch(
            "admin_new_appeal",
            "users.manage",
            fn to, staff_identity ->
              Hybridsocial.Emails.admin_new_appeal_email(to, staff_identity, preloaded)
            end
          )
        end)

        conn |> put_status(:created) |> json(%{data: serialize_appeal(appeal)})

      {:error, :already_pending} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "appeal.already_pending"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  def index(conn, params) do
    identity_id = conn.assigns.current_identity.id

    opts = [
      identity_id: identity_id,
      status: params["status"],
      limit: clamp_limit(params["limit"]),
      offset: parse_int(params["offset"], 0)
    ]

    appeals = Moderation.list_appeals(opts)

    conn
    |> put_status(:ok)
    |> json(%{data: Enum.map(appeals, &serialize_appeal/1)})
  end

  # ── Content takedowns: the owner's list + appealing one ─────────────

  # GET /api/v1/takedowns — the caller's own takedowns (to find one to appeal).
  def my_takedowns(conn, params) do
    identity_id = conn.assigns.current_identity.id

    takedowns =
      Moderation.list_takedowns_for_owner(identity_id, limit: clamp_limit(params["limit"]))

    conn
    |> put_status(:ok)
    |> json(%{data: Enum.map(takedowns, &serialize_takedown/1)})
  end

  # POST /api/v1/takedowns/:id/appeal — the owner appeals a specific takedown.
  def appeal_takedown(conn, %{"id" => takedown_id} = params) do
    identity_id = conn.assigns.current_identity.id

    case Moderation.create_takedown_appeal(identity_id, takedown_id, params["reason"]) do
      {:ok, appeal} ->
        conn |> put_status(:created) |> json(%{data: serialize_appeal(appeal)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "takedown.not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "takedown.forbidden"})

      {:error, :not_appealable} ->
        conn |> put_status(:conflict) |> json(%{error: "takedown.not_appealable"})

      {:error, :already_pending} ->
        conn |> put_status(:conflict) |> json(%{error: "appeal.already_pending"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp serialize_appeal(appeal) do
    %{
      id: appeal.id,
      identity_id: appeal.identity_id,
      action_type: appeal.action_type,
      reason: appeal.reason,
      status: appeal.status,
      reviewed_by: appeal.reviewed_by,
      reviewed_at: appeal.reviewed_at,
      response: appeal.response,
      takedown_id: appeal.takedown_id,
      created_at: appeal.inserted_at
    }
  end

  defp serialize_takedown(takedown) do
    %{
      id: takedown.id,
      target_type: takedown.target_type,
      target_id: takedown.target_id,
      reason: takedown.reason,
      category: takedown.category,
      status: takedown.status,
      purge_after: takedown.purge_after,
      created_at: takedown.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp clamp_limit(nil), do: 20
  defp clamp_limit(val) when is_binary(val), do: clamp_limit(parse_int(val, 20))
  defp clamp_limit(val) when is_integer(val), do: min(max(val, 1), 100)

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
end
