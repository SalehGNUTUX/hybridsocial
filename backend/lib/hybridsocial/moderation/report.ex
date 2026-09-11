defmodule Hybridsocial.Moderation.Report do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @categories ~w(spam harassment hate_speech illegal misinformation other)
  @statuses ~w(pending investigating resolved dismissed)
  @tiers ~w(group instance)

  # Categories that are never the group's business alone. A group can decide
  # what's off-topic; it cannot decide that illegal content or hate speech is
  # acceptable within its walls, and the instance carries that responsibility
  # whatever the reporter picked. Reports in these categories are forced to
  # the instance tier — see `Moderation.create_report/2`.
  @always_instance ~w(illegal hate_speech)

  schema "reports" do
    field :target_type, :string
    field :target_id, :binary_id
    field :category, :string
    field :description, :string
    field :status, :string, default: "pending"
    field :action_taken, :string
    field :federated, :boolean, default: false
    field :resolved_at, :utc_datetime_usec

    # "group" reports land in that group's own moderation queue; "instance"
    # goes to instance staff, which is the pre-existing behaviour and default.
    field :tier, :string, default: "instance"
    field :group_id, :binary_id

    field :escalated_at, :utc_datetime_usec
    field :escalated_by, :binary_id

    belongs_to :reporter, Hybridsocial.Accounts.Identity
    belongs_to :reported, Hybridsocial.Accounts.Identity
    belongs_to :assigned_moderator, Hybridsocial.Accounts.Identity, foreign_key: :assigned_to

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :reporter_id,
      :reported_id,
      :target_type,
      :target_id,
      :category,
      :description,
      :federated,
      :tier,
      :group_id
    ])
    |> validate_required([:reporter_id, :reported_id, :category])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:tier, @tiers)
    |> validate_length(:description, max: 2000)
    |> validate_length(:target_type, max: 50)
    |> require_group_for_group_tier()
    |> foreign_key_constraint(:reporter_id)
    |> foreign_key_constraint(:reported_id)
    |> foreign_key_constraint(:group_id)
  end

  # A group-tier report with no group has no queue to land in — it would be
  # invisible to everyone. Reject rather than silently re-tier it.
  defp require_group_for_group_tier(changeset) do
    if get_field(changeset, :tier) == "group" and is_nil(get_field(changeset, :group_id)) do
      add_error(changeset, :group_id, "is required for a group-tier report")
    else
      changeset
    end
  end

  @doc "Marks the report as escalated to the instance tier."
  def escalate_changeset(report, actor_id) do
    change(report,
      tier: "instance",
      escalated_at: DateTime.utc_now(),
      escalated_by: actor_id
    )
  end

  def assign_changeset(report, moderator_id) do
    report
    |> change(assigned_to: moderator_id, status: "investigating")
  end

  def resolve_changeset(report, action_taken) do
    report
    |> change(status: "resolved", action_taken: action_taken, resolved_at: DateTime.utc_now())
  end

  def dismiss_changeset(report) do
    report
    |> change(status: "dismissed", resolved_at: DateTime.utc_now())
  end

  def categories, do: @categories
  def statuses, do: @statuses
  def tiers, do: @tiers
  def always_instance_categories, do: @always_instance
end
