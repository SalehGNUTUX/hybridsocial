defmodule Hybridsocial.Repo.Migrations.AddEmojisAndProfileUrlToIdentities do
  use Ecto.Migration

  def change do
    alter table(:identities) do
      # Custom emoji manifest for this actor's display_name/bio, mirrored
      # from the AP actor `tag` (each: %{"shortcode", "url", "static_url"}).
      add :emojis, {:array, :map}, null: false, default: []
      # The actor's human-facing HTML profile URL (AP `url`), for the
      # "view on original instance" link. Distinct from ap_actor_url (the
      # AP id). text to match the widened url columns.
      add :profile_url, :text
    end
  end
end
