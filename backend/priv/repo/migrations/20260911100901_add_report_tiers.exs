defmodule Hybridsocial.Repo.Migrations.AddReportTiers do
  use Ecto.Migration

  def change do
    alter table(:reports) do
      # Which queue owns this report. "instance" is the existing behaviour and
      # stays the default, so every current row and every un-tiered caller
      # keeps working untouched.
      add :tier, :string, null: false, default: "instance"

      # The group whose rules are alleged to be broken. Only meaningful for
      # tier "group". Nilify rather than cascade: if the group is deleted the
      # report should survive as an instance-tier record, not vanish.
      add :group_id, references(:groups, type: :binary_id, on_delete: :nilify_all)

      # Escalation to the instance tier. `escalated_at` doubles as the flag —
      # an escalated group report is visible to instance staff regardless of
      # how long it has been sitting.
      add :escalated_at, :utc_datetime_usec
      add :escalated_by, references(:identities, type: :binary_id, on_delete: :nilify_all)
    end

    # The group moderation queue reads by (group, status); the ageing check
    # reads open group-tier reports by age.
    create index(:reports, [:group_id, :status], where: "group_id IS NOT NULL")
    create index(:reports, [:tier, :status])
  end
end
