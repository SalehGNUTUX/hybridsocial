defmodule Hybridsocial.Social.PostRevision do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "post_revisions" do
    field :content, :string
    field :content_html, :string
    field :edited_at, :utc_datetime_usec
    field :revision_number, :integer

    belongs_to :post, Hybridsocial.Social.Post
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:post_id, :content, :content_html, :edited_at, :revision_number])
    # Content is intentionally NOT required: a revision snapshots a post's
    # prior body, and media-only posts (image/video/audio without a
    # caption) legitimately have nil content. Requiring it here made
    # editing a caption-less media post blow up when snapshotting its
    # previous (blank) content — see issue #26.
    |> validate_required([:post_id, :revision_number])
    |> foreign_key_constraint(:post_id)
  end
end
