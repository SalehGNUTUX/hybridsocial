defmodule Hybridsocial.Federation.ContainmentTest do
  use ExUnit.Case, async: true

  alias Hybridsocial.Federation.Containment

  describe "get_actor/1" do
    test "extracts a string actor" do
      assert Containment.get_actor(%{"actor" => "https://remote.example/u/alice"}) ==
               "https://remote.example/u/alice"
    end

    test "extracts the first string from an actor list" do
      assert Containment.get_actor(%{
               "actor" => ["https://remote.example/u/alice", "https://remote.example/u/bob"]
             }) == "https://remote.example/u/alice"
    end

    test "extracts from a list of actor maps, picking a Person-like type" do
      assert Containment.get_actor(%{
               "actor" => [
                 %{"id" => "https://remote.example/u/group", "type" => "Collection"},
                 %{"id" => "https://remote.example/u/alice", "type" => "Person"}
               ]
             }) == "https://remote.example/u/alice"
    end

    test "extracts from a nested map" do
      assert Containment.get_actor(%{
               "actor" => %{"id" => "https://remote.example/u/alice", "type" => "Person"}
             }) == "https://remote.example/u/alice"
    end

    test "falls back to attributedTo when actor is nil" do
      assert Containment.get_actor(%{
               "actor" => nil,
               "attributedTo" => "https://remote.example/u/alice"
             }) == "https://remote.example/u/alice"
    end

    test "returns nil when no actor is present" do
      assert Containment.get_actor(%{"type" => "Create"}) == nil
    end
  end

  describe "contain_origin/2" do
    test "accepts activity id and actor on the same host" do
      activity = %{"actor" => "https://remote.example/u/alice"}
      assert :ok = Containment.contain_origin("https://remote.example/objects/note-1", activity)
    end

    test "rejects activity id and actor on different hosts (spoofing attempt)" do
      activity = %{"actor" => "https://attacker.example/u/alice"}

      assert :error =
               Containment.contain_origin("https://victim.example/objects/note-1", activity)
    end

    test "rejects a nil actor" do
      assert :error = Containment.contain_origin("https://remote.example/n/1", %{"actor" => nil})
    end

    test "uses attributedTo when actor is missing" do
      activity = %{"attributedTo" => "https://remote.example/u/alice"}
      assert :ok = Containment.contain_origin("https://remote.example/objects/note-1", activity)
    end
  end

  describe "contain_child/1" do
    test "accepts an embedded object from the same host as its attributedTo" do
      activity = %{
        "object" => %{
          "id" => "https://remote.example/objects/note-1",
          "attributedTo" => "https://remote.example/u/alice"
        }
      }

      assert :ok = Containment.contain_child(activity)
    end

    test "rejects an embedded object whose id is on a different host than attributedTo" do
      activity = %{
        "object" => %{
          "id" => "https://victim.example/objects/note-1",
          "attributedTo" => "https://attacker.example/u/alice"
        }
      }

      assert :error = Containment.contain_child(activity)
    end

    test "passes through activities with no embedded object" do
      assert :ok = Containment.contain_child(%{"object" => "https://remote.example/n/1"})
    end
  end

  describe "contain_local_fetch/1 (SSRF guard)" do
    test "blocks fetching local URLs" do
      local = HybridsocialWeb.Endpoint.url() <> "/actors/internal"
      assert :error = Containment.contain_local_fetch(local)
    end

    test "allows fetching remote URLs" do
      assert :ok = Containment.contain_local_fetch("https://remote.example/u/alice")
    end
  end

  describe "same_origin/2" do
    test "returns :ok for same host" do
      assert :ok =
               Containment.same_origin(
                 "https://remote.example/a",
                 "https://remote.example/b"
               )
    end

    test "returns :error for different hosts" do
      assert :error =
               Containment.same_origin(
                 "https://remote.example/a",
                 "https://other.example/b"
               )
    end
  end
end
