defmodule Hybridsocial.Repo.Migrations.CreateStories do
  use Ecto.Migration

  def change do
    create table(:stories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :identity_id, references(:identities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :media_id, references(:media, type: :binary_id, on_delete: :delete_all), null: false
      add :caption, :string, size: 200
      add :duration_hours, :integer, null: false, default: 24
      add :view_count, :integer, null: false, default: 0
      add :reaction_count, :integer, null: false, default: 0
      add :published_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stories, [:identity_id, :published_at])
    create index(:stories, [:expires_at])

    create table(:story_views, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false

      add :viewer_id, references(:identities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :viewed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:story_views, [:story_id, :viewer_id])
    create index(:story_views, [:viewer_id])

    create table(:story_reactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false

      add :identity_id, references(:identities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :emoji, :string, null: false, size: 32

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:story_reactions, [:story_id, :identity_id])
    create index(:story_reactions, [:story_id])
  end
end
