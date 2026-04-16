defmodule Hybridsocial.Accounts.RecoveryCode do
  @moduledoc """
  Account recovery codes. A user can generate one in settings; if they
  lose email access later, they can present handle + code at `/recover`
  to reset their password without going through email.

  Design:

    * 20 characters from a friendly alphabet (Crockford base32 minus
      ambiguous I/L/O/U), grouped as 4x5 for display: `A7KQM-X9PN3-W4TDH-Y2FBC`.
      Encoded bits: 20 * 5 = ~97 bits. Plenty of entropy.
    * Stored as `Bcrypt.hash_pwd_salt/1` on the identity. Verification
      is constant-time. Plaintext is never persisted.
    * Auto-rotated on successful use: a new code is generated and shown
      to the user on the recovery success page. The previous code stops
      working the moment a recovery completes.
  """

  @alphabet String.to_charlist("23456789ABCDEFGHJKMNPQRSTVWXYZ")
  @code_length 20
  @group_size 5

  @doc """
  Returns a freshly-generated code in display form. Entropy: ~97 bits.

      iex> code = RecoveryCode.generate()
      iex> String.length(code) == 23     # 20 + 3 dashes
      true
  """
  def generate do
    chars =
      for _ <- 1..@code_length do
        Enum.at(@alphabet, :rand.uniform(length(@alphabet)) - 1)
      end

    chars
    |> Enum.chunk_every(@group_size)
    |> Enum.map_join("-", &List.to_string/1)
  end

  @doc """
  Normalises user input for comparison. Users paste codes with spaces,
  lowercase, extra dashes — treat all those as equivalent.
  """
  def normalize(input) when is_binary(input) do
    input
    |> String.upcase()
    |> String.replace(~r/[\s-]/, "")
  end

  def normalize(_), do: ""

  @doc "Hash a code for storage. Call with the display-form code."
  def hash(code) when is_binary(code) do
    Bcrypt.hash_pwd_salt(normalize(code))
  end

  @doc """
  Constant-time verify. Returns true iff the user's input matches the
  stored hash, ignoring case/spaces/dashes. `nil` hash always fails
  without revealing that no code is set.
  """
  def verify(_input, nil) do
    # Burn the same amount of time as a real check to avoid user
    # enumeration via timing.
    Bcrypt.no_user_verify()
    false
  end

  def verify(input, hash) when is_binary(input) and is_binary(hash) do
    Bcrypt.verify_pass(normalize(input), hash)
  end

  def verify(_, _), do: false
end
