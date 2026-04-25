defmodule Hybridsocial.Repo.Migrations.AddDisplayNameToHashtags do
  use Ecto.Migration

  @moduledoc """
  Hashtags lookup is case-insensitive (one canonical lowercase row
  per tag), but the display should reflect the *first* author's
  casing. Adds a sibling column for the case-preserved form and
  backfills existing rows from the lowercase name so nothing
  regresses to a blank label.
  """

  def up do
    alter table(:hashtags) do
      add :display_name, :string
    end

    execute("UPDATE hashtags SET display_name = name WHERE display_name IS NULL")
  end

  def down do
    alter table(:hashtags) do
      remove :display_name
    end
  end
end
