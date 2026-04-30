defmodule Hybridsocial.Repo.Migrations.CreateServiceMetrics do
  use Ecto.Migration

  def change do
    create table(:service_metrics, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :service, :string, null: false
      add :metric, :string, null: false
      add :value, :float, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    # Hot path: dashboard reads "last N hours of (service, metric)".
    # The composite index covers both the per-(service, metric) series
    # query and the summary's "all rows in last hour" scan via index-only
    # scan over the leading column. We tried adding a partial index
    # WHERE inserted_at > now() - interval '2 hours' to make the summary
    # cheaper, but Postgres rejects it because now() isn't IMMUTABLE.
    create index(:service_metrics, [:service, :metric, :inserted_at])
  end
end
