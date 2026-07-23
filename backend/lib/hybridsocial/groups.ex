defmodule Hybridsocial.Groups do
  @moduledoc """
  The Groups context. Manages groups, memberships, screening, applications, and invites.
  """
  import Ecto.Query

  alias Hybridsocial.Repo

  alias Hybridsocial.Groups.{
    Group,
    GroupMember,
    GroupScreeningConfig,
    GroupApplication,
    GroupInvite
  }

  alias Hybridsocial.Accounts
  alias Hybridsocial.Accounts.Identity

  @default_page_size 20

  # Permission ladder. The role enum already had `:moderator` baked
  # in, but every previous `require_role` call only accepted
  # `[:admin, :owner]`, so the moderator slot was a UX-only label
  # with zero teeth. Tier-aligning the call sites (vs. inlining lists
  # everywhere) keeps the policy in one obvious place — change the
  # tuple, change the rule.
  @moderate_roles [:moderator, :admin, :owner]
  @manage_roles [:admin, :owner]
  @destroy_roles [:owner]

  # ---------------------------------------------------------------------------
  # Group CRUD
  # ---------------------------------------------------------------------------

  def create_group(identity_id, attrs) do
    with :ok <- Accounts.check_subaccount_limit(identity_id, "group") do
      handle = attrs["handle"] || generate_group_handle(attrs["name"])

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:identity, fn _ ->
        %Identity{}
        |> Identity.create_changeset(%{
          "type" => "group",
          "handle" => handle,
          "display_name" => attrs["name"],
          "bio" => attrs["description"],
          "parent_identity_id" => identity_id
        })
      end)
      |> Ecto.Multi.insert(:group, fn %{identity: group_identity} ->
        %Group{}
        |> Group.create_changeset(
          attrs
          |> Map.put("created_by", identity_id)
          |> Map.put("identity_id", group_identity.id)
        )
      end)
      |> Ecto.Multi.insert(:owner_member, fn %{group: group} ->
        %GroupMember{}
        |> GroupMember.changeset(%{
          group_id: group.id,
          identity_id: identity_id,
          role: :owner,
          status: :approved
        })
      end)
      |> Ecto.Multi.update(:update_count, fn %{group: group} ->
        group
        |> Ecto.Changeset.change(member_count: 1)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{identity: group_identity, update_count: group_updated}} ->
          group = %{group_updated | identity: group_identity}
          Phoenix.PubSub.broadcast(Hybridsocial.PubSub, "groups", {:group_created, group})
          {:ok, group}

        {:error, :identity, changeset, _} ->
          {:error, changeset}

        {:error, :group, changeset, _} ->
          {:error, changeset}

        {:error, :owner_member, changeset, _} ->
          {:error, changeset}
      end
    end
  end

  defp generate_group_handle(nil),
    do: "group_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

  defp generate_group_handle(name) do
    handle =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_")
      |> String.slice(0, 20)

    if handle == "" do
      generate_group_handle(nil)
    else
      handle
    end
  end

  def update_group(group_id, identity_id, attrs) do
    with {:ok, group} <- get_existing_group(group_id),
         {:ok, _role} <- require_role(group_id, identity_id, @manage_roles) do
      case group |> Group.update_changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          Phoenix.PubSub.broadcast(Hybridsocial.PubSub, "groups", {:group_updated, updated})
          {:ok, updated}

        error ->
          error
      end
    end
  end

  @doc """
  Soft-deletes a group. `opts` may carry `:reason` and `:ip`, which are
  written to the moderation audit log alongside the actor's role — so a group
  vanishing (especially at the hands of instance staff, who can delete any
  group without being a member) leaves an accountable trail. Deletion only
  stamps `deleted_at`; member rows and posts are untouched, so `restore_group/3`
  can bring it back whole.
  """
  def delete_group(group_id, identity_id, opts \\ []) do
    with {:ok, group} <- get_existing_group(group_id),
         {:ok, role} <- require_role(group_id, identity_id, @destroy_roles) do
      Ecto.Multi.new()
      |> Ecto.Multi.update(:group, Group.soft_delete_changeset(group))
      |> Ecto.Multi.run(:soft_delete_identity, fn _repo, _ ->
        if group.identity_id do
          case Repo.get(Identity, group.identity_id) do
            nil -> {:ok, nil}
            identity -> identity |> Identity.soft_delete_changeset() |> Repo.update()
          end
        else
          {:ok, nil}
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{group: deleted_group}} ->
          log_group_action(identity_id, "group.delete", deleted_group, role, opts)
          maybe_open_takedown(deleted_group, identity_id, role, opts)

          Phoenix.PubSub.broadcast(
            Hybridsocial.PubSub,
            "groups",
            {:group_deleted, deleted_group.id}
          )

          {:ok, deleted_group}

        {:error, :group, changeset, _} ->
          {:error, changeset}

        {:error, _, reason, _} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Restores a soft-deleted group and its actor identity. Instance staff only:
  restoring reverses a moderation action, so a group owner must not be able to
  undo a staff takedown — the intended flow is the owner appeals, and staff
  restore after reviewing. Members and posts were never deleted, so the group
  comes back with all its non-removed content intact (any individual posts a
  moderator took down separately stay down). Audited like the deletion.
  """
  def restore_group(group_id, actor_id, opts \\ []) do
    if staff_member?(actor_id) do
      case get_deleted_group(group_id) do
        nil ->
          {:error, :not_found}

        group ->
          Ecto.Multi.new()
          |> Ecto.Multi.update(:group, Group.restore_changeset(group))
          |> Ecto.Multi.run(:restore_identity, fn _repo, _ ->
            if group.identity_id do
              case Repo.get(Identity, group.identity_id) do
                nil -> {:ok, nil}
                identity -> identity |> Identity.restore_changeset() |> Repo.update()
              end
            else
              {:ok, nil}
            end
          end)
          |> Repo.transaction()
          |> case do
            {:ok, %{group: restored_group}} ->
              log_group_action(actor_id, "group.restore", restored_group, :staff, opts)

              Phoenix.PubSub.broadcast(
                Hybridsocial.PubSub,
                "groups",
                {:group_restored, restored_group.id}
              )

              {:ok, restored_group}

            {:error, :group, changeset, _} ->
              {:error, changeset}

            {:error, _, reason, _} ->
              {:error, reason}
          end
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Lists soft-deleted groups (most recently deleted first) so staff can find one
  to restore. Instance staff only.
  """
  def list_deleted_groups(actor_id, opts \\ []) do
    if staff_member?(actor_id) do
      limit = Keyword.get(opts, :limit, @default_page_size)

      groups =
        Group
        |> where([g], not is_nil(g.deleted_at))
        |> order_by([g], desc: g.deleted_at)
        |> limit(^limit)
        |> Repo.all()

      {:ok, groups}
    else
      {:error, :forbidden}
    end
  end

  # Best-effort audit entry for a group create/delete/restore. The role tells a
  # reviewer whether a deletion was an owner tearing down their own group or
  # instance staff acting as a moderator; the reason (if given) explains it.
  defp log_group_action(actor_id, action, group, role, opts) do
    Hybridsocial.Moderation.log(
      actor_id,
      action,
      "group",
      group.id,
      %{
        "name" => group.name,
        "actor_role" => to_string(role),
        "reason" => Keyword.get(opts, :reason)
      },
      Keyword.get(opts, :ip)
    )
  end

  defp get_deleted_group(group_id) do
    Group
    |> where([g], not is_nil(g.deleted_at))
    |> Repo.get(group_id)
  end

  @doc """
  PERMANENTLY deletes a group and everything that hangs off it. Used only by the
  takedown auto-purge worker after the appeal window. Members, applications,
  invites and screening cascade via `on_delete: :delete_all`; the group's actor
  identity (and the media/notifications it owns) go with it. Irreversible.
  """
  def purge_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        {:ok, :already_gone}

      group ->
        Ecto.Multi.new()
        |> Ecto.Multi.delete(:group, group)
        |> Ecto.Multi.run(:identity, fn _repo, _ ->
          case group.identity_id && Repo.get(Identity, group.identity_id) do
            nil -> {:ok, nil}
            false -> {:ok, nil}
            identity -> Repo.delete(identity)
          end
        end)
        |> Repo.transaction()
        |> case do
          {:ok, _} -> {:ok, :purged}
          {:error, _step, reason, _} -> {:error, reason}
        end
    end
  end

  # A staff deletion is a moderation takedown: open a takedown record so the
  # owner is notified with the reason and given the appeal window. An owner
  # tearing down their own group is not a takedown — skip it. Also skip when no
  # reason was given (nothing to explain to the owner).
  defp maybe_open_takedown(group, moderator_id, :staff, opts) do
    reason = Keyword.get(opts, :reason)
    owner_id = owner_identity_id(group.id)

    if is_binary(reason) and reason != "" and owner_id do
      Hybridsocial.Moderation.create_takedown(%{
        target_type: "group",
        target_id: group.id,
        owner_id: owner_id,
        moderator_id: moderator_id,
        reason: reason,
        category: Keyword.get(opts, :category)
      })
    end

    :ok
  end

  defp maybe_open_takedown(_group, _moderator_id, _role, _opts), do: :ok

  defp owner_identity_id(group_id) do
    GroupMember
    |> where([m], m.group_id == ^group_id and m.role == :owner and m.status == :approved)
    |> select([m], m.identity_id)
    |> limit(1)
    |> Repo.one()
  end

  def get_group(id) do
    Group
    |> where([g], is_nil(g.deleted_at))
    |> Repo.get(id)
  end

  def get_group!(id) do
    Group
    |> where([g], is_nil(g.deleted_at))
    |> Repo.get!(id)
  end

  def list_groups(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)
    cursor = Keyword.get(opts, :cursor)
    visibility = Keyword.get(opts, :visibility)

    query =
      Group
      |> where([g], is_nil(g.deleted_at))
      |> order_by([g], desc: g.inserted_at)
      |> limit(^limit)

    query =
      if visibility do
        where(query, [g], g.visibility == ^visibility)
      else
        query
      end

    query =
      if cursor do
        where(query, [g], g.inserted_at < ^cursor)
      else
        query
      end

    Repo.all(query)
  end

  def search_groups(query_string) do
    pattern = "%#{query_string}%"

    Group
    |> where([g], is_nil(g.deleted_at))
    |> where([g], ilike(g.name, ^pattern) or ilike(g.description, ^pattern))
    |> order_by([g], desc: g.inserted_at)
    |> limit(@default_page_size)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Membership
  # ---------------------------------------------------------------------------

  def join_group(group_id, identity_id) do
    with {:ok, group} <- get_existing_group(group_id),
         nil <- get_member(group_id, identity_id),
         nil <- get_pending_application(group_id, identity_id) do
      case group.join_policy do
        :open ->
          insert_member(group_id, identity_id, :member, :approved)

        :screening ->
          case check_auto_approval(group_id, identity_id, %{}) do
            :approved ->
              insert_member(group_id, identity_id, :member, :approved)

            :pending ->
              apply_to_group(group_id, identity_id, %{})
          end

        :approval ->
          apply_to_group(group_id, identity_id, %{})

        :invite_only ->
          case get_pending_invite(group_id, identity_id) do
            nil ->
              {:error, :invite_required}

            invite ->
              invite
              |> GroupInvite.changeset(%{status: "accepted"})
              |> Repo.update()

              insert_member(group_id, identity_id, :member, :approved)
          end
      end
    else
      %GroupMember{} -> {:error, :already_member}
      %GroupApplication{} -> {:error, :already_applied}
      {:error, reason} -> {:error, reason}
    end
  end

  def leave_group(group_id, identity_id) do
    case get_member(group_id, identity_id) do
      nil ->
        {:error, :not_member}

      %GroupMember{role: :owner} = member ->
        # An owner walking out abandons the group: no one would be left
        # to manage settings, accept applications, or transfer power.
        # Require either promoting another member to owner first or
        # deleting the group outright. The "last owner" check is
        # strict — if there happen to be co-owners, any one of them
        # may leave.
        case count_owners(group_id) do
          n when n > 1 ->
            do_leave(member, group_id)

          _ ->
            {:error, :owner_must_transfer}
        end

      member ->
        do_leave(member, group_id)
    end
  end

  defp do_leave(%GroupMember{} = member, group_id) do
    Repo.delete(member)
    update_member_count(group_id, -1)
    {:ok, member}
  end

  defp count_owners(group_id) do
    GroupMember
    |> where([m], m.group_id == ^group_id and m.role == ^:owner and m.status == ^:approved)
    |> Repo.aggregate(:count)
  end

  def get_members(group_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)
    status = Keyword.get(opts, :status, :approved)

    GroupMember
    |> where([m], m.group_id == ^group_id and m.status == ^status)
    |> order_by([m], asc: m.inserted_at)
    |> limit(^limit)
    |> preload(:identity)
    |> Repo.all()
  end

  def update_member_role(group_id, admin_id, member_id, role) do
    with {:ok, actor_role} <- require_role(group_id, admin_id, @manage_roles),
         member when not is_nil(member) <- get_member_by_id(member_id, group_id),
         :ok <- authorize_role_change(actor_role, member.role, role) do
      member
      |> GroupMember.changeset(%{role: role})
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def ban_member(group_id, admin_id, member_id) do
    with {:ok, actor_role} <- require_role(group_id, admin_id, @moderate_roles),
         member when not is_nil(member) <- get_member_by_id(member_id, group_id),
         :ok <- authorize_ban(actor_role, member.role),
         :ok <- ensure_not_sole_owner(group_id, member) do
      # Only approved members are counted in member_count, so only decrement
      # when banning one that was actually counted (mirrors insert_member).
      was_approved = member.status == :approved

      case member |> GroupMember.changeset(%{status: :banned}) |> Repo.update() do
        {:ok, banned} ->
          if was_approved, do: update_member_count(group_id, -1)
          {:ok, banned}

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Banning the only owner would leave the group ownerless (no one could then
  # grant owner or delete it) — the same state `leave_group` guards against.
  defp ensure_not_sole_owner(group_id, %GroupMember{role: :owner}) do
    if count_owners(group_id) > 1, do: :ok, else: {:error, :owner_must_transfer}
  end

  defp ensure_not_sole_owner(_group_id, _member), do: :ok

  # Only an owner (or instance staff) may change an existing owner's role or
  # hand out the `:owner` role. Without this, an admin could demote the owner
  # or promote themselves/a puppet to owner and seize the group — the owner
  # role must stay with its creator, transferable only by an owner.
  defp authorize_role_change(actor_role, _target_role, _new_role)
       when actor_role in [:owner, :staff],
       do: :ok

  defp authorize_role_change(_actor_role, :owner, _new_role), do: {:error, :forbidden}

  defp authorize_role_change(_actor_role, _target_role, new_role) do
    if to_string(new_role) == "owner", do: {:error, :forbidden}, else: :ok
  end

  # An owner can only be banned by another owner (or instance staff), so a
  # moderator/admin can't evict the owner and take over the group.
  defp authorize_ban(actor_role, _target_role) when actor_role in [:owner, :staff], do: :ok
  defp authorize_ban(_actor_role, :owner), do: {:error, :forbidden}
  defp authorize_ban(_actor_role, _target_role), do: :ok

  def member?(group_id, identity_id) do
    GroupMember
    |> where(
      [m],
      m.group_id == ^group_id and m.identity_id == ^identity_id and m.status == :approved
    )
    |> Repo.exists?()
  end

  @doc "Returns the GroupMember row for the given pair, or nil."
  def get_membership(group_id, identity_id) do
    GroupMember
    |> where([m], m.group_id == ^group_id and m.identity_id == ^identity_id)
    |> Repo.one()
  end

  def member_role(group_id, identity_id) do
    GroupMember
    |> where(
      [m],
      m.group_id == ^group_id and m.identity_id == ^identity_id and m.status == :approved
    )
    |> select([m], m.role)
    |> Repo.one()
  end

  @doc """
  True when the identity may take moderator-tier actions in the group:
  pin/unpin posts, ban members, approve / reject join applications.
  Owners and admins are always considered moderators; instance staff
  ride the same path as `require_role/3` so site staff retain
  override authority.
  """
  def can_moderate?(group_id, identity_id) do
    case require_role(group_id, identity_id, @moderate_roles) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc "True when the identity may take admin-tier actions (settings, role grants)."
  def can_manage?(group_id, identity_id) do
    case require_role(group_id, identity_id, @manage_roles) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Screening
  # ---------------------------------------------------------------------------

  def get_screening_config(group_id) do
    Repo.get(GroupScreeningConfig, group_id)
  end

  def update_screening_config(group_id, admin_id, attrs) do
    with {:ok, _role} <- require_role(group_id, admin_id, @manage_roles) do
      case get_screening_config(group_id) do
        nil ->
          %GroupScreeningConfig{}
          |> GroupScreeningConfig.changeset(Map.put(attrs, "group_id", group_id))
          |> Repo.insert()

        config ->
          config
          |> GroupScreeningConfig.changeset(attrs)
          |> Repo.update()
      end
    end
  end

  def check_auto_approval(group_id, identity_id, _answers) do
    config = get_screening_config(group_id)

    cond do
      is_nil(config) ->
        :approved

      config.require_profile_image ->
        identity = Accounts.get_identity(identity_id)

        if identity && identity.avatar_url do
          check_account_age(config, identity)
        else
          :pending
        end

      config.min_account_age_days > 0 ->
        identity = Accounts.get_identity(identity_id)
        check_account_age(config, identity)

      true ->
        :approved
    end
  end

  # ---------------------------------------------------------------------------
  # Applications
  # ---------------------------------------------------------------------------

  def apply_to_group(group_id, identity_id, answers) do
    with {:ok, _group} <- get_existing_group(group_id),
         {:ok, application} <-
           %GroupApplication{}
           |> GroupApplication.changeset(%{
             group_id: group_id,
             identity_id: identity_id,
             answers: answers
           })
           |> Repo.insert() do
      # Notify every moderator/admin/owner so a pending request can't sit
      # unseen — the applicant themselves is skipped by create_notification's
      # self-notification guard.
      Hybridsocial.Notifications.notify_group_application(
        application,
        moderator_ids(group_id)
      )

      {:ok, application}
    end
  end

  def approve_application(application_id, admin_id) do
    with {:ok, application} <- get_application(application_id),
         {:ok, _role} <- require_role(application.group_id, admin_id, @moderate_roles) do
      Ecto.Multi.new()
      |> Ecto.Multi.update(:application, fn _ ->
        GroupApplication.review_changeset(application, %{
          status: :approved,
          reviewed_by: admin_id
        })
      end)
      |> Ecto.Multi.insert(:member, fn _ ->
        %GroupMember{}
        |> GroupMember.changeset(%{
          group_id: application.group_id,
          identity_id: application.identity_id,
          role: :member,
          status: :approved
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{application: application, member: _member}} ->
          update_member_count(application.group_id, 1)
          {:ok, application}

        {:error, :application, changeset, _} ->
          {:error, changeset}

        {:error, :member, changeset, _} ->
          {:error, changeset}
      end
    end
  end

  def reject_application(application_id, admin_id) do
    with {:ok, application} <- get_application(application_id),
         {:ok, _role} <- require_role(application.group_id, admin_id, @moderate_roles) do
      application
      |> GroupApplication.review_changeset(%{
        status: :rejected,
        reviewed_by: admin_id
      })
      |> Repo.update()
    end
  end

  def get_applications(group_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)
    status = Keyword.get(opts, :status, :pending)

    GroupApplication
    |> where([a], a.group_id == ^group_id and a.status == ^status)
    |> order_by([a], asc: a.created_at)
    |> limit(^limit)
    |> preload(:identity)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Invites
  # ---------------------------------------------------------------------------

  def invite_to_group(group_id, inviter_id, invited_id) do
    with {:ok, _group} <- get_existing_group(group_id),
         true <- member?(group_id, inviter_id) || {:error, :not_member},
         :ok <-
           Hybridsocial.Accounts.InvitePrefs.check(
             invited_id,
             inviter_id,
             :group
           ) do
      result =
        %GroupInvite{}
        |> GroupInvite.changeset(%{
          group_id: group_id,
          invited_by: inviter_id,
          invited_id: invited_id
        })
        |> Repo.insert()

      with {:ok, invite} <- result do
        Hybridsocial.Notifications.notify_group_invite(invite)
        {:ok, invite}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def accept_invite(invite_id, identity_id) do
    with {:ok, invite} <- get_invite(invite_id),
         true <- invite.invited_id == identity_id || {:error, :forbidden} do
      Ecto.Multi.new()
      |> Ecto.Multi.update(:invite, fn _ ->
        invite
        |> GroupInvite.changeset(%{status: "accepted"})
      end)
      |> Ecto.Multi.insert(:member, fn _ ->
        %GroupMember{}
        |> GroupMember.changeset(%{
          group_id: invite.group_id,
          identity_id: identity_id,
          role: :member,
          status: :approved
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{invite: invite, member: _member}} ->
          update_member_count(invite.group_id, 1)
          {:ok, invite}

        {:error, :invite, changeset, _} ->
          {:error, changeset}

        {:error, :member, changeset, _} ->
          {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def decline_invite(invite_id, identity_id) do
    with {:ok, invite} <- get_invite(invite_id),
         true <- invite.invited_id == identity_id || {:error, :forbidden} do
      invite
      |> GroupInvite.changeset(%{status: "declined"})
      |> Repo.update()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def get_invites(identity_id) do
    GroupInvite
    |> where([i], i.invited_id == ^identity_id and i.status == "pending")
    |> order_by([i], desc: i.inserted_at)
    |> preload([:group, :inviter])
    |> Repo.all()
  end

  @doc """
  Pending invites for a group, surfaced to the admins so they can see
  who's been invited and cancel anything that hasn't been accepted yet.
  Requires the viewer to be an admin/owner of the group.
  """
  def list_pending_invites(group_id, viewer_id) do
    with {:ok, _role} <- require_role(group_id, viewer_id, @manage_roles) do
      invites =
        GroupInvite
        |> where([i], i.group_id == ^group_id and i.status == "pending")
        |> order_by([i], desc: i.inserted_at)
        |> preload([:invited, :inviter])
        |> Repo.all()

      {:ok, invites}
    end
  end

  @doc """
  Cancel a still-pending invite. Either the original inviter or any
  admin/owner of the group may cancel — keeps "I sent that by mistake"
  recoverable without forcing the inviter to be online.
  """
  def cancel_invite(invite_id, viewer_id) do
    case Repo.get(GroupInvite, invite_id) do
      nil ->
        {:error, :not_found}

      %GroupInvite{status: status} when status != "pending" ->
        {:error, :not_pending}

      invite ->
        if invite.invited_by == viewer_id or can_manage?(invite.group_id, viewer_id) do
          Repo.delete(invite)
        else
          {:error, :forbidden}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_existing_group(group_id) do
    case get_group(group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, group}
    end
  end

  defp get_member(group_id, identity_id) do
    GroupMember
    |> where([m], m.group_id == ^group_id and m.identity_id == ^identity_id)
    |> Repo.one()
  end

  defp get_member_by_id(member_id, group_id) do
    GroupMember
    |> where([m], m.id == ^member_id and m.group_id == ^group_id)
    |> Repo.one()
  end

  defp insert_member(group_id, identity_id, role, status) do
    result =
      %GroupMember{}
      |> GroupMember.changeset(%{
        group_id: group_id,
        identity_id: identity_id,
        role: role,
        status: status
      })
      |> Repo.insert()

    case result do
      {:ok, member} ->
        if status == :approved, do: update_member_count(group_id, 1)
        {:ok, member}

      error ->
        error
    end
  end

  defp update_member_count(group_id, delta) do
    Group
    |> where([g], g.id == ^group_id)
    |> Repo.update_all(inc: [member_count: delta])
  end

  defp require_role(group_id, identity_id, allowed_roles) do
    case member_role(group_id, identity_id) do
      nil ->
        if staff_member?(identity_id), do: {:ok, :staff}, else: {:error, :forbidden}

      role ->
        cond do
          role in allowed_roles -> {:ok, role}
          staff_member?(identity_id) -> {:ok, :staff}
          true -> {:error, :forbidden}
        end
    end
  end

  # Instance admins/moderators (anyone with an active row in
  # identity_roles) can manage any group regardless of group-internal
  # role — used by the moderation icon panel on group profiles.
  defp staff_member?(nil), do: false
  defp staff_member?(identity_id), do: Hybridsocial.Auth.RBAC.staff?(identity_id)

  defp get_application(application_id) do
    case Repo.get(GroupApplication, application_id) do
      nil -> {:error, :not_found}
      application -> {:ok, application}
    end
  end

  defp get_pending_application(group_id, identity_id) do
    GroupApplication
    |> where(
      [a],
      a.group_id == ^group_id and a.identity_id == ^identity_id and a.status == :pending
    )
    |> Repo.one()
  end

  # Identity ids of everyone who can review applications for a group
  # (the @moderate_roles tier, approved members only) — the recipients
  # of a new-application notification.
  defp moderator_ids(group_id) do
    GroupMember
    |> where(
      [m],
      m.group_id == ^group_id and m.status == :approved and m.role in ^@moderate_roles
    )
    |> select([m], m.identity_id)
    |> Repo.all()
  end

  defp get_invite(invite_id) do
    case Repo.get(GroupInvite, invite_id) do
      nil -> {:error, :not_found}
      invite -> {:ok, invite}
    end
  end

  defp get_pending_invite(group_id, identity_id) do
    GroupInvite
    |> where(
      [i],
      i.group_id == ^group_id and i.invited_id == ^identity_id and i.status == "pending"
    )
    |> Repo.one()
  end

  defp check_account_age(config, identity) do
    if config.min_account_age_days > 0 && identity do
      account_age_days = DateTime.diff(DateTime.utc_now(), identity.inserted_at, :day)

      if account_age_days >= config.min_account_age_days do
        :approved
      else
        :pending
      end
    else
      :approved
    end
  end
end
