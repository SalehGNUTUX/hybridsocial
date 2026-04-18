defmodule Hybridsocial.Federation.Relay do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @valid_statuses ~w(pending accepted rejected failed)

  schema "relays" do
    field :inbox_url, :string
    field :status, :string, default: "pending"
    # The AS id of the Follow we sent — lets us emit a matching Undo
    # later without rebuilding the activity from scratch.
    field :follow_activity_id, :string
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(relay, attrs) do
    relay
    |> cast(attrs, [:inbox_url, :status, :follow_activity_id, :last_error])
    |> validate_required([:inbox_url])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:inbox_url)
  end
end
