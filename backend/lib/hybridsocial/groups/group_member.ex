defmodule Hybridsocial.Groups.GroupMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @doc """
  The actions a partial ban can withhold.

  `:post` and `:comment` are separate because they're different harms: a
  member who derails threads can be stopped from replying while still able to
  start their own topics, and vice versa.
  """
  @restrictable_actions ~w(post comment react)
  def restrictable_actions, do: @restrictable_actions

  schema "group_members" do
    field :role, Ecto.Enum, values: [:member, :moderator, :admin, :owner], default: :member

    field :status, Ecto.Enum,
      values: [:pending, :approved, :rejected, :banned],
      default: :approved

    # Partial ban. Empty list = member in good standing. A full ban is
    # `status: :banned`; this is the granular tier below it.
    field :restrictions, {:array, :string}, default: []

    # When the current sanction lapses. nil = permanent.
    field :restricted_until, :utc_datetime_usec
    field :restricted_by, :binary_id
    field :restriction_reason, :string

    belongs_to :group, Hybridsocial.Groups.Group
    belongs_to :identity, Hybridsocial.Accounts.Identity

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:group_id, :identity_id, :role, :status])
    |> validate_required([:group_id, :identity_id])
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:identity_id)
    |> unique_constraint([:group_id, :identity_id])
  end

  @doc """
  Applies or clears a sanction. `restrictions` and the ban `status` are set
  here rather than in `changeset/2` so an ordinary membership update can't
  silently sanction someone.
  """
  def sanction_changeset(member, attrs) do
    member
    |> cast(attrs, [
      :status,
      :restrictions,
      :restricted_until,
      :restricted_by,
      :restriction_reason
    ])
    |> validate_subset(:restrictions, @restrictable_actions)
  end

  @doc """
  True when the row's sanction has lapsed.

  Read-time evaluation is deliberate. The sweeper (`GroupSanctionExpiryWorker`)
  is a plain self-ticking GenServer, so a late tick or a process that died
  must not translate into someone staying sanctioned past their time. The
  sweeper only tidies rows; this is what actually decides.
  """
  def sanction_expired?(%__MODULE__{restricted_until: nil}, _now), do: false

  def sanction_expired?(%__MODULE__{restricted_until: until}, now),
    do: DateTime.compare(until, now) != :gt

  @doc "The member's status once a lapsed timed ban is taken into account."
  def effective_status(%__MODULE__{status: :banned} = member, now) do
    if sanction_expired?(member, now), do: :approved, else: :banned
  end

  def effective_status(%__MODULE__{status: status}, _now), do: status

  @doc "The restrictions actually in force, once expiry is taken into account."
  def effective_restrictions(%__MODULE__{} = member, now) do
    if sanction_expired?(member, now), do: [], else: member.restrictions || []
  end
end
