defmodule Hybridsocial.Repo.Migrations.AddCircuitBreakerToRemoteInstances do
  use Ecto.Migration

  # Per-domain delivery circuit breaker: after N consecutive connection-level
  # failures (nxdomain / TLS / connect timeout — i.e. the instance is down, not
  # merely rejecting one activity) we stop attempting delivery until
  # `circuit_reopen_at`, then allow a single probe to recover. Stops the
  # unbounded per-activity hammering of dead instances.
  def change do
    alter table(:remote_instances) do
      add :consecutive_failures, :integer, default: 0, null: false
      add :unreachable_since, :utc_datetime_usec
      add :circuit_reopen_at, :utc_datetime_usec
    end

    # `allow?/1` filters on reopen time when the circuit is open.
    create index(:remote_instances, [:circuit_reopen_at])
  end
end
