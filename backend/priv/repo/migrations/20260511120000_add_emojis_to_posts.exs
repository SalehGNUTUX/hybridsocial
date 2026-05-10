defmodule Hybridsocial.Repo.Migrations.AddEmojisToPosts do
  use Ecto.Migration

  def change do
    # Per-post custom-emoji manifest. ActivityPub `Note.tag` entries
    # with type "Emoji" carry the shortcode + image URL the remote
    # instance uses for that post; we store them here so the renderer
    # can swap `:shortcode:` text for an <img>. Stored per-post (not
    # globalized into custom_emojis) because two instances can use
    # the same shortcode for different glyphs.
    alter table(:posts) do
      add :emojis, {:array, :map}, default: []
    end
  end
end
