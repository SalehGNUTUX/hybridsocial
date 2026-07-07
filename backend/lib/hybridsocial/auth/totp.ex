defmodule Hybridsocial.Auth.TOTP do
  @moduledoc """
  Handles TOTP (Time-based One-Time Password) operations per RFC 6238.
  Uses NimbleTOTP for secret generation, URI building, and code validation.
  """

  @issuer "HybridSocial"
  # TOTP step, seconds (NimbleTOTP default).
  @period 30

  @doc """
  Generates a new random TOTP secret (20 bytes, base32-encoded internally by NimbleTOTP).
  Returns raw binary secret.
  """
  def generate_secret do
    NimbleTOTP.secret()
  end

  @doc """
  Generates an otpauth:// URI suitable for QR code scanning.
  """
  def generate_uri(secret, email) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{email}", secret, issuer: @issuer)
  end

  @doc """
  Validates a TOTP code against the given secret.
  Accepts string codes (6-digit) and converts them for verification.

  Accepts the adjacent windows (±1 period) as well as the current one, so a
  code submitted near a 30s boundary, or with minor client/server clock
  skew or submission latency, still validates. This is standard TOTP drift
  tolerance (RFC 6238 §5.2) and also removes a boundary-timing flake in the
  2FA/recovery tests.
  """
  def valid_code?(secret, code) when is_binary(code) do
    now = System.os_time(:second)

    Enum.any?([-@period, 0, @period], fn offset ->
      NimbleTOTP.valid?(secret, code, time: now + offset)
    end)
  end

  def valid_code?(_secret, _code), do: false

  @doc """
  Generates a list of recovery codes.
  Each code is an 8-character alphanumeric string.
  """
  def generate_recovery_codes(count \\ 8) do
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    alphabet_size = length(alphabet)

    Enum.map(1..count, fn _ ->
      1..8
      |> Enum.map(fn _ -> Enum.at(alphabet, :rand.uniform(alphabet_size) - 1) end)
      |> List.to_string()
    end)
  end
end
