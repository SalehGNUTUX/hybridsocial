defmodule Hybridsocial.Repo.Migrations.CreateModerationTakedowns do
  use Ecto.Migration

  def change do
    create table(:moderation_takedowns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # What was taken down. target_id is a plain string (not a binary_id FK)
      # because the target spans several tables — groups, page/account
      # identities, posts, media — and outlives the soft-deleted row it points
      # at, so we can't hang a foreign key on a single table.
      add :target_type, :string, null: false
      add :target_id, :string, null: false

      # Who owns the content (notified + can appeal) and who took it down.
      add :owner_id, references(:identities, type: :binary_id, on_delete: :nilify_all)
      add :moderator_id, references(:identities, type: :binary_id, on_delete: :nilify_all)

      add :reason, :text, null: false
      add :category, :string
      add :status, :string, null: false, default: "active"

      # No appeal by this instant → the auto-purge worker hard-deletes.
      add :purge_after, :utc_datetime_usec, null: false
      add :notified_inapp_at, :utc_datetime_usec
      add :notified_email_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:moderation_takedowns, [:owner_id])
    create index(:moderation_takedowns, [:target_type, :target_id])
    # The purge worker scans for active takedowns past their window.
    create index(:moderation_takedowns, [:status, :purge_after])
  end
end
