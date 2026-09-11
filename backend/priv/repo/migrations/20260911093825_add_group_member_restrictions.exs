defmodule Hybridsocial.Repo.Migrations.AddGroupMemberRestrictions do
  use Ecto.Migration

  def change do
    alter table(:group_members) do
      # Partial ban: which actions this member may NOT take. Empty = a member
      # in good standing. A full ban stays `status: :banned` — this is the
      # granular tier below it.
      add :restrictions, {:array, :string}, null: false, default: []

      # When the current sanction (full ban or restrictions) lapses.
      # NULL = permanent. Evaluated at read time, not only by the sweeper, so
      # a late or dead worker tick can't keep someone sanctioned past their
      # time.
      add :restricted_until, :utc_datetime_usec

      # Accountability, mirroring how moderation actions are recorded
      # elsewhere: who applied it and why.
      add :restricted_by, references(:identities, type: :binary_id, on_delete: :nilify_all)
      add :restriction_reason, :text
    end

    # The expiry sweeper looks for rows whose sanction has lapsed; without
    # this it scans every membership on the instance every tick.
    create index(:group_members, [:restricted_until],
             where: "restricted_until IS NOT NULL",
             name: :group_members_restricted_until_idx
           )
  end
end
