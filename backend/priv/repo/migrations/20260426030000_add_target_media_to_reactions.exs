defmodule Hybridsocial.Repo.Migrations.AddTargetMediaToReactions do
  use Ecto.Migration

  # Per-image reactions on multi-image posts (Instagram-style).
  #
  # Posts already carry `target_media_id` to scope replies. Mirror it
  # on reactions so a 4-image post can collect a separate ❤ count per
  # image plus a parent-level reaction.
  #
  # The old `(post_id, identity_id)` unique constraint must be widened
  # to include the media column. Postgres 15+ supports
  # `NULLS NOT DISTINCT` so the post-level (target_media_id IS NULL)
  # case still gets deduped to one reaction per user per post — prod
  # is on PG 17 (see docker-compose).
  def up do
    alter table(:reactions) do
      add :target_media_id,
          references(:media, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:reactions, [:target_media_id])

    execute "DROP INDEX IF EXISTS reactions_post_id_identity_id_index"

    execute """
    CREATE UNIQUE INDEX reactions_post_user_media_unique
      ON reactions (post_id, identity_id, target_media_id)
      NULLS NOT DISTINCT
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS reactions_post_user_media_unique"

    create unique_index(:reactions, [:post_id, :identity_id])

    drop_if_exists index(:reactions, [:target_media_id])

    alter table(:reactions) do
      remove :target_media_id
    end
  end
end
