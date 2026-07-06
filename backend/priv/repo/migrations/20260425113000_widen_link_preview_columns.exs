defmodule Hybridsocial.Repo.Migrations.WidenLinkPreviewColumns do
  use Ecto.Migration

  @moduledoc """
  OG metadata regularly exceeds the original 255-char ceiling
  (long article titles, query-string-laden image URLs, branded
  site names with separators). Inserts were 500ing with
  `string_data_right_truncation`, which propagated up and killed
  /api/v1/timelines/public when any link in the feed had wide
  metadata. Bump to text — Postgres stores it identically to
  varchar(n) on disk, only the length check changes.
  """

  def up do
    alter table(:link_previews) do
      modify :title, :text
      modify :image_url, :text
      modify :site_name, :text
    end
  end

  def down do
    # Truncate any rows that grew past the old limit so the cast
    # back to varchar(255) succeeds.
    execute("UPDATE link_previews SET title = LEFT(title, 255) WHERE length(title) > 255")

    execute(
      "UPDATE link_previews SET image_url = LEFT(image_url, 255) WHERE length(image_url) > 255"
    )

    execute(
      "UPDATE link_previews SET site_name = LEFT(site_name, 255) WHERE length(site_name) > 255"
    )

    alter table(:link_previews) do
      modify :title, :string
      modify :image_url, :string
      modify :site_name, :string
    end
  end
end
