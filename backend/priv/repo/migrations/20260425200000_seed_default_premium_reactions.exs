defmodule Hybridsocial.Repo.Migrations.SeedDefaultPremiumReactions do
  use Ecto.Migration

  @moduledoc """
  Seeds the admin-curated premium-reaction catalog with the seven
  reactions a paid tier gets on top of the default 7. Idempotent —
  inserts only when the shortcode isn't already present, so an
  operator that has customized the catalog by hand won't lose
  their changes.
  """

  @reactions [
    {"fire", "🔥", 0},
    {"pray", "🙏", 1},
    {"broken_heart", "💔", 2},
    {"thinking", "🤔", 3},
    {"vomiting", "🤮", 4},
    {"cool", "😎", 5},
    {"facepalm", "🤦", 6}
  ]

  def up do
    now =
      DateTime.utc_now()
      |> DateTime.truncate(:microsecond)
      |> NaiveDateTime.to_iso8601()

    Enum.each(@reactions, fn {shortcode, character, position} ->
      execute("""
      INSERT INTO premium_reaction_emojis
        (id, shortcode, character, position, enabled, inserted_at, updated_at)
      SELECT
        gen_random_uuid(),
        '#{shortcode}',
        '#{character}',
        #{position},
        true,
        '#{now}',
        '#{now}'
      WHERE NOT EXISTS (
        SELECT 1 FROM premium_reaction_emojis WHERE shortcode = '#{shortcode}'
      )
      """)
    end)
  end

  def down do
    # Don't auto-delete on rollback — the operator may have edited
    # these rows after the seed; safer to leave them in place.
    :ok
  end
end
