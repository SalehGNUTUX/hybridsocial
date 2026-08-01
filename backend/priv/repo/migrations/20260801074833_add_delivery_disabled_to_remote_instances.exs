defmodule Hybridsocial.Repo.Migrations.AddDeliveryDisabledToRemoteInstances do
  use Ecto.Migration

  def change do
    alter table(:remote_instances) do
      # Admin kill switch for outbound delivery to a domain that is gone
      # for good (DNS dead, instance shut down). Distinct from the
      # circuit breaker, which always re-probes, and from an instance
      # policy, which is a moderation decision about inbound content.
      add :delivery_disabled_at, :utc_datetime_usec
      add :delivery_disabled_reason, :text
      add :delivery_disabled_by, :binary_id
    end

    # Publisher fan-out reads the disabled set on every publish; keep it
    # a partial index so it stays tiny regardless of peer count.
    create index(:remote_instances, [:domain],
             where: "delivery_disabled_at IS NOT NULL",
             name: :remote_instances_delivery_disabled_index
           )
  end
end
