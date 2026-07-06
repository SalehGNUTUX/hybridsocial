defmodule Hybridsocial.Accounts.BotWebhookDelivery do
  @moduledoc """
  One outbound HTTP attempt to a bot's configured webhook. Rows live
  in a queue drained by `Hybridsocial.Bots.WebhookDeliveryWorker`. The
  row stays for history even after success / final failure so bot
  owners can audit recent deliveries from Developer Tools.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(pending delivered failed)

  schema "bot_webhook_deliveries" do
    belongs_to :bot_identity, Hybridsocial.Accounts.Identity, foreign_key: :bot_identity_id

    field :webhook_url, :string
    field :event, :string
    field :payload, :map, default: %{}

    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_status_code, :integer
    field :last_error, :string

    field :next_attempt_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec

    # Only inserted_at — rows are immutable history once finalised, so
    # an updated_at column would just rot.
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :bot_identity_id,
      :webhook_url,
      :event,
      :payload,
      :status,
      :attempts,
      :last_status_code,
      :last_error,
      :next_attempt_at,
      :delivered_at
    ])
    |> validate_required([:bot_identity_id, :webhook_url, :event, :payload])
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:bot_identity_id)
  end
end
