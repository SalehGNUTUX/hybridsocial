defmodule Hybridsocial.Cache.TokenCache do
  @moduledoc "Identity/token caching to avoid DB lookups on every request."

  alias Hybridsocial.Cache

  def cache_identity(identity_id, identity_data, ttl \\ 300) do
    Cache.set("identity:#{identity_id}", identity_data, ttl)
  end

  def get_cached_identity(identity_id) do
    Cache.get("identity:#{identity_id}")
  end

  def invalidate_identity(identity_id) do
    Cache.delete("identity:#{identity_id}")
  end

  # --- Access-token session validity ---
  #
  # Positive cache of "this access token maps to a live, non-revoked
  # session row". Lets the auth plug enforce revocation without a DB
  # lookup on every request: on a miss it hits the DB once, then caches
  # the result for `ttl` seconds. Revocation invalidates the key for
  # instant effect on the single-token paths; bulk paths rely on the TTL.

  @session_ttl 60

  def cache_session_active(token_hash, ttl \\ @session_ttl) do
    Cache.set("session_active:#{token_hash}", true, ttl)
  end

  def session_active_cached(token_hash) do
    Cache.get("session_active:#{token_hash}")
  end

  def invalidate_session(token_hash) do
    Cache.delete("session_active:#{token_hash}")
  end
end
