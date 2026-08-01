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
  #
  # The cached value carries the session's `application_id` and `scopes` so
  # Plugs.RequireScope can enforce the grant without a second lookup. A bare
  # `true` is an entry written by an older release; it's treated as a
  # first-party session and ages out within the TTL.

  @session_ttl 60

  def cache_session_active(token_hash, session \\ true, ttl \\ @session_ttl) do
    Cache.set("session_active:#{token_hash}", session, ttl)
  end

  def session_active_cached(token_hash) do
    Cache.get("session_active:#{token_hash}")
  end

  def invalidate_session(token_hash) do
    Cache.delete("session_active:#{token_hash}")
  end
end
