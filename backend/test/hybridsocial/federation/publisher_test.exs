defmodule Hybridsocial.Federation.PublisherTest do
  use Hybridsocial.DataCase, async: true

  alias Hybridsocial.Federation.Publisher
  alias Hybridsocial.Federation.ActivityBuilder

  @public "https://www.w3.org/ns/activitystreams#Public"

  describe "determine_recipients/2" do
    test "returns empty list when there are no followers" do
      identity = create_user("sender1", "sender1@example.com")

      activity = %{
        "type" => "Create",
        "to" => [@public],
        "cc" => ["http://localhost:4002/actors/#{identity.id}/followers"]
      }

      inboxes = Publisher.determine_recipients(activity, identity)
      assert inboxes == []
    end

    test "returns follower inboxes for public posts" do
      identity = create_user("sender2", "sender2@example.com")
      follower = create_user("follower2", "follower2@example.com")

      # Create a follow relationship
      {:ok, _follow} = Hybridsocial.Social.follow(follower.id, identity.id)

      activity = %{
        "type" => "Create",
        "to" => [@public],
        "cc" => ["http://localhost:4002/actors/#{identity.id}/followers"]
      }

      inboxes = Publisher.determine_recipients(activity, identity)

      # Local follower inboxes are filtered out (we don't deliver locally via AP)
      assert inboxes == []
    end

    test "returns empty list for followers-only posts with no followers" do
      identity = create_user("sender3", "sender3@example.com")
      followers_url = "http://localhost:4002/actors/#{identity.id}/followers"

      activity = %{
        "type" => "Create",
        "to" => [followers_url],
        "cc" => []
      }

      inboxes = Publisher.determine_recipients(activity, identity)
      assert inboxes == []
    end

    test "deduplicates inbox URLs" do
      identity = create_user("sender4", "sender4@example.com")

      # Activity addressing the same target in both to and cc
      activity = %{
        "type" => "Create",
        "to" => [@public],
        "cc" => [@public, "http://localhost:4002/actors/#{identity.id}/followers"]
      }

      inboxes = Publisher.determine_recipients(activity, identity)

      # Should be deduplicated
      assert inboxes == Enum.uniq(inboxes)
    end
  end

  describe "publish/2" do
    test "creates delivery records for each recipient" do
      identity = create_user("pub1", "pub1@example.com")

      {:ok, post} =
        Hybridsocial.Social.Posts.create_post(identity.id, %{
          "content" => "Test post",
          "visibility" => "direct"
        })

      post = Hybridsocial.Repo.preload(post, :identity)
      activity = ActivityBuilder.build_create(post)

      # Direct visibility with no recipients should create 0 deliveries
      {:ok, count} = Publisher.publish(activity, identity)
      assert count == 0
    end
  end

  describe "deliver/3 — refuses to send unsigned" do
    test "returns an explicit error when the identity has no private_key" do
      identity = create_user("nokey1", "nokey1@example.com")
      # Strip the auto-generated key so we exercise the missing-key branch.
      {:ok, identity} =
        identity
        |> Ecto.Changeset.cast(%{private_key: nil}, [:private_key])
        |> Hybridsocial.Repo.update()

      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Follow",
        "id" => "http://localhost:4002/activities/test-no-key",
        "actor" => "http://localhost:4002/actors/#{identity.id}",
        "object" => "https://remote.example/users/x"
      }

      assert {:error, "missing_private_key"} =
               Publisher.deliver(activity, "https://remote.example/inbox", identity)
    end
  end
end
