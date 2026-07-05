defmodule Hybridsocial.Social.DraftsTest do
  use Hybridsocial.DataCase, async: true

  alias Hybridsocial.Social.{Drafts, PostDraft}

  describe "create_draft/2" do
    test "creates a draft owned by the caller" do
      identity = create_user("drafter")

      assert {:ok, %PostDraft{} = draft} =
               Drafts.create_draft(identity.id, %{
                 "content" => "A work in progress",
                 "visibility" => "followers"
               })

      assert draft.identity_id == identity.id
      assert draft.content == "A work in progress"
      assert draft.visibility == "followers"
    end

    test "accepts media_ids as an array field without attaching anything" do
      identity = create_user("drafter_media")
      media_id = Ecto.UUID.generate()

      assert {:ok, draft} =
               Drafts.create_draft(identity.id, %{
                 "content" => "With media",
                 "media_ids" => [media_id]
               })

      assert draft.media_ids == [media_id]
    end

    test "rejects an invalid visibility" do
      identity = create_user("drafter_bad")

      assert {:error, changeset} =
               Drafts.create_draft(identity.id, %{"visibility" => "galaxy-brain"})

      assert %{visibility: _} = errors_on(changeset)
    end
  end

  describe "list_drafts/1" do
    test "returns the caller's drafts newest-updated first" do
      identity = create_user("lister")

      {:ok, a} = Drafts.create_draft(identity.id, %{"content" => "first"})
      {:ok, b} = Drafts.create_draft(identity.id, %{"content" => "second"})
      # Touch a to make it the newest-updated
      {:ok, a} = Drafts.update_draft(a.id, identity.id, %{"content" => "first (edited)"})

      drafts = Drafts.list_drafts(identity.id)
      assert [first, second] = drafts
      assert first.id == a.id
      assert second.id == b.id
    end

    test "does not leak drafts from other identities" do
      alice = create_user("alice")
      bob = create_user("bob")

      {:ok, _} = Drafts.create_draft(alice.id, %{"content" => "alice's draft"})
      {:ok, _} = Drafts.create_draft(bob.id, %{"content" => "bob's draft"})

      assert [%{content: "alice's draft"}] = Drafts.list_drafts(alice.id)
      assert [%{content: "bob's draft"}] = Drafts.list_drafts(bob.id)
    end
  end

  describe "get_draft/2" do
    test "returns the draft when owned by the caller" do
      identity = create_user("getter")
      {:ok, draft} = Drafts.create_draft(identity.id, %{"content" => "mine"})

      assert {:ok, fetched} = Drafts.get_draft(draft.id, identity.id)
      assert fetched.id == draft.id
    end

    test "returns :forbidden when owned by someone else" do
      alice = create_user("a")
      bob = create_user("b")
      {:ok, draft} = Drafts.create_draft(alice.id, %{"content" => "hands off"})

      assert {:error, :forbidden} = Drafts.get_draft(draft.id, bob.id)
    end

    test "returns :not_found for a missing id" do
      identity = create_user("nobody")
      assert {:error, :not_found} = Drafts.get_draft(Ecto.UUID.generate(), identity.id)
    end
  end

  describe "update_draft/3" do
    test "updates content and keeps identity_id stable" do
      identity = create_user("updater")
      {:ok, draft} = Drafts.create_draft(identity.id, %{"content" => "v1"})

      assert {:ok, updated} =
               Drafts.update_draft(draft.id, identity.id, %{"content" => "v2"})

      assert updated.id == draft.id
      assert updated.identity_id == identity.id
      assert updated.content == "v2"
    end

    test "refuses updates from a non-owner" do
      alice = create_user("u_alice")
      bob = create_user("u_bob")
      {:ok, draft} = Drafts.create_draft(alice.id, %{"content" => "alice's"})

      assert {:error, :forbidden} =
               Drafts.update_draft(draft.id, bob.id, %{"content" => "hijacked"})

      fresh = Repo.get!(PostDraft, draft.id)
      assert fresh.content == "alice's"
    end
  end

  describe "delete_draft/2" do
    test "deletes the draft" do
      identity = create_user("deleter")
      {:ok, draft} = Drafts.create_draft(identity.id, %{"content" => "goodbye"})

      assert {:ok, _} = Drafts.delete_draft(draft.id, identity.id)
      refute Repo.get(PostDraft, draft.id)
    end

    test "refuses deletion from a non-owner" do
      alice = create_user("d_alice")
      bob = create_user("d_bob")
      {:ok, draft} = Drafts.create_draft(alice.id, %{"content" => "alice's"})

      assert {:error, :forbidden} = Drafts.delete_draft(draft.id, bob.id)
      assert Repo.get(PostDraft, draft.id)
    end
  end
end
