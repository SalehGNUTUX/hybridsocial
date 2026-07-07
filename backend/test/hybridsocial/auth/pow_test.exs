defmodule Hybridsocial.Auth.PoWTest do
  use ExUnit.Case, async: true

  alias Hybridsocial.Auth.PoW
  alias Hybridsocial.Cache

  describe "verify/2" do
    test "accepts a valid solution to a server-issued challenge" do
      challenge = PoW.generate_challenge(4)
      nonce = find_nonce(challenge.prefix, 4)

      assert PoW.verify(challenge.prefix, nonce)
    end

    test "single-use: the same challenge can't be verified twice" do
      challenge = PoW.generate_challenge(4)
      nonce = find_nonce(challenge.prefix, 4)

      assert PoW.verify(challenge.prefix, nonce)
      # Re-submitting the same (prefix, nonce) pair must fail because
      # the challenge was consumed.
      refute PoW.verify(challenge.prefix, nonce)
    end

    test "rejects a prefix the server never issued (client-generated)" do
      fake_prefix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      nonce = find_nonce(fake_prefix, 4)

      refute PoW.verify(fake_prefix, nonce)
    end

    test "rejects valid prefix but wrong nonce" do
      challenge = PoW.generate_challenge(4)

      # A random nonce satisfies difficulty 4 (4 leading zero bits) ~1/16
      # of the time, so a hardcoded "bad_nonce" flakes. Use one whose hash
      # provably starts with a 1 bit — never a valid difficulty-4 solution.
      refute PoW.verify(challenge.prefix, find_non_solution(challenge.prefix))
    end

    test "rejects when the challenge has expired / been evicted" do
      challenge = PoW.generate_challenge(4)
      nonce = find_nonce(challenge.prefix, 4)

      # Simulate expiry by deleting the cache entry manually.
      Cache.delete("pow:#{challenge.prefix}")

      refute PoW.verify(challenge.prefix, nonce)
    end

    test "rejects nil inputs" do
      refute PoW.verify(nil, nil)
    end

    test "rejects non-binary nonce against a valid prefix" do
      challenge = PoW.generate_challenge(4)

      refute PoW.verify(challenge.prefix, nil)
      refute PoW.verify(challenge.prefix, 12_345)
    end
  end

  defp find_nonce(prefix, difficulty) do
    Enum.reduce_while(0..1_000_000, nil, fn i, _acc ->
      nonce = Integer.to_string(i)
      hash = :crypto.hash(:sha256, prefix <> nonce)
      zeros = count_zeros(hash)

      if zeros >= difficulty do
        {:halt, nonce}
      else
        {:cont, nil}
      end
    end)
  end

  defp count_zeros(<<0::1, rest::bitstring>>), do: 1 + count_zeros(rest)
  defp count_zeros(_), do: 0

  # First nonce whose SHA-256(prefix <> nonce) starts with a 1 bit, so it
  # can never meet any positive difficulty. Deterministic (no flakes).
  defp find_non_solution(prefix) do
    Enum.reduce_while(0..1_000_000, nil, fn i, _acc ->
      nonce = Integer.to_string(i)
      <<first::1, _::bitstring>> = :crypto.hash(:sha256, prefix <> nonce)
      if first == 1, do: {:halt, nonce}, else: {:cont, nil}
    end)
  end
end
