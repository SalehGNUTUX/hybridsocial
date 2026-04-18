defmodule Hybridsocial.Auth.Token do
  @moduledoc """
  JWT token generation and verification using Joken.

  Access tokens are 7 days — long enough that a returning user
  after a week of inactivity is still authenticated without a
  round trip, short enough that a leaked token has a bounded
  blast radius. Refresh tokens are 90 days and rotate on every
  use, so an active user effectively never logs out.
  """
  use Joken.Config

  @access_token_ttl 7 * 24 * 3600
  @refresh_token_ttl 90 * 24 * 3600

  @impl true
  def token_config do
    default_claims(
      iss: "hybridsocial",
      default_exp: @access_token_ttl
    )
  end

  def generate_access_token(identity_id) do
    claims = %{
      "sub" => identity_id,
      "type" => "access"
    }

    generate_and_sign(claims, signer())
  end

  def verify_access_token(token) do
    case verify_and_validate(token, signer()) do
      {:ok, claims} ->
        if claims["type"] == "access" do
          {:ok, claims}
        else
          {:error, :invalid_token_type}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def generate_refresh_token do
    token = :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)
    {token, hash_token(token)}
  end

  def hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  def access_token_ttl, do: @access_token_ttl
  def refresh_token_ttl, do: @refresh_token_ttl

  defp signer do
    secret = Application.get_env(:hybridsocial, __MODULE__)[:secret] || secret_key_base()
    Joken.Signer.create("HS256", secret)
  end

  defp secret_key_base do
    Application.get_env(:hybridsocial, HybridsocialWeb.Endpoint)[:secret_key_base]
  end
end
