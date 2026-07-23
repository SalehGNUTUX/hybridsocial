defmodule Hybridsocial.Repo.Migrations.AddRemindedAtToTakedowns do
  use Ecto.Migration

  def change do
    alter table(:moderation_takedowns) do
      # When the pre-purge reminder was sent, so it goes out exactly once.
      add :reminded_at, :utc_datetime_usec
    end
  end
end
