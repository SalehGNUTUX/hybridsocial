defmodule Hybridsocial.Repo.Migrations.AddDurationMsToFederationDeliveries do
  use Ecto.Migration

  def change do
    alter table(:federation_deliveries) do
      # Wall-clock duration of the HTTP POST to the peer inbox, in
      # milliseconds. Captured by Publisher.deliver/3 around the
      # HTTPoison call. Lets the admin Delivery Queue tab compute
      # p50/p95 latency per destination domain.
      add :duration_ms, :integer
    end

    # Powers the percentile aggregation in DeliveryStats.latency_per_peer.
    # Same partial-index trick we tried earlier doesn't work because
    # `now()` isn't IMMUTABLE — the full composite covers the read.
    create index(:federation_deliveries, [:status, :last_attempt_at, :duration_ms])
  end
end
