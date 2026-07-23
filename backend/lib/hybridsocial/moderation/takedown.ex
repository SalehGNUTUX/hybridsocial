defmodule Hybridsocial.Moderation.Takedown do
  @moduledoc """
  A record that content (a group, page, post, media, or verified badge) was
  removed by staff for a reason. It carries the reason shown to the owner, the
  appeal window, and the lifecycle status so the owner can be notified, appeal
  to restore, or — if they never appeal — be auto-purged after the window.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @target_types ~w(group page post media account_badge)
  @statuses ~w(active appealed restored purged)

  schema "moderation_takedowns" do
    field :target_type, :string
    field :target_id, :string
    field :reason, :string
    field :category, :string
    field :status, :string, default: "active"
    field :purge_after, :utc_datetime_usec
    field :notified_inapp_at, :utc_datetime_usec
    field :notified_email_at, :utc_datetime_usec
    field :reminded_at, :utc_datetime_usec

    belongs_to :owner, Hybridsocial.Accounts.Identity
    belongs_to :moderator, Hybridsocial.Accounts.Identity

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(takedown, attrs) do
    takedown
    |> cast(attrs, [
      :target_type,
      :target_id,
      :owner_id,
      :moderator_id,
      :reason,
      :category,
      :status,
      :purge_after,
      :notified_inapp_at,
      :notified_email_at,
      :reminded_at
    ])
    |> validate_required([:target_type, :target_id, :reason, :purge_after])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:reason, min: 3, max: 5000)
  end

  def status_changeset(takedown, status) when status in @statuses do
    change(takedown, status: status)
  end

  def target_types, do: @target_types
  def statuses, do: @statuses
end
