defmodule Hybridsocial.Auth.Token do
  @moduledoc """
  JWT token generation and verification using Joken.

  Access tokens are 15 minutes. They're stateless JWTs, so the short
  life bounds the blast radius of a leak and the window in which a
  revoked-but-not-yet-expired token could still be replayed. Clients
  refresh transparently on 401. Refresh tokens are 90 days and rotate
  on every use, so an active user effectively never logs out, and a
  refresh is the checkpoint where server-side revocation is enforced.

  Third-party OAuth apps are the exception: Mastodon-API clients treat
  an access token as permanent and never call the refresh grant, so a
  15-minute token would strand them. Tokens minted through the
  authorization-code flow get a longer TTL (`oauth_app_token_ttl_days`,
  admin-configurable) and stay revocable through their `oauth_tokens`
  row, which is what the Auth plug actually checks on every request.
  """
  use Joken.Config

  @access_token_ttl 15 * 60
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

  @doc """
  Access token with an explicit lifetime, for third-party OAuth apps.

  Joken only fills in a claim the caller didn't supply, so passing `exp`
  here overrides the 15-minute `default_exp` from `token_config/0`.
  """
  def generate_access_token(identity_id, ttl_seconds) when is_integer(ttl_seconds) do
    claims = %{
      "sub" => identity_id,
      "type" => "access",
      "exp" => System.system_time(:second) + ttl_seconds
    }

    generate_and_sign(claims, signer())
  end

  @doc """
  Lifetime of a token issued to a third-party OAuth application.

  Admin-configurable; defaults to 60 days.
  """
  def oauth_app_token_ttl do
    days = Hybridsocial.Config.get("oauth_app_token_ttl_days", 60)

    days =
      cond do
        is_integer(days) -> days
        is_binary(days) -> String.to_integer(days)
        true -> 60
      end

    max(days, 1) * 24 * 3600
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
