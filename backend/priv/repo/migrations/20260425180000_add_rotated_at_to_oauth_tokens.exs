defmodule Hybridsocial.Repo.Migrations.AddRotatedAtToOauthTokens do
  use Ecto.Migration

  @moduledoc """
  Adds a soft-rotation timestamp on oauth_tokens so a refresh that
  has just been rotated can still be honored briefly. Closes the
  cross-tab race where two browser contexts both present the same
  refresh token simultaneously and the second one was being denied
  with `invalid_refresh_token`, dropping the user to /login during
  a transient backend restart or token-expiry boundary.

  Pure additive — existing rows behave the same way (rotated_at is
  NULL, treated as never-rotated).
  """

  def change do
    alter table(:oauth_tokens) do
      add :rotated_at, :utc_datetime_usec
    end
  end
end
