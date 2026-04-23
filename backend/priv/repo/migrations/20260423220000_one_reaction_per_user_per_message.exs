defmodule Hybridsocial.Repo.Migrations.OneReactionPerUserPerMessage do
  use Ecto.Migration

  @moduledoc """
  Enforces one reaction per user per message. Previously a user could
  stack several emoji on a single bubble (❤ + 😂 + 🎉 …); the new UX
  treats reactions as a single-choice toggle (click same → remove,
  click different → swap).

  Deduplicates existing rows before tightening the unique index —
  keeping the most-recently-inserted reaction per (message_id, identity_id)
  so the enforced state matches what the user most recently expressed.
  """

  def up do
    execute("""
    DELETE FROM message_reactions r
    USING message_reactions r2
    WHERE r.message_id = r2.message_id
      AND r.identity_id = r2.identity_id
      AND r.inserted_at < r2.inserted_at
    """)

    drop_if_exists unique_index(:message_reactions, [:message_id, :identity_id, :emoji])
    create unique_index(:message_reactions, [:message_id, :identity_id])
  end

  def down do
    drop_if_exists unique_index(:message_reactions, [:message_id, :identity_id])
    create unique_index(:message_reactions, [:message_id, :identity_id, :emoji])
  end
end
