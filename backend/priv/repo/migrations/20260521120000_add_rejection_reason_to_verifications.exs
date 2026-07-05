defmodule Hybridsocial.Repo.Migrations.AddRejectionReasonToVerifications do
  use Ecto.Migration

  def change do
    alter table(:verifications) do
      add :rejection_reason, :text
    end
  end
end
