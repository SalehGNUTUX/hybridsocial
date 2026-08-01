defmodule Hybridsocial.Push.Vapid do
  @moduledoc """
  VAPID key management for Web Push notifications.
  Keys are generated once per instance and stored in the database.
  """

  alias Hybridsocial.Config

  @doc "Get or generate VAPID public key. Generated once, stored in DB settings."
  def public_key do
    case Config.get("vapid_public_key") do
      nil -> generate_and_store()[:public]
      "" -> generate_and_store()[:public]
      key -> key
    end
  end

  @doc "Get VAPID private key from DB settings."
  def private_key do
    Config.get("vapid_private_key", "")
  end

  defp generate_and_store do
    # Generate ECDSA P-256 key pair
    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)

    public_b64 = Base.url_encode64(pub, padding: false)
    private_b64 = Base.url_encode64(priv, padding: false)

    Config.set("vapid_public_key", public_b64)
    Config.set("vapid_private_key", private_b64)

    %{public: public_b64, private: private_b64}
  rescue
    error -> unstorable_key(error)
  catch
    # The config store isn't running (it isn't in the test supervision tree).
    # A keypair we can't persist is worse than none — every call would mint a
    # different one — so report "no push" instead of handing back a key that
    # no subscription will ever match.
    :exit, reason -> unstorable_key(reason)
  end

  defp unstorable_key(reason) do
    require Logger

    Logger.warning("VAPID keypair could not be stored, Web Push unavailable: #{inspect(reason)}")

    %{public: nil, private: nil}
  end
end
