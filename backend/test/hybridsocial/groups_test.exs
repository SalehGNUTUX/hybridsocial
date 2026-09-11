defmodule Hybridsocial.GroupsTest do
  use Hybridsocial.DataCase, async: true

  alias Hybridsocial.Groups
  alias Hybridsocial.Accounts
  alias Hybridsocial.Auth.RBAC
  alias Hybridsocial.Moderation.AuditLog
  alias Hybridsocial.Moderation.Takedown
  alias Hybridsocial.Notifications.Notification

  defp create_identity(handle, email) do
    {:ok, identity} =
      Accounts.register_user(%{
        "handle" => handle,
        "display_name" => handle,
        "email" => email,
        "password" => "password1234567890",
        "password_confirmation" => "password1234567890"
      })

    identity
  end

  # Grant an instance-level role so RBAC.staff?/1 is true — the "instance
  # moderator" the group role ladder defers to.
  defp make_staff(identity) do
    {:ok, _} = RBAC.assign_role(identity.id, "moderator", identity.id)
    identity
  end

  defp membership_id(group_id, identity_id) do
    Hybridsocial.Groups.GroupMember
    |> where([m], m.group_id == ^group_id and m.identity_id == ^identity_id)
    |> Repo.one()
    |> Map.get(:id)
  end

  defp last_audit(action) do
    AuditLog
    |> where([a], a.action == ^action)
    |> order_by([a], desc: a.created_at)
    |> limit(1)
    |> Repo.one()
  end

  setup do
    alice = create_identity("alice", "alice@example.com")
    bob = create_identity("bob", "bob@example.com")
    carol = create_identity("carol", "carol@example.com")
    %{alice: alice, bob: bob, carol: carol}
  end

  # ---------------------------------------------------------------------------
  # Group CRUD
  # ---------------------------------------------------------------------------

  describe "create_group/2" do
    test "creates a group and adds creator as owner", %{alice: alice} do
      assert {:ok, group} =
               Groups.create_group(alice.id, %{
                 "name" => "Test Group",
                 "description" => "A test group"
               })

      assert group.name == "Test Group"
      assert group.description == "A test group"
      assert group.member_count == 1
      assert group.created_by == alice.id

      # Creator should be owner
      assert Groups.member?(group.id, alice.id)
      assert Groups.member_role(group.id, alice.id) == :owner
    end

    test "returns error for missing name", %{alice: alice} do
      assert {:error, changeset} = Groups.create_group(alice.id, %{})
      assert %{name: _} = errors_on(changeset)
    end

    test "defaults federation_mode to :local_only", %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Safe by default"})
      assert group.federation_mode == :local_only
    end

    test "accepts federation_mode at creation", %{alice: alice} do
      {:ok, group} =
        Groups.create_group(alice.id, %{
          "name" => "Public federated",
          "federation_mode" => "public_federated"
        })

      assert group.federation_mode == :public_federated
    end

    test "rejects an unknown federation_mode", %{alice: alice} do
      assert {:error, changeset} =
               Groups.create_group(alice.id, %{
                 "name" => "Bad mode",
                 "federation_mode" => "hybrid-cosmic"
               })

      assert %{federation_mode: _} = errors_on(changeset)
    end
  end

  describe "update_group/3" do
    test "allows admin/owner to update", %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Original"})

      assert {:ok, updated} =
               Groups.update_group(group.id, alice.id, %{"name" => "Updated"})

      assert updated.name == "Updated"
    end

    test "rejects update from non-admin", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, _} = Groups.join_group(group.id, bob.id)

      assert {:error, :forbidden} =
               Groups.update_group(group.id, bob.id, %{"name" => "Hacked"})
    end

    test "returns not_found for missing group", %{alice: alice} do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Groups.update_group(fake_id, alice.id, %{"name" => "X"})
    end

    test "silently ignores federation_mode changes (it's locked at create)", %{alice: alice} do
      {:ok, group} =
        Groups.create_group(alice.id, %{
          "name" => "Locked",
          "federation_mode" => "local_only"
        })

      assert {:ok, updated} =
               Groups.update_group(group.id, alice.id, %{
                 "name" => "Still locked",
                 "federation_mode" => "public_federated"
               })

      assert updated.name == "Still locked"
      assert updated.federation_mode == :local_only
    end
  end

  describe "delete_group/2" do
    test "owner can soft delete", %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Doomed"})
      assert {:ok, deleted} = Groups.delete_group(group.id, alice.id)
      assert deleted.deleted_at != nil
      assert Groups.get_group(group.id) == nil
    end

    test "non-owner cannot delete", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Safe"})
      {:ok, _} = Groups.join_group(group.id, bob.id)
      assert {:error, :forbidden} = Groups.delete_group(group.id, bob.id)
    end

    test "a group admin — not the owner — cannot delete", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Safe"})
      {:ok, _} = Groups.join_group(group.id, bob.id)

      {:ok, _} =
        Groups.update_member_role(group.id, alice.id, membership_id(group.id, bob.id), "admin")

      # @destroy_roles is [:owner] — an admin manages the group but must not be
      # able to delete it (only the owner, plus instance-staff takedown).
      assert {:error, :forbidden} = Groups.delete_group(group.id, bob.id)
    end

    test "instance staff can delete any group without being a member", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Under review"})
      make_staff(bob)
      refute Groups.member_role(group.id, bob.id)

      assert {:ok, _deleted} = Groups.delete_group(group.id, bob.id, reason: "policy violation")
      assert Groups.get_group(group.id) == nil
    end

    test "writes an audit entry recording who deleted, their role, and why", %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Doomed"})
      {:ok, _} = Groups.delete_group(group.id, alice.id, reason: "spam")

      entry = last_audit("group.delete")
      assert entry.actor_id == alice.id
      assert entry.target_type == "group"
      assert entry.target_id == group.id
      assert entry.details["actor_role"] == "owner"
      assert entry.details["reason"] == "spam"
    end

    test "a staff deletion with a reason opens a takedown and notifies the owner",
         %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Reported"})
      make_staff(bob)

      {:ok, _} = Groups.delete_group(group.id, bob.id, reason: "hate speech")

      takedown = Repo.get_by(Takedown, target_type: "group", target_id: group.id)
      assert takedown
      assert takedown.owner_id == alice.id
      assert takedown.moderator_id == bob.id
      assert takedown.status == "active"
      assert takedown.reason == "hate speech"
      # The appeal window is in the future (default 60 days).
      assert DateTime.compare(takedown.purge_after, DateTime.utc_now()) == :gt

      # The owner got an in-app takedown notification (actor = the moderator).
      notif =
        Repo.get_by(Notification, recipient_id: alice.id, type: "moderation_takedown")

      assert notif
      assert notif.actor_id == bob.id
    end

    test "an owner tearing down their own group does not open a takedown",
         %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Mine"})
      {:ok, _} = Groups.delete_group(group.id, alice.id, reason: "cleaning up")

      refute Repo.get_by(Takedown, target_type: "group", target_id: group.id)
    end
  end

  describe "restore_group/3" do
    test "staff can restore a soft-deleted group with members intact",
         %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Wrongly removed"})
      {:ok, _} = Groups.join_group(group.id, bob.id)
      staff = create_identity("modstaff", "modstaff@example.com")
      make_staff(staff)

      {:ok, _} = Groups.delete_group(group.id, staff.id, reason: "misunderstanding")
      assert Groups.get_group(group.id) == nil

      assert {:ok, restored} = Groups.restore_group(group.id, staff.id)
      assert is_nil(restored.deleted_at)
      # Back and whole: still fetchable, and memberships/roles survived.
      assert Groups.get_group(group.id) != nil
      assert Groups.member_role(group.id, alice.id) == :owner
    end

    test "a non-staff member cannot restore (can't undo a staff takedown)",
         %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Removed"})
      staff = create_identity("mod2", "mod2@example.com")
      make_staff(staff)
      {:ok, _} = Groups.delete_group(group.id, staff.id)

      # Even the owner cannot self-restore a moderation takedown.
      assert {:error, :forbidden} = Groups.restore_group(group.id, alice.id)
    end

    test "restore writes its own audit entry", %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Back soon"})
      staff = create_identity("mod3", "mod3@example.com")
      make_staff(staff)
      {:ok, _} = Groups.delete_group(group.id, staff.id)
      {:ok, _} = Groups.restore_group(group.id, staff.id)

      entry = last_audit("group.restore")
      assert entry.actor_id == staff.id
      assert entry.target_id == group.id
    end
  end

  describe "list_deleted_groups/2" do
    test "staff see deleted groups; non-staff are forbidden", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Gone"})
      staff = create_identity("mod4", "mod4@example.com")
      make_staff(staff)
      {:ok, _} = Groups.delete_group(group.id, staff.id)

      assert {:ok, groups} = Groups.list_deleted_groups(staff.id)
      assert Enum.any?(groups, &(&1.id == group.id))
      assert {:error, :forbidden} = Groups.list_deleted_groups(bob.id)
    end
  end

  describe "list_groups/1" do
    test "lists non-deleted groups", %{alice: alice} do
      {:ok, _g1} = Groups.create_group(alice.id, %{"name" => "Group 1"})
      {:ok, g2} = Groups.create_group(alice.id, %{"name" => "Group 2"})
      Groups.delete_group(g2.id, alice.id)

      groups = Groups.list_groups()
      assert length(groups) == 1
      assert hd(groups).name == "Group 1"
    end

    test "filters by visibility", %{alice: alice} do
      {:ok, _} = Groups.create_group(alice.id, %{"name" => "Public", "visibility" => "public"})
      {:ok, _} = Groups.create_group(alice.id, %{"name" => "Private", "visibility" => "private"})

      public = Groups.list_groups(visibility: :public)
      assert length(public) == 1
      assert hd(public).name == "Public"
    end
  end

  describe "list_member_groups/2" do
    test "returns only groups the identity has actually joined", %{alice: alice, bob: bob} do
      {:ok, joined} = Groups.create_group(alice.id, %{"name" => "Joined"})
      {:ok, _} = Groups.join_group(joined.id, bob.id)
      {:ok, other} = Groups.create_group(alice.id, %{"name" => "Not joined"})

      bob_ids = Groups.list_member_groups(bob.id) |> Enum.map(& &1.id)
      assert joined.id in bob_ids
      refute other.id in bob_ids

      # The owner is an approved member of both groups they created.
      alice_ids = Groups.list_member_groups(alice.id) |> Enum.map(& &1.id)
      assert joined.id in alice_ids
      assert other.id in alice_ids
    end

    test "excludes pending (not-yet-approved) memberships", %{alice: alice, bob: bob} do
      {:ok, group} =
        Groups.create_group(alice.id, %{"name" => "Approval", "join_policy" => "approval"})

      # An approval-gated join leaves bob pending, not approved.
      Groups.join_group(group.id, bob.id)

      refute group.id in (Groups.list_member_groups(bob.id) |> Enum.map(& &1.id))
    end
  end

  describe "search_groups/1" do
    test "searches by name and description", %{alice: alice} do
      {:ok, _} =
        Groups.create_group(alice.id, %{"name" => "Elixir Devs", "description" => "Coding"})

      {:ok, _} =
        Groups.create_group(alice.id, %{"name" => "Cooking", "description" => "Elixir recipes"})

      {:ok, _} =
        Groups.create_group(alice.id, %{"name" => "Sports", "description" => "Athletic stuff"})

      results = Groups.search_groups("elixir")
      assert length(results) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Membership
  # ---------------------------------------------------------------------------

  describe "join_group/2" do
    test "open group: immediate approval", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Open", "join_policy" => "open"})
      assert {:ok, member} = Groups.join_group(group.id, bob.id)
      assert member.status == :approved
      assert Groups.member?(group.id, bob.id)
    end

    test "approval group: creates a pending application visible to admins",
         %{alice: alice, bob: bob} do
      {:ok, group} =
        Groups.create_group(alice.id, %{"name" => "Approval", "join_policy" => "approval"})

      # A request to join an approval group produces an application (not a
      # pending membership), so it surfaces on the admin applications list —
      # the exact wiring that was previously broken.
      assert {:ok, %Hybridsocial.Groups.GroupApplication{} = application} =
               Groups.join_group(group.id, bob.id)

      assert application.status == :pending
      refute Groups.member?(group.id, bob.id)

      assert [listed] = Groups.get_applications(group.id)
      assert listed.identity_id == bob.id
    end

    test "approval group: re-requesting returns :already_applied",
         %{alice: alice, bob: bob} do
      {:ok, group} =
        Groups.create_group(alice.id, %{"name" => "Approval", "join_policy" => "approval"})

      assert {:ok, _application} = Groups.join_group(group.id, bob.id)
      assert {:error, :already_applied} = Groups.join_group(group.id, bob.id)
      assert length(Groups.get_applications(group.id)) == 1
    end

    test "invite_only group: requires invite", %{alice: alice, bob: bob} do
      {:ok, group} =
        Groups.create_group(alice.id, %{"name" => "Invite Only", "join_policy" => "invite_only"})

      assert {:error, :invite_required} = Groups.join_group(group.id, bob.id)
    end

    test "invite_only group: succeeds with invite", %{alice: alice, bob: bob} do
      {:ok, group} =
        Groups.create_group(alice.id, %{"name" => "Invite Only", "join_policy" => "invite_only"})

      {:ok, _invite} = Groups.invite_to_group(group.id, alice.id, bob.id)
      assert {:ok, member} = Groups.join_group(group.id, bob.id)
      assert member.status == :approved
    end

    test "returns error for already member", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, _} = Groups.join_group(group.id, bob.id)
      assert {:error, :already_member} = Groups.join_group(group.id, bob.id)
    end

    test "returns error for non-existent group", %{bob: bob} do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Groups.join_group(fake_id, bob.id)
    end
  end

  describe "leave_group/2" do
    test "removes membership", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, _} = Groups.join_group(group.id, bob.id)
      assert {:ok, _} = Groups.leave_group(group.id, bob.id)
      refute Groups.member?(group.id, bob.id)
    end

    test "returns error if not member", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      assert {:error, :not_member} = Groups.leave_group(group.id, bob.id)
    end
  end

  describe "get_members/2" do
    test "returns approved members", %{alice: alice, bob: bob, carol: carol} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, _} = Groups.join_group(group.id, bob.id)
      {:ok, _} = Groups.join_group(group.id, carol.id)

      members = Groups.get_members(group.id)
      assert length(members) == 3
    end
  end

  describe "update_member_role/4" do
    test "admin can change roles", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, member} = Groups.join_group(group.id, bob.id)

      assert {:ok, updated} = Groups.update_member_role(group.id, alice.id, member.id, :moderator)
      assert updated.role == :moderator
    end

    test "non-admin cannot change roles", %{alice: alice, bob: bob, carol: carol} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, _} = Groups.join_group(group.id, bob.id)
      {:ok, member} = Groups.join_group(group.id, carol.id)

      assert {:error, :forbidden} = Groups.update_member_role(group.id, bob.id, member.id, :admin)
    end

    test "an admin cannot promote a member to owner", %{alice: alice, bob: bob, carol: carol} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, bob_m} = Groups.join_group(group.id, bob.id)
      {:ok, carol_m} = Groups.join_group(group.id, carol.id)
      {:ok, _} = Groups.update_member_role(group.id, alice.id, bob_m.id, :admin)

      assert {:error, :forbidden} =
               Groups.update_member_role(group.id, bob.id, carol_m.id, :owner)
    end

    test "an admin cannot demote the owner", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, bob_m} = Groups.join_group(group.id, bob.id)
      {:ok, _} = Groups.update_member_role(group.id, alice.id, bob_m.id, :admin)
      owner = Enum.find(Groups.get_members(group.id), &(&1.identity_id == alice.id))

      assert {:error, :forbidden} =
               Groups.update_member_role(group.id, bob.id, owner.id, :member)

      assert Groups.member_role(group.id, alice.id) == :owner
    end
  end

  describe "ban_member/3" do
    test "banning an approved member decrements member_count", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, member} = Groups.join_group(group.id, bob.id)
      assert Groups.get_group(group.id).member_count == 2

      assert {:ok, banned} = Groups.ban_member(group.id, alice.id, member.id)
      assert banned.status == :banned
      assert Groups.get_group(group.id).member_count == 1
    end

    test "the sole owner cannot be banned (would orphan the group)", %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      owner = Enum.find(Groups.get_members(group.id), &(&1.identity_id == alice.id))

      assert {:error, :owner_must_transfer} = Groups.ban_member(group.id, alice.id, owner.id)
      assert Groups.member_role(group.id, alice.id) == :owner
    end

    test "admin can ban member", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, member} = Groups.join_group(group.id, bob.id)

      assert {:ok, banned} = Groups.ban_member(group.id, alice.id, member.id)
      assert banned.status == :banned
    end

    test "a moderator cannot ban the owner", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, bob_m} = Groups.join_group(group.id, bob.id)
      {:ok, _} = Groups.update_member_role(group.id, alice.id, bob_m.id, :moderator)
      owner = Enum.find(Groups.get_members(group.id), &(&1.identity_id == alice.id))

      assert {:error, :forbidden} = Groups.ban_member(group.id, bob.id, owner.id)
      assert Groups.member_role(group.id, alice.id) == :owner
    end
  end

  # ---------------------------------------------------------------------------
  # Screening
  # ---------------------------------------------------------------------------

  describe "screening config" do
    test "get returns nil when not configured", %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      assert Groups.get_screening_config(group.id) == nil
    end

    test "update creates config", %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})

      assert {:ok, config} =
               Groups.update_screening_config(group.id, alice.id, %{
                 "require_profile_image" => true,
                 "min_account_age_days" => 7
               })

      assert config.require_profile_image == true
      assert config.min_account_age_days == 7
    end

    test "update existing config", %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})

      {:ok, _} =
        Groups.update_screening_config(group.id, alice.id, %{"min_account_age_days" => 7})

      assert {:ok, config} =
               Groups.update_screening_config(group.id, alice.id, %{"min_account_age_days" => 14})

      assert config.min_account_age_days == 14
    end

    test "persists and reloads free-text questions", %{alice: alice} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})

      questions = [%{"text" => "How did you hear about us?"}, %{"text" => "Why join?"}]

      assert {:ok, _} =
               Groups.update_screening_config(group.id, alice.id, %{"questions" => questions})

      # Reload from the DB (not the changeset result) so we exercise the jsonb
      # array-of-maps load path the settings page reads back on prefill.
      reloaded = Groups.get_screening_config(group.id)
      assert reloaded.questions == questions
    end

    test "non-admin cannot update", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, _} = Groups.join_group(group.id, bob.id)

      assert {:error, :forbidden} =
               Groups.update_screening_config(group.id, bob.id, %{"min_account_age_days" => 7})
    end
  end

  # ---------------------------------------------------------------------------
  # Applications
  # ---------------------------------------------------------------------------

  describe "applications" do
    test "submit application", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})

      assert {:ok, application} =
               Groups.apply_to_group(group.id, bob.id, %{"reason" => "I want to join"})

      assert application.status == :pending
      assert application.group_id == group.id
      assert application.identity_id == bob.id
    end

    test "approve application adds member", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, application} = Groups.apply_to_group(group.id, bob.id, %{})

      assert {:ok, approved} = Groups.approve_application(application.id, alice.id)
      assert approved.status == :approved
      assert Groups.member?(group.id, bob.id)
    end

    test "reject application", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, application} = Groups.apply_to_group(group.id, bob.id, %{})

      assert {:ok, rejected} = Groups.reject_application(application.id, alice.id)
      assert rejected.status == :rejected
      refute Groups.member?(group.id, bob.id)
    end

    test "list pending applications", %{alice: alice, bob: bob, carol: carol} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, _} = Groups.apply_to_group(group.id, bob.id, %{})
      {:ok, _} = Groups.apply_to_group(group.id, carol.id, %{})

      applications = Groups.get_applications(group.id)
      assert length(applications) == 2
    end

    test "non-admin cannot approve", %{alice: alice, bob: bob, carol: carol} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, _} = Groups.join_group(group.id, bob.id)
      {:ok, application} = Groups.apply_to_group(group.id, carol.id, %{})

      assert {:error, :forbidden} = Groups.approve_application(application.id, bob.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Invites
  # ---------------------------------------------------------------------------

  describe "invites" do
    test "member can invite another user", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})

      assert {:ok, invite} = Groups.invite_to_group(group.id, alice.id, bob.id)
      assert invite.status == "pending"
      assert invite.group_id == group.id
      assert invite.invited_id == bob.id
    end

    test "non-member cannot invite", %{alice: alice, bob: bob, carol: carol} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      assert {:error, :not_member} = Groups.invite_to_group(group.id, bob.id, carol.id)
    end

    test "accept invite adds member", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, invite} = Groups.invite_to_group(group.id, alice.id, bob.id)

      assert {:ok, accepted} = Groups.accept_invite(invite.id, bob.id)
      assert accepted.status == "accepted"
      assert Groups.member?(group.id, bob.id)
    end

    test "decline invite", %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, invite} = Groups.invite_to_group(group.id, alice.id, bob.id)

      assert {:ok, declined} = Groups.decline_invite(invite.id, bob.id)
      assert declined.status == "declined"
      refute Groups.member?(group.id, bob.id)
    end

    test "cannot accept someone else's invite", %{alice: alice, bob: bob, carol: carol} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Group"})
      {:ok, invite} = Groups.invite_to_group(group.id, alice.id, bob.id)

      assert {:error, :forbidden} = Groups.accept_invite(invite.id, carol.id)
    end

    test "get pending invites for user", %{alice: alice, bob: bob} do
      {:ok, group1} = Groups.create_group(alice.id, %{"name" => "Group 1"})
      {:ok, group2} = Groups.create_group(alice.id, %{"name" => "Group 2"})
      {:ok, _} = Groups.invite_to_group(group1.id, alice.id, bob.id)
      {:ok, _} = Groups.invite_to_group(group2.id, alice.id, bob.id)

      invites = Groups.get_invites(bob.id)
      assert length(invites) == 2
    end
  end

  describe "update_member_role/4 — role management is governance, not moderation" do
    test "instance staff CANNOT promote themselves in a group they only joined",
         %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Community"})
      {:ok, _} = Groups.join_group(group.id, bob.id)
      make_staff(bob)

      bob_membership = membership_id(group.id, bob.id)

      assert {:error, :forbidden} =
               Groups.update_member_role(group.id, bob.id, bob_membership, "moderator")

      # Role is unchanged — the staff override does not reach role management.
      assert Repo.get(Hybridsocial.Groups.GroupMember, bob_membership).role == :member
    end

    test "instance staff who aren't members cannot change anyone's role",
         %{alice: alice, bob: bob, carol: carol} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Community"})
      {:ok, _} = Groups.join_group(group.id, bob.id)
      make_staff(carol)

      bob_membership = membership_id(group.id, bob.id)

      assert {:error, :forbidden} =
               Groups.update_member_role(group.id, carol.id, bob_membership, "admin")
    end

    test "a genuine group owner/admin can still change roles",
         %{alice: alice, bob: bob} do
      {:ok, group} = Groups.create_group(alice.id, %{"name" => "Community"})
      {:ok, _} = Groups.join_group(group.id, bob.id)

      bob_membership = membership_id(group.id, bob.id)

      assert {:ok, updated} =
               Groups.update_member_role(group.id, alice.id, bob_membership, "moderator")

      assert updated.role == :moderator
    end
  end

  # ---------------------------------------------------------------------------
  # Posting / reacting authorization
  #
  # `group_id` is a cast field on Post, so without an explicit guard any
  # authenticated identity could attribute a post to any group. These lock the
  # guard down at the context level, where every local creation path funnels.
  # ---------------------------------------------------------------------------

  describe "authorize_group_post/2" do
    setup %{alice: alice, bob: bob} do
      {:ok, group} =
        Groups.create_group(alice.id, %{
          "name" => "Private Club",
          "handle" => "privclub",
          "visibility" => "private",
          "join_policy" => "open"
        })

      {:ok, _} = Groups.join_group(group.id, bob.id)
      %{group: group}
    end

    test "an approved member may post", %{group: group, bob: bob} do
      assert :ok = Groups.authorize_group_post(%{"group_id" => group.id}, bob.id)
    end

    test "the owner may post", %{group: group, alice: alice} do
      assert :ok = Groups.authorize_group_post(%{"group_id" => group.id}, alice.id)
    end

    test "a non-member may NOT post into the group", %{group: group, carol: carol} do
      assert {:error, :group_forbidden} =
               Groups.authorize_group_post(%{"group_id" => group.id}, carol.id)
    end

    test "a banned member may NOT post", %{group: group, alice: alice, bob: bob} do
      {:ok, _} = Groups.ban_member(group.id, alice.id, membership_id(group.id, bob.id))

      assert {:error, :group_forbidden} =
               Groups.authorize_group_post(%{"group_id" => group.id}, bob.id)
    end

    test "a pending applicant may NOT post", %{alice: alice, carol: carol} do
      {:ok, gated} =
        Groups.create_group(alice.id, %{
          "name" => "Gated",
          "handle" => "gatedclub",
          "visibility" => "private",
          "join_policy" => "approval"
        })

      {:ok, _} = Groups.join_group(gated.id, carol.id)

      assert {:error, :group_forbidden} =
               Groups.authorize_group_post(%{"group_id" => gated.id}, carol.id)
    end

    test "nobody may post into a soft-deleted group", %{group: group, alice: alice, bob: bob} do
      {:ok, _} = Groups.delete_group(group.id, alice.id)

      # Membership rows survive the soft delete; they must not stay writable.
      assert {:error, :group_forbidden} =
               Groups.authorize_group_post(%{"group_id" => group.id}, bob.id)

      assert {:error, :group_forbidden} =
               Groups.authorize_group_post(%{"group_id" => group.id}, alice.id)
    end

    test "a status with no group_id is unaffected", %{carol: carol} do
      assert :ok = Groups.authorize_group_post(%{"content" => "hi"}, carol.id)
      assert :ok = Groups.authorize_group_post(%{"group_id" => nil}, carol.id)
      assert :ok = Groups.authorize_group_post(%{"group_id" => ""}, carol.id)
    end

    test "atom-keyed attrs are checked too, not silently skipped", %{group: group, carol: carol} do
      assert {:error, :group_forbidden} =
               Groups.authorize_group_post(%{group_id: group.id}, carol.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Partial and timed bans (#86)
  # ---------------------------------------------------------------------------

  describe "restrict_member/4 — partial bans" do
    setup %{alice: alice, bob: bob} do
      {:ok, group} =
        Groups.create_group(alice.id, %{
          "name" => "Sanctions",
          "handle" => "sanctions",
          "visibility" => "private",
          "join_policy" => "open"
        })

      {:ok, _} = Groups.join_group(group.id, bob.id)
      %{group: group, bob_mid: membership_id(group.id, bob.id)}
    end

    test "withholding :post stops posting but not reacting", %{
      group: g,
      alice: alice,
      bob: bob,
      bob_mid: mid
    } do
      {:ok, _} = Groups.restrict_member(g.id, alice.id, mid, restrictions: ["post"])

      refute Groups.can_do_in_group?(g.id, bob.id, :post)
      assert Groups.can_do_in_group?(g.id, bob.id, :react)
      assert Groups.can_do_in_group?(g.id, bob.id, :comment)
    end

    test "withholding :react stops only reacting", %{
      group: g,
      alice: alice,
      bob: bob,
      bob_mid: mid
    } do
      {:ok, _} = Groups.restrict_member(g.id, alice.id, mid, restrictions: ["react"])

      assert Groups.can_do_in_group?(g.id, bob.id, :post)
      refute Groups.can_do_in_group?(g.id, bob.id, :react)
    end

    test "a restricted member is still an approved member", %{
      group: g,
      alice: alice,
      bob: bob,
      bob_mid: mid
    } do
      {:ok, member} = Groups.restrict_member(g.id, alice.id, mid, restrictions: ["post"])

      assert member.status == :approved
      # Still reads the group — a partial ban is not a removal.
      assert Groups.member?(g.id, bob.id)
    end

    test "unrestrict clears it", %{group: g, alice: alice, bob: bob, bob_mid: mid} do
      {:ok, _} = Groups.restrict_member(g.id, alice.id, mid, restrictions: ["post", "react"])
      refute Groups.can_do_in_group?(g.id, bob.id, :post)

      {:ok, cleared} = Groups.unrestrict_member(g.id, alice.id, mid)

      assert cleared.restrictions == []
      assert Groups.can_do_in_group?(g.id, bob.id, :post)
    end

    test "an unknown action is rejected rather than silently stored", %{
      group: g,
      alice: alice,
      bob_mid: mid
    } do
      assert {:error, {:invalid_restrictions, ["reactions"]}} =
               Groups.restrict_member(g.id, alice.id, mid, restrictions: ["reactions"])
    end

    test "a plain member cannot sanction anyone", %{group: g, bob: bob, carol: carol} do
      {:ok, _} = Groups.join_group(g.id, carol.id)
      carol_mid = membership_id(g.id, carol.id)

      assert {:error, :forbidden} =
               Groups.restrict_member(g.id, bob.id, carol_mid, restrictions: ["post"])
    end

    test "a moderator can sanction — this is moderation, not governance", %{
      group: g,
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {:ok, _} =
        Groups.update_member_role(g.id, alice.id, membership_id(g.id, bob.id), "moderator")

      {:ok, _} = Groups.join_group(g.id, carol.id)

      assert {:ok, _} =
               Groups.restrict_member(g.id, bob.id, membership_id(g.id, carol.id),
                 restrictions: ["post"]
               )
    end

    test "a moderator cannot sanction the owner", %{group: g, alice: alice, bob: bob} do
      {:ok, _} =
        Groups.update_member_role(g.id, alice.id, membership_id(g.id, bob.id), "moderator")

      assert {:error, :forbidden} =
               Groups.restrict_member(g.id, bob.id, membership_id(g.id, alice.id),
                 restrictions: ["post"]
               )
    end
  end

  describe "timed sanctions expire at read time" do
    setup %{alice: alice, bob: bob} do
      {:ok, group} =
        Groups.create_group(alice.id, %{
          "name" => "Timed",
          "handle" => "timedgroup",
          "visibility" => "private",
          "join_policy" => "open"
        })

      {:ok, _} = Groups.join_group(group.id, bob.id)
      %{group: group, bob_mid: membership_id(group.id, bob.id)}
    end

    defp ago(seconds), do: DateTime.utc_now() |> DateTime.add(-seconds, :second)
    defp ahead(seconds), do: DateTime.utc_now() |> DateTime.add(seconds, :second)

    test "a future expiry keeps the sanction in force", %{
      group: g,
      alice: alice,
      bob: bob,
      bob_mid: mid
    } do
      {:ok, _} =
        Groups.restrict_member(g.id, alice.id, mid, restrictions: ["post"], until: ahead(3600))

      refute Groups.can_do_in_group?(g.id, bob.id, :post)
    end

    # The whole point: correctness must not depend on the sweeper having run.
    test "a lapsed partial ban is lifted WITHOUT the sweeper running", %{
      group: g,
      alice: alice,
      bob: bob,
      bob_mid: mid
    } do
      {:ok, _} =
        Groups.restrict_member(g.id, alice.id, mid, restrictions: ["post"], until: ago(60))

      assert Groups.can_do_in_group?(g.id, bob.id, :post),
             "a late or dead sweeper tick must not keep a member sanctioned past their time"
    end

    test "a lapsed full ban is lifted WITHOUT the sweeper running", %{
      group: g,
      alice: alice,
      bob: bob,
      bob_mid: mid
    } do
      {:ok, banned} = Groups.restrict_member(g.id, alice.id, mid, full: true, until: ago(60))

      # The row still says banned...
      assert banned.status == :banned
      # ...but every path honours the expiry, not just the write check.
      # If these disagreed, a member could post to a group they can't read.
      assert Groups.can_do_in_group?(g.id, bob.id, :post)
      assert Groups.member?(g.id, bob.id)
      assert Groups.member_role(g.id, bob.id) == :member
    end

    test "a permanent sanction (no until) never lapses", %{
      group: g,
      alice: alice,
      bob: bob,
      bob_mid: mid
    } do
      {:ok, _} = Groups.restrict_member(g.id, alice.id, mid, restrictions: ["post"], until: nil)
      refute Groups.can_do_in_group?(g.id, bob.id, :post)
    end
  end

  describe "sweep_expired_sanctions/1" do
    setup %{alice: alice, bob: bob} do
      {:ok, group} =
        Groups.create_group(alice.id, %{
          "name" => "Sweep",
          "handle" => "sweepgroup",
          "visibility" => "private",
          "join_policy" => "open"
        })

      {:ok, _} = Groups.join_group(group.id, bob.id)
      %{group: group, bob_mid: membership_id(group.id, bob.id)}
    end

    test "tidies a lapsed partial ban", %{group: g, alice: alice, bob: bob, bob_mid: mid} do
      {:ok, _} =
        Groups.restrict_member(g.id, alice.id, mid, restrictions: ["post"], until: ago(60))

      assert Groups.sweep_expired_sanctions() >= 1

      row = Repo.get!(Hybridsocial.Groups.GroupMember, mid)
      assert row.restrictions == []
      assert is_nil(row.restricted_until)
      assert Groups.can_do_in_group?(g.id, bob.id, :post)
    end

    test "restores a lapsed full ban to approved", %{
      group: g,
      alice: alice,
      bob: bob,
      bob_mid: mid
    } do
      {:ok, _} = Groups.restrict_member(g.id, alice.id, mid, full: true, until: ago(60))

      Groups.sweep_expired_sanctions()

      row = Repo.get!(Hybridsocial.Groups.GroupMember, mid)
      assert row.status == :approved
      assert Groups.member?(g.id, bob.id)
    end

    test "leaves an in-force sanction alone", %{group: g, alice: alice, bob_mid: mid} do
      {:ok, _} =
        Groups.restrict_member(g.id, alice.id, mid, restrictions: ["post"], until: ahead(3600))

      Groups.sweep_expired_sanctions()

      row = Repo.get!(Hybridsocial.Groups.GroupMember, mid)
      assert row.restrictions == ["post"]
    end

    test "leaves a permanent sanction alone", %{group: g, alice: alice, bob_mid: mid} do
      {:ok, _} = Groups.restrict_member(g.id, alice.id, mid, restrictions: ["post"])

      Groups.sweep_expired_sanctions()

      row = Repo.get!(Hybridsocial.Groups.GroupMember, mid)
      assert row.restrictions == ["post"]
    end
  end
end
