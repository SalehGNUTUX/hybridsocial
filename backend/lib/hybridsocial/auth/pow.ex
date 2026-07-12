defmodule Hybridsocial.Auth.PoW do
  @moduledoc """
  Proof of Work challenge for abuse-prone endpoints.

  Each challenge is bound to a server-issued prefix stored in the
  Valkey cache with a 5-minute TTL. Verification requires both that
  the prefix is still in the cache (server issued it, hasn't been
  consumed, hasn't expired) AND that the submitted nonce produces a
  hash with the required leading-zero difficulty. On successful
  verification the cache entry is deleted so each challenge is
  single-use — prevents the same solution being replayed.

  If Valkey is unavailable, verification fails closed (returns
  false). This is intentional — the point of PoW is rate-limiting
  by making work mandatory, and silently accepting challenges we
  didn't issue defeats that.
  """

  alias Hybridsocial.Cache
  alias Hybridsocial.Config

  @ttl_seconds 300

  def enabled? do
    Config.get("pow_enabled", false) == true
  end

  def difficulty do
    Config.get("pow_difficulty", 16)
  end

  def generate_challenge(diff \\ nil) do
    diff = diff || difficulty()
    prefix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    expires_at = DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)

    try do
      Cache.set("pow:#{prefix}", %{"difficulty" => diff}, @ttl_seconds)
    rescue
      _ -> :ok
    end

    %{prefix: prefix, difficulty: diff, expires_at: expires_at}
  end

  # Clients send the nonce as a JSON number (register/login/reset) or a
  # string (recover). Normalize integers to their decimal string so the
  # hash matches what the browser computed with `prefix + String(nonce)`.
  def verify(prefix, nonce) when is_binary(prefix) and is_integer(nonce),
    do: verify(prefix, Integer.to_string(nonce))

  def verify(prefix, nonce) when is_binary(prefix) and is_binary(nonce) do
    case Cache.get("pow:#{prefix}") do
      nil ->
        false

      challenge ->
        stored_diff = Map.get(challenge, "difficulty") || Map.get(challenge, :difficulty)

        if valid_solution?(prefix, nonce, stored_diff) do
          # Single-use: consume the challenge so the same solution
          # can't be replayed.
          Cache.delete("pow:#{prefix}")
          true
        else
          false
        end
    end
  end

  def verify(_, _), do: false

  defp valid_solution?(prefix, nonce, diff) when is_integer(diff) and diff > 0 do
    hash = :crypto.hash(:sha256, prefix <> nonce)
    count_leading_zero_bits(hash) >= diff
  end

  defp valid_solution?(_, _, _), do: false

  defp count_leading_zero_bits(<<0::1, rest::bitstring>>), do: 1 + count_leading_zero_bits(rest)
  defp count_leading_zero_bits(_), do: 0
end
