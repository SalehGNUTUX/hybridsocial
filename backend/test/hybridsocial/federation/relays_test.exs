defmodule Hybridsocial.Federation.RelaysTest do
  use Hybridsocial.DataCase, async: false

  alias Hybridsocial.Federation.Relays

  describe "subscribe_to_relay/2" do
    test "creates a relay with pending status" do
      admin = create_admin("relay_admin", "relay_admin@example.com")

      assert {:ok, relay} =
               Relays.subscribe_to_relay("https://relay.example/inbox", admin.id)

      assert relay.inbox_url == "https://relay.example/inbox"
      assert relay.status == "pending"
    end

    test "rejects duplicate inbox URLs" do
      admin = create_admin("relay_dup_admin", "relay_dup_admin@example.com")

      {:ok, _} = Relays.subscribe_to_relay("https://relay2.example/inbox", admin.id)
      assert {:error, _} = Relays.subscribe_to_relay("https://relay2.example/inbox", admin.id)
    end
  end

  describe "unsubscribe_from_relay/2" do
    test "removes the relay" do
      admin = create_admin("relay_unsub", "relay_unsub@example.com")
      {:ok, relay} = Relays.subscribe_to_relay("https://relay3.example/inbox", admin.id)

      assert {:ok, _} = Relays.unsubscribe_from_relay(relay.id, admin.id)
      assert Relays.get_relay(relay.id) == nil
    end

    test "returns error for non-existent relay" do
      admin = create_admin("relay_missing", "relay_missing@example.com")
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = Relays.unsubscribe_from_relay(fake_id, admin.id)
    end
  end

  describe "list_relays/0" do
    test "returns all relays" do
      admin = create_admin("relay_list", "relay_list@example.com")
      {:ok, _} = Relays.subscribe_to_relay("https://relay4.example/inbox", admin.id)
      {:ok, _} = Relays.subscribe_to_relay("https://relay5.example/inbox", admin.id)

      relays = Relays.list_relays()
      assert length(relays) >= 2
    end
  end

  describe "accept_relay/1" do
    test "marks relay as accepted by domain" do
      admin = create_admin("relay_accept", "relay_accept@example.com")
      {:ok, _} = Relays.subscribe_to_relay("https://relay6.example/inbox", admin.id)

      assert {:ok, relay} = Relays.accept_relay("relay6.example")
      assert relay.status == "accepted"
    end

    test "returns error for unknown domain" do
      assert {:error, :not_found} = Relays.accept_relay("unknown.example")
    end
  end

  describe "process_relay_announce/1" do
    test "rejects malformed announces (no actor / no object URL)" do
      assert {:error, :invalid_announce} =
               Relays.process_relay_announce(%{"type" => "Announce"})

      assert {:error, :invalid_announce} =
               Relays.process_relay_announce(%{"actor" => "https://r.example/actor"})
    end

    test "rejects announces from unknown (unaccepted) relay actors" do
      # No matching relay row exists, so this hostname is unknown.
      assert {:error, :unknown_relay} =
               Relays.process_relay_announce(%{
                 "actor" => "https://stranger.example/actor",
                 "object" => "https://stranger.example/posts/1"
               })
    end

    test "accepts announces from a registered relay (host-matched)" do
      {:ok, _} =
        Relays.subscribe_to_relay("https://approved-relay.example/inbox", Ecto.UUID.generate())

      {:ok, _} = Relays.accept_relay("approved-relay.example")

      # Object dereference will fail (network), but we verify the
      # call gets PAST the known_relay? gate by checking the error
      # isn't :unknown_relay.
      result =
        Relays.process_relay_announce(%{
          "actor" => "https://approved-relay.example/actor",
          "object" => "https://approved-relay.example/posts/1"
        })

      refute result == {:error, :unknown_relay}
    end
  end
end
