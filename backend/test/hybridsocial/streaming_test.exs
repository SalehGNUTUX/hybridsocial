defmodule Hybridsocial.StreamingTest do
  # async: false — these tests broadcast to shared global PubSub topics
  # (e.g. "timeline:public"). Run concurrently, one test's broadcast lands
  # in another's mailbox and trips refute_receive.
  use Hybridsocial.DataCase, async: false

  alias Hybridsocial.Streaming

  describe "broadcast_post/1" do
    # broadcast_post fans out to followers via a real DB query on
    # account_id, so it must be a valid identity UUID (not "user-1").
    setup do
      %{identity: create_user("streamer", "streamer@test.com")}
    end

    test "broadcasts public post to public timeline", %{identity: identity} do
      Phoenix.PubSub.subscribe(Hybridsocial.PubSub, "timeline:public")

      post = %{
        id: "post-1",
        content: "Hello world",
        visibility: "public",
        account_id: identity.id,
        tags: []
      }

      assert :ok = Streaming.broadcast_post(post)
      assert_receive %{event: "update", payload: ^post}
    end

    test "broadcasts post to author's user topic", %{identity: identity} do
      Phoenix.PubSub.subscribe(Hybridsocial.PubSub, "user:#{identity.id}")

      post = %{
        id: "post-2",
        content: "Hello",
        visibility: "public",
        account_id: identity.id,
        tags: []
      }

      assert :ok = Streaming.broadcast_post(post)
      assert_receive %{event: "update", payload: ^post}
    end

    test "broadcasts post to group topic", %{identity: identity} do
      Phoenix.PubSub.subscribe(Hybridsocial.PubSub, "group:group-1")

      post = %{
        id: "post-3",
        content: "Group post",
        visibility: "public",
        account_id: identity.id,
        group_id: "group-1",
        tags: []
      }

      assert :ok = Streaming.broadcast_post(post)
      assert_receive %{event: "update", payload: ^post}
    end

    test "broadcasts post to hashtag topics", %{identity: identity} do
      Phoenix.PubSub.subscribe(Hybridsocial.PubSub, "hashtag:elixir")

      post = %{
        id: "post-4",
        content: "Tagged post",
        visibility: "public",
        account_id: identity.id,
        tags: ["elixir"]
      }

      assert :ok = Streaming.broadcast_post(post)
      assert_receive %{event: "update", payload: ^post}
    end

    test "does not broadcast private posts to public timeline", %{identity: identity} do
      Phoenix.PubSub.subscribe(Hybridsocial.PubSub, "timeline:public")

      post = %{
        id: "post-5",
        content: "Private post",
        visibility: "private",
        account_id: identity.id,
        tags: []
      }

      assert :ok = Streaming.broadcast_post(post)
      refute_receive %{event: "update", payload: _}
    end
  end

  describe "broadcast_notification/1" do
    test "broadcasts notification to user topic" do
      Phoenix.PubSub.subscribe(Hybridsocial.PubSub, "user:user-1")

      notification = %{
        id: "notif-1",
        type: "follow",
        account_id: "user-1"
      }

      assert :ok = Streaming.broadcast_notification(notification)
      assert_receive %{event: "notification", payload: ^notification}
    end
  end

  describe "broadcast_delete/1" do
    test "broadcasts delete event to public timeline" do
      Phoenix.PubSub.subscribe(Hybridsocial.PubSub, "timeline:public")

      assert :ok = Streaming.broadcast_delete("post-1")
      assert_receive %{event: "delete", payload: "post-1"}
    end
  end

  describe "broadcast_dm/2" do
    test "broadcasts direct message to conversation topic" do
      Phoenix.PubSub.subscribe(Hybridsocial.PubSub, "direct:conv-1")

      message = %{id: "msg-1", content: "Hello DM"}

      assert :ok = Streaming.broadcast_dm("conv-1", message)
      assert_receive %{event: "conversation", payload: ^message}
    end
  end
end
