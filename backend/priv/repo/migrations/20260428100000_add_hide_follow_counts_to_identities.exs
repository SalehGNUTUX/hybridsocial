defmodule Hybridsocial.Repo.Migrations.AddHideFollowCountsToIdentities do
  use Ecto.Migration

  def change do
    alter table(:identities) do
      add :hide_follow_counts, :boolean, default: false, null: false
    end
  end
end
