defmodule Hybridsocial.Repo.Migrations.RelayStatusAddFailed do
  use Ecto.Migration

  @moduledoc """
  `status` on the relays table is backed by a Postgres ENUM
  (`relay_status`) with values pending/accepted/rejected. The new
  outbound-Follow delivery path tries to flip the row to "failed"
  when delivery to the relay inbox errors, which blew up with
  `invalid input value for enum relay_status: "failed"` and left
  every relay stuck on pending.

  ALTER TYPE ... ADD VALUE must run outside a transaction, hence
  the explicit `disable_ddl_transaction/1` + `disable_migration_lock/1`.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TYPE relay_status ADD VALUE IF NOT EXISTS 'failed'"
  end

  def down do
    # Postgres can't remove an enum value without dropping and
    # recreating the type, which would cascade to every table using
    # it. Leave the value present on rollback.
    :ok
  end
end
