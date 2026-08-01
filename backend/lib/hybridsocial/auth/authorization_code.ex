defmodule Hybridsocial.Auth.AuthorizationCode do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:code_hash, :string, autogenerate: false}
  @foreign_key_type :binary_id

  schema "oauth_authorization_codes" do
    field :redirect_uri, :string
    field :scopes, {:array, :string}, default: []
    field :code_challenge, :string
    field :code_challenge_method, :string, default: "S256"
    field :expires_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :application, Hybridsocial.Auth.OAuthApplication
    belongs_to :identity, Hybridsocial.Accounts.Identity
  end

  def changeset(code, attrs) do
    code
    |> cast(attrs, [
      :code_hash,
      :application_id,
      :identity_id,
      :redirect_uri,
      :scopes,
      :code_challenge,
      :code_challenge_method,
      :expires_at,
      :inserted_at
    ])
    |> validate_required([
      :code_hash,
      :application_id,
      :identity_id,
      :redirect_uri,
      :expires_at
    ])
    # PKCE is optional: a confidential client authenticates with its
    # client_secret at the token endpoint instead. `Auth.OAuth` requires one
    # or the other, so a challenge-less code is never redeemable on its own.
    |> validate_inclusion(:code_challenge_method, ["S256"])
  end
end
