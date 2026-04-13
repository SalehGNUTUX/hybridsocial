defmodule Hybridsocial.Repo.Migrations.AddBotRateLimits do
  use Ecto.Migration

  def change do
    alter table(:bots) do
      # nil = use global default
      add :posts_per_hour, :integer
    end
  end
end
