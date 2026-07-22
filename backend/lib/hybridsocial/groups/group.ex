defmodule Hybridsocial.Groups.Group do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "groups" do
    field :name, :string
    field :description, :string
    field :visibility, Ecto.Enum, values: [:public, :private, :local_only], default: :public

    # Federation mode is chosen at create time and LOCKED. See
    # `update_changeset/2` — changing it later would either leak previously
    # private posts to existing remote followers (local_only -> public_federated)
    # or abandon remote followers mid-subscription (public_federated ->
    # local_only). Neither is safe.
    field :federation_mode, Ecto.Enum,
      values: [:local_only, :public_federated],
      default: :local_only

    field :join_policy, Ecto.Enum,
      values: [:open, :screening, :approval, :invite_only],
      default: :open

    field :avatar_url, :string
    field :header_url, :string
    field :member_count, :integer, default: 0
    field :post_count, :integer, default: 0
    field :deleted_at, :utc_datetime_usec

    # Legacy fields kept for backwards compat during migration
    field :ap_actor_url, :string
    field :public_key, :string
    field :private_key, Hybridsocial.Crypto.EncryptedBinary, context: "group.private_key"

    belongs_to :creator, Hybridsocial.Accounts.Identity, foreign_key: :created_by

    # Link to the identity system — group is now a federated actor via its identity
    belongs_to :identity, Hybridsocial.Accounts.Identity

    has_many :members, Hybridsocial.Groups.GroupMember
    has_one :screening_config, Hybridsocial.Groups.GroupScreeningConfig

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(group, attrs) do
    group
    |> cast(attrs, [
      :name,
      :description,
      :visibility,
      :federation_mode,
      :join_policy,
      :avatar_url,
      :header_url,
      :created_by,
      :identity_id
    ])
    |> validate_required([:name, :created_by])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 1200)
    |> validate_length(:avatar_url, max: 2048)
    |> validate_length(:header_url, max: 2048)
    |> foreign_key_constraint(:created_by)
    |> foreign_key_constraint(:identity_id)
    |> unique_constraint(:identity_id)
  end

  # federation_mode is deliberately NOT cast here — it's locked at creation.
  def update_changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :description, :visibility, :join_policy, :avatar_url, :header_url])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 1200)
    |> validate_length(:avatar_url, max: 2048)
    |> validate_length(:header_url, max: 2048)
  end

  def soft_delete_changeset(group) do
    group
    |> change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond))
  end

  # Reverse a soft delete. Deletion only stamps `deleted_at` (member rows and
  # posts are never touched), so clearing it brings the group back whole.
  def restore_changeset(group) do
    group
    |> change(deleted_at: nil)
  end
end
