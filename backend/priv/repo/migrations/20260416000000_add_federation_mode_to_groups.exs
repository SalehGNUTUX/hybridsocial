defmodule Hybridsocial.Repo.Migrations.AddFederationModeToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :federation_mode, :string, null: false, default: "local_only"
    end

    # Existing groups that were already public should stay federated so we
    # don't retroactively unpublish their content. Everything else defaults
    # to local_only — safe by default, no accidental leakage.
    execute(
      "UPDATE groups SET federation_mode = 'public_federated' WHERE visibility = 'public'",
      "UPDATE groups SET federation_mode = 'local_only'"
    )
  end
end
