defmodule Hybridsocial.Repo.Migrations.AddRelayActorUrl do
  use Ecto.Migration

  @moduledoc """
  Pleroma-style relays are subscribed to by following the relay's
  actor URL directly (object = <actor_url>) rather than the
  Mastodon-style "follow Public" convention. Store the actor URL
  separately so the subscribe/undo paths can distinguish and so
  inbound Accept activities can be matched back to the right row.
  """

  def change do
    alter table(:relays) do
      add :actor_url, :string
    end
  end
end
