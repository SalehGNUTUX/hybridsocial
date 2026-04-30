defmodule Hybridsocial.Repo.Migrations.AddActivityBodyToFederationDeliveries do
  use Ecto.Migration

  def change do
    alter table(:federation_deliveries) do
      # Store the exact ActivityPub payload that would be POSTed to the
      # peer. Lets the admin Dead-Letter Queue retry a failed delivery
      # without rebuilding the activity from the post — a non-trivial
      # operation since type-specific builders (Create / Update /
      # Delete / Like / Announce / Follow) all differ. Nullable
      # because pre-existing rows won't have it; the dead-letter UI
      # surfaces "body not available" for those.
      add :activity_body, :map
    end
  end
end
