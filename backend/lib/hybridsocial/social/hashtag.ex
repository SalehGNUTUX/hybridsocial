defmodule Hybridsocial.Social.Hashtag do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hashtags" do
    # `name` is the lowercase canonical key — what every lookup hits.
    # `display_name` is the first-seen casing, used for rendering
    # everywhere a hashtag chip / trending row / tag page header is
    # shown. Lookup stays case-insensitive (HelloWorld == helloworld
    # == HELLOWORLD), display preserves what the first author typed.
    field :name, :string
    field :display_name, :string
    field :usage_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(hashtag, attrs) do
    hashtag
    |> cast(attrs, [:name, :display_name, :usage_count])
    |> validate_required([:name])
    |> update_change(:name, &String.downcase/1)
    |> unique_constraint(:name)
  end
end
