defmodule Hybridsocial.Repo.Migrations.RelayStatusTracking do
  use Ecto.Migration

  @moduledoc """
  Relay subscriptions need a couple more fields so we can actually
  track the ActivityPub handshake instead of just inserting a row
  and hoping:

    * follow_activity_id — the AS id of the Follow we sent, so a
      later Undo{Follow} can reference the exact same id.
    * last_error — delivery failure detail surfaced to the admin
      when a Follow (or Undo) to the relay fails.
  """

  def change do
    alter table(:relays) do
      add :follow_activity_id, :string
      add :last_error, :text
    end
  end
end
