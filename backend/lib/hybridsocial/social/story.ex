defmodule Hybridsocial.Social.Story do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_durations [8, 16, 24]

  schema "stories" do
    field :caption, :string
    field :duration_hours, :integer, default: 24
    field :view_count, :integer, default: 0
    field :reaction_count, :integer, default: 0
    field :published_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :identity, Hybridsocial.Accounts.Identity
    belongs_to :media, Hybridsocial.Media.MediaFile

    has_many :views, Hybridsocial.Social.StoryView
    has_many :reactions, Hybridsocial.Social.StoryReaction

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(story, attrs) do
    story
    |> cast(attrs, [:identity_id, :media_id, :caption, :duration_hours])
    |> validate_required([:identity_id, :media_id, :duration_hours])
    |> validate_inclusion(:duration_hours, @valid_durations, message: "must be 8, 16, or 24")
    |> validate_length(:caption, max: 200)
    |> put_timestamps()
    |> foreign_key_constraint(:identity_id)
    |> foreign_key_constraint(:media_id)
  end

  def valid_durations, do: @valid_durations

  defp put_timestamps(changeset) do
    case get_field(changeset, :duration_hours) do
      nil ->
        changeset

      hours ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        expires = DateTime.add(now, hours * 3600, :second)

        changeset
        |> put_change(:published_at, now)
        |> put_change(:expires_at, expires)
    end
  end
end
