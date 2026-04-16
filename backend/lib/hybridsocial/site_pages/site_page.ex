defmodule Hybridsocial.SitePages.SitePage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "site_pages" do
    field :slug, :string
    field :title, :string
    field :body_markdown, :string, default: ""
    field :body_html, :string, default: ""
    field :published, :boolean, default: false
    field :last_edited_by, :binary_id
    field :deleted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @allowed_slugs ~w(privacy terms about)

  def changeset(page, attrs) do
    page
    |> cast(attrs, [:slug, :title, :body_markdown, :published, :last_edited_by])
    |> validate_required([:slug, :title])
    |> validate_length(:title, max: 100)
    |> validate_length(:body_markdown, max: 50_000)
    |> validate_inclusion(:slug, @allowed_slugs,
      message: "must be one of: #{Enum.join(@allowed_slugs, ", ")}"
    )
    |> unique_constraint(:slug)
    |> render_markdown()
  end

  defp render_markdown(changeset) do
    case get_change(changeset, :body_markdown) do
      nil ->
        changeset

      markdown ->
        # Site pages are admin-authored and trusted — render with the full
        # GFM surface (tables, task lists, images, strikethrough, code
        # fences, ordered lists, etc.) via Earmark + the widest sanitizer
        # allowlist. Links still get rel/target applied by Sanitizer.
        html =
          markdown
          |> Hybridsocial.Content.MarkdownRenderer.render_trusted()
          |> Hybridsocial.Content.Sanitizer.sanitize_links()

        put_change(changeset, :body_html, html)
    end
  end
end
