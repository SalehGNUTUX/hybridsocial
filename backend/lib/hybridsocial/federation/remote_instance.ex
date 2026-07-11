defmodule Hybridsocial.Federation.RemoteInstance do
  @moduledoc """
  Per-domain cache of remote-server software metadata (NodeInfo).
  We consult it at outbound DM time so we can choose the right
  activity type per peer:

    * Pleroma / Akkoma: emit `Create{ChatMessage}` (their native
      one-on-one chat primitive);
    * everyone else (Mastodon, Misskey, unknowns): DMs silently
      fall back to a direct-visibility post, which is how those
      servers actually model private messages.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "remote_instances" do
    field :domain, :string
    field :software, :string
    field :version, :string
    field :features, {:array, :string}, default: []
    field :chat_capable_override, :boolean
    field :fetched_at, :utc_datetime_usec
    field :last_error, :string

    # Delivery circuit breaker (see Federation.CircuitBreaker).
    field :consecutive_failures, :integer, default: 0
    field :unreachable_since, :utc_datetime_usec
    field :circuit_reopen_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :domain,
      :software,
      :version,
      :features,
      :chat_capable_override,
      :fetched_at,
      :last_error,
      :consecutive_failures,
      :unreachable_since,
      :circuit_reopen_at
    ])
    |> validate_required([:domain])
    |> unique_constraint(:domain)
  end
end
