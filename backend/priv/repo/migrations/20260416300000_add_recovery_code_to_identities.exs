defmodule Hybridsocial.Repo.Migrations.AddRecoveryCodeToIdentities do
  use Ecto.Migration

  def change do
    alter table(:identities) do
      # Bcrypt hash of the current recovery code. Never store plaintext.
      add :recovery_code_hash, :string

      # When the current code was generated (for display in settings).
      add :recovery_code_generated_at, :utc_datetime_usec

      # Last time someone successfully used this code to recover.
      add :recovery_code_last_used_at, :utc_datetime_usec

      # Set when a recovery happened. Gates sensitive actions for 24h
      # to give a real user time to counter-recover if an attacker beat them.
      add :recovered_at, :utc_datetime_usec
    end
  end
end
