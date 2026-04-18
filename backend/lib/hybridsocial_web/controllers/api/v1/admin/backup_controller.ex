defmodule HybridsocialWeb.Api.V1.Admin.BackupController do
  use HybridsocialWeb, :controller

  alias Hybridsocial.Admin.Backup
  alias Hybridsocial.Auth.RBAC

  defp require_permission(conn, permission) do
    identity = conn.assigns.current_identity

    if RBAC.has_permission?(identity.id, permission) do
      :ok
    else
      {:error, permission}
    end
  end

  defp deny(conn, permission) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "permission.denied", required: permission})
  end

  def create(conn, params) do
    with :ok <- require_permission(conn, "backups.create") do
      do_create(conn, params)
    else
      {:error, perm} -> deny(conn, perm)
    end
  end

  defp do_create(conn, params) do
    admin_id = conn.assigns.current_identity.id
    passphrase = params["passphrase"]
    type = params["type"] || "full"

    if is_nil(passphrase) or passphrase == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "backup.passphrase_required"})
    else
      case Backup.create_backup(admin_id, passphrase, type) do
        {:ok, backup_job} ->
          conn
          |> put_status(:accepted)
          |> json(%{data: serialize_backup(backup_job)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "validation.failed", details: format_errors(changeset)})
      end
    end
  end

  def index(conn, _params) do
    with :ok <- require_permission(conn, "backups.view") do
      backups = Backup.list_backups()

      conn
      |> put_status(:ok)
      |> json(%{data: Enum.map(backups, &serialize_backup/1)})
    else
      {:error, perm} -> deny(conn, perm)
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_permission(conn, "backups.view") do
      case Backup.get_backup(id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "backup.not_found"})

        backup_job ->
          conn
          |> put_status(:ok)
          |> json(%{data: serialize_backup(backup_job)})
      end
    else
      {:error, perm} -> deny(conn, perm)
    end
  end

  def download(conn, %{"id" => id}) do
    with :ok <- require_permission(conn, "backups.view") do
      do_download(conn, id)
    else
      {:error, perm} -> deny(conn, perm)
    end
  end

  defp do_download(conn, id) do
    case Backup.read_backup_file(id) do
      {:ok, bin, filename} ->
        conn
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> put_resp_content_type("application/octet-stream")
        |> send_resp(200, bin)

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "backup.not_found"})

      {:error, :no_file} ->
        conn |> put_status(:not_found) |> json(%{error: "backup.no_file"})

      {:error, {:file_read_error, reason}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "backup.file_missing",
          message:
            "The backup file is missing on disk (#{inspect(reason)}). If backups were created before a container rebuild, they're gone — the volume wasn't persistent."
        })
    end
  end

  def restore(conn, %{"id" => id} = params) do
    with :ok <- require_permission(conn, "backups.restore") do
      do_restore(conn, id, params)
    else
      {:error, perm} -> deny(conn, perm)
    end
  end

  defp do_restore(conn, id, params) do
    passphrase = params["passphrase"]
    confirmation = params["confirmation"]

    cond do
      is_nil(passphrase) or passphrase == "" ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "backup.passphrase_required"})

      confirmation != "RESTORE" ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "backup.confirmation_required",
          message: "Restoring a backup is destructive. Send confirmation: \"RESTORE\" to proceed."
        })

      true ->
        case Backup.restore_backup(id, passphrase) do
          {:ok, :restored} ->
            json(conn, %{status: "ok", message: "Database restored."})

          {:error, :not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "backup.not_found"})

          {:error, :no_file} ->
            conn |> put_status(:not_found) |> json(%{error: "backup.no_file"})

          {:error, :invalid_passphrase} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "backup.invalid_passphrase"})

          {:error, :decryption_failed} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "backup.decryption_failed"})

          {:error, {:file_read_error, reason}} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "backup.file_read_error", details: inspect(reason)})

          {:error, {:pg_restore_failed, exit_code, output}} ->
            conn
            |> put_status(:bad_gateway)
            |> json(%{
              error: "backup.pg_restore_failed",
              exit_code: exit_code,
              output: output
            })
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- require_permission(conn, "backups.create") do
      case Backup.delete_backup(id) do
        {:ok, :deleted} ->
          json(conn, %{status: "ok"})

        {:error, :not_found} ->
          conn |> put_status(:not_found) |> json(%{error: "backup.not_found"})
      end
    else
      {:error, perm} -> deny(conn, perm)
    end
  end

  defp serialize_backup(backup_job) do
    %{
      id: backup_job.id,
      type: backup_job.type,
      status: backup_job.status,
      file_path: backup_job.file_path,
      file_size: backup_job.file_size,
      started_at: backup_job.started_at,
      completed_at: backup_job.completed_at,
      initiated_by: backup_job.initiated_by,
      created_at: backup_job.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
