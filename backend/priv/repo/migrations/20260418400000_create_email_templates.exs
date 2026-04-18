defmodule Hybridsocial.Repo.Migrations.CreateEmailTemplates do
  use Ecto.Migration

  @moduledoc """
  Admin-editable overrides for transactional emails. The `key` is the
  semantic email name (e.g. `confirmation`, `password_reset`) and is
  the primary key — there's exactly one override per email type, and
  a missing row means "use the hardcoded default". `enabled = false`
  on a row also means "use the default" without losing the draft.
  """

  def change do
    create table(:email_templates, primary_key: false) do
      add :key, :string, primary_key: true
      add :subject, :text, null: false
      add :html_body, :text, null: false
      add :enabled, :boolean, default: true, null: false
      add :updated_by, :binary_id

      timestamps(type: :utc_datetime_usec)
    end
  end
end
