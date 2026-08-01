defmodule Hybridsocial.Repo.Migrations.RelaxPkceRequirementOnAuthorizationCodes do
  @moduledoc """
  Makes PKCE optional on authorization codes.

  Mastodon-API clients (Husky, Tusky, the official apps) use the classic
  confidential-client flow: client_id + client_secret, no code_challenge.
  Requiring a challenge at the DB level meant every one of them failed at
  `/oauth/authorize`. The code is still never redeemable on possession alone —
  `Auth.OAuth.verify_client_proof/4` demands either the PKCE verifier or the
  client secret.
  """
  use Ecto.Migration

  def up do
    alter table(:oauth_authorization_codes) do
      modify :code_challenge, :string, null: true
      modify :code_challenge_method, :string, null: true, default: nil
    end
  end

  def down do
    execute "DELETE FROM oauth_authorization_codes WHERE code_challenge IS NULL"

    alter table(:oauth_authorization_codes) do
      modify :code_challenge, :string, null: false
      modify :code_challenge_method, :string, null: false, default: "S256"
    end
  end
end
