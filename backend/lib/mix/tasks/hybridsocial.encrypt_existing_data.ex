defmodule Mix.Tasks.Hybridsocial.EncryptExistingData do
  @shortdoc "Encrypt existing plaintext sensitive fields (private keys, 2FA, emails)"
  @moduledoc """
  One-time backfill for installs that predate at-rest field encryption.
  Re-saves each row so the encrypted columns (`identities.private_key`,
  `groups.private_key`, `users.otp_secret`, `users.email`) are written as
  ciphertext, and sets `users.email_hash` (the login blind index).

      mix hybridsocial.encrypt_existing_data

  Idempotent and safe to re-run (already-encrypted values are simply
  re-encrypted). A fresh instance doesn't need this — the importer and
  registration write ciphertext from the start.
  """
  use Mix.Task

  alias Ecto.Changeset
  alias Hybridsocial.{Crypto, Repo}
  alias Hybridsocial.Accounts.{Identity, User}
  alias Hybridsocial.Groups.Group

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    users = backfill_users()
    identities = backfill_keys(Identity)
    groups = backfill_keys(Group)

    Mix.shell().info("Encrypted: #{users} users, #{identities} identities, #{groups} groups")
  end

  defp backfill_users do
    Repo.all(User)
    |> Enum.reduce(0, fn u, acc ->
      # Values read back decrypted (or plaintext for legacy rows) via the
      # EncryptedBinary type; force_change makes the dump re-encrypt them.
      Changeset.change(u)
      |> force_if(:email, u.email)
      |> force_if(:email_hash, u.email && Crypto.blind_index(u.email, "user.email"))
      |> force_if(:otp_secret, u.otp_secret)
      |> Repo.update!()

      acc + 1
    end)
  end

  defp backfill_keys(schema) do
    Repo.all(schema)
    |> Enum.reduce(0, fn row, acc ->
      Changeset.change(row)
      |> force_if(:private_key, row.private_key)
      |> Repo.update!()

      acc + 1
    end)
  end

  defp force_if(changeset, _field, nil), do: changeset
  defp force_if(changeset, field, value), do: Changeset.force_change(changeset, field, value)
end
