defmodule Hybridsocial.CryptoTest do
  use ExUnit.Case, async: true

  alias Hybridsocial.Crypto

  describe "encrypt/2 + decrypt/2" do
    test "round-trips a value" do
      blob = Crypto.encrypt("-----BEGIN RSA PRIVATE KEY-----abc", "identity.private_key")
      assert Crypto.encrypted?(blob)
      assert String.starts_with?(blob, "HSE1:")
      assert Crypto.decrypt(blob, "identity.private_key") == "-----BEGIN RSA PRIVATE KEY-----abc"
    end

    test "ciphertext is randomized (fresh nonce per call)" do
      a = Crypto.encrypt("same", "ctx")
      b = Crypto.encrypt("same", "ctx")
      assert a != b
      assert Crypto.decrypt(a, "ctx") == "same"
      assert Crypto.decrypt(b, "ctx") == "same"
    end

    test "nil passes through" do
      assert Crypto.encrypt(nil, "ctx") == nil
      assert Crypto.decrypt(nil, "ctx") == nil
    end

    test "context is bound — a blob can't be decrypted under a different context" do
      blob = Crypto.encrypt("secret", "user.otp_secret")
      assert_raise Crypto.Error, fn -> Crypto.decrypt(blob, "identity.private_key") end
    end

    test "tampering is detected (GCM auth)" do
      blob = Crypto.encrypt("secret", "ctx")
      "HSE1:" <> b64 = blob
      raw = Base.decode64!(b64)
      # flip a byte in the ciphertext body
      <<head::binary-size(20), byte, rest::binary>> = raw
      tampered = "HSE1:" <> Base.encode64(<<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)
      assert_raise Crypto.Error, fn -> Crypto.decrypt(tampered, "ctx") end
    end

    test "legacy plaintext (no prefix) reads back unchanged" do
      assert Crypto.decrypt("-----BEGIN RSA PRIVATE KEY-----legacy", "ctx") ==
               "-----BEGIN RSA PRIVATE KEY-----legacy"

      refute Crypto.encrypted?("plain@email.com")
    end
  end

  describe "blind_index/2" do
    test "is deterministic and case/space-insensitive" do
      a = Crypto.blind_index("User@Example.com", "user.email")
      b = Crypto.blind_index("  user@example.com ", "user.email")
      assert a == b
    end

    test "differs by value and by context" do
      refute Crypto.blind_index("a@x.com", "user.email") ==
               Crypto.blind_index("b@x.com", "user.email")

      refute Crypto.blind_index("a@x.com", "user.email") == Crypto.blind_index("a@x.com", "other")
    end

    test "does not reveal the plaintext" do
      idx = Crypto.blind_index("secret@example.com", "user.email")
      refute String.contains?(idx, "secret")
      refute String.contains?(idx, "example")
    end
  end
end
