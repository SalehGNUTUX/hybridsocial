defmodule Hybridsocial.Federation.Relay do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @valid_statuses ~w(pending accepted rejected failed)

  schema "relays" do
    field :inbox_url, :string
    field :status, :string, default: "pending"
    # For Pleroma-style relays we subscribe by following the relay's
    # actor URL; for Mastodon-style we follow AS:Public and the
    # actor_url is the sender of the Accept. Tracking both lets us
    # send correctly-shaped Undos + match Accept activities back to
    # this row regardless of the relay's flavor.
    field :actor_url, :string
    # The AS id of the Follow we sent — lets us emit a matching Undo
    # later without rebuilding the activity from scratch.
    field :follow_activity_id, :string
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(relay, attrs) do
    relay
    |> cast(attrs, [:inbox_url, :status, :actor_url, :follow_activity_id, :last_error])
    |> validate_required([:inbox_url])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:inbox_url)
  end
end
