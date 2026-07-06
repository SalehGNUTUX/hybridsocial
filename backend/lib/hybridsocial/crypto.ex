defmodule Hybridsocial.Crypto do
  @moduledoc """
  At-rest field encryption for sensitive columns — actor private keys, 2FA
  secrets, and emails.

  Design (mirrors `Hybridsocial.Messaging.Crypto`):

    - A single master key comes from a pluggable `KeyProvider`
      (`:hybridsocial, :crypto_key_provider`, default env-var backed), so the
      source can move from an env var to Vault/KMS with no schema change.
    - Per-field subkeys are derived from the master via HMAC-SHA256 with a
      field "context" (e.g. `"identity.private_key"`) as info — no data keys
      stored in the DB.
    - Values are AES-256-GCM encrypted; the context is bound as additional
      authenticated data, so ciphertext from one field can't be replayed
      into another. Output is a self-describing text string
      (`"HSE1:" <> base64`) so encrypted columns stay `text` and legacy
      plaintext rows pass through unchanged until backfilled.

  Threat model — identical to the DM crypto:

    - Defends against: stolen DB dumps, backup theft, a decommissioned disk.
    - Does NOT defend against: a compromised running server or malicious
      operator (the server holds the master key). Pair with full-disk
      encryption on the host, and move the key to Vault/KMS if you need
      rotation/audit.
  """

  @prefix "HSE1:"
  @key_size 32
  @nonce_size 12
  @tag_size 16

  defmodule Error do
    defexception [:message]
  end

  @doc """
  Encrypt `plaintext` for a field `context`. Returns a `"HSE1:"`-prefixed
  base64 string, or `nil` for `nil` input.
  """
  def encrypt(nil, _context), do: nil

  def encrypt(plaintext, context) when is_binary(plaintext) and is_binary(context) do
    key = subkey(context)
    nonce = :crypto.strong_rand_bytes(@nonce_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad(context), true)

    @prefix <> Base.encode64(nonce <> tag <> ciphertext)
  end

  @doc """
  Decrypt a value produced by `encrypt/2`. A value without the `"HSE1:"`
  prefix is treated as legacy plaintext and returned unchanged (so a column
  can be flipped to encrypted before its rows are backfilled). Raises if a
  prefixed value fails authentication.
  """
  def decrypt(nil, _context), do: nil

  def decrypt(@prefix <> b64, context) when is_binary(context) do
    with {:ok, raw} <- Base.decode64(b64),
         <<nonce::binary-size(@nonce_size), tag::binary-size(@tag_size), ciphertext::binary>> <-
           raw,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             subkey(context),
             nonce,
             ciphertext,
             aad(context),
             tag,
             false
           ) do
      plaintext
    else
      _ -> raise Error, message: "decryption failed for context #{context}"
    end
  end

  def decrypt(plaintext, _context) when is_binary(plaintext), do: plaintext

  @doc """
  Deterministic keyed index for a searchable/unique encrypted field (e.g.
  email). Normalizes (trim + downcase) then HMAC-SHA256s under a
  context-separated subkey. Same input → same output, so it supports
  equality lookups and unique constraints without exposing the plaintext.
  """
  def blind_index(nil, _context), do: nil

  def blind_index(value, context) when is_binary(value) and is_binary(context) do
    normalized = value |> String.trim() |> String.downcase()

    :crypto.mac(:hmac, :sha256, subkey("index:" <> context), normalized)
    |> Base.encode16(case: :lower)
  end

  @doc "True if `value` is already an encrypted blob (has the prefix)."
  def encrypted?(@prefix <> _), do: true
  def encrypted?(_), do: false

  # --- internals -------------------------------------------------------

  defp subkey(context) do
    prk = :crypto.mac(:hmac, :sha256, <<0>>, master_key())

    :crypto.mac(:hmac, :sha256, prk, "hs:field:v1:" <> context <> <<1>>)
    |> binary_part(0, @key_size)
  end

  defp aad(context), do: "hs:aad:v1:" <> context

  defp master_key do
    provider =
      Application.get_env(:hybridsocial, :crypto_key_provider, Hybridsocial.Crypto.EnvKeyProvider)

    case provider.master_key() do
      {:ok, key} when is_binary(key) and byte_size(key) >= 16 ->
        key

      {:ok, key} when is_binary(key) ->
        raise Error,
          message: "data encryption key too short (#{byte_size(key)} bytes; need >= 16)"

      {:error, reason} ->
        raise Error, message: "no data encryption key configured: #{inspect(reason)}"
    end
  end
end
