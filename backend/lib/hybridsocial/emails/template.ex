defmodule Hybridsocial.Emails.Template do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}

  schema "email_templates" do
    field :subject, :string
    field :html_body, :string
    field :enabled, :boolean, default: true
    field :updated_by, Ecto.UUID

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [:key, :subject, :html_body, :enabled, :updated_by])
    |> validate_required([:key, :subject, :html_body])
    |> validate_length(:subject, max: 300)
    |> validate_length(:html_body, max: 200_000)
  end
end
