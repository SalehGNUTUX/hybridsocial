defmodule Hybridsocial.Repo.Migrations.AddTakedownIdToAppeals do
  use Ecto.Migration

  def change do
    alter table(:moderation_appeals) do
      # An appeal against a specific content takedown (vs. an account-level
      # sanction, which stays keyed by action_type). Nullable so existing
      # suspension/silencing/etc. appeals are unaffected.
      add :takedown_id,
          references(:moderation_takedowns, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:moderation_appeals, [:takedown_id])
  end
end
