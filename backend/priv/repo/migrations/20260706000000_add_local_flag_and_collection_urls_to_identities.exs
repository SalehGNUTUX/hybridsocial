defmodule Hybridsocial.Repo.Migrations.AddLocalFlagAndCollectionUrlsToIdentities do
  use Ecto.Migration

  # Supports importing legacy actors from a retired Pleroma/Rebased
  # instance while preserving their ActivityPub identity. Two things are
  # needed on the identities table:
  #
  #   * an explicit `is_local` flag — until now "local" was inferred from
  #     the `/actors/<uuid>` URL prefix, which breaks for imported actors
  #     whose `ap_actor_url` is a foreign-shaped `/users/<nickname>` URL.
  #     The durable definition is "we hold the private key", so we backfill
  #     from that.
  #
  #   * the collection URLs that were previously recomputed at serialize
  #     time (`following`, `featured`, `sharedInbox`) so imported actors can
  #     store their original values.

  def up do
    alter table(:identities) do
      add :is_local, :boolean
      add :following_url, :string
      add :featured_url, :string
      add :shared_inbox_url, :string
    end

    flush()

    # A local actor is exactly one we can sign as — i.e. one we hold a
    # private key for. Remote identity rows (create_remote_identity) have
    # no private key.
    execute("UPDATE identities SET is_local = (private_key IS NOT NULL)")

    alter table(:identities) do
      modify :is_local, :boolean, default: true, null: false
    end

    create index(:identities, [:is_local])
  end

  def down do
    alter table(:identities) do
      remove :is_local
      remove :following_url
      remove :featured_url
      remove :shared_inbox_url
    end
  end
end
