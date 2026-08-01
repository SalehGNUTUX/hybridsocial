defmodule Hybridsocial.Federation.DeadActorsTest do
  use Hybridsocial.DataCase, async: true

  alias Hybridsocial.Federation.{DeadActors, Delivery}
  alias Hybridsocial.Repo
  alias Hybridsocial.Social.Follow

  defp remote_user(handle, actor_url, inbox_url) do
    handle
    |> create_user("#{handle}@example.com")
    |> Ecto.Changeset.cast(
      %{is_local: false, ap_actor_url: actor_url, inbox_url: inbox_url},
      [:is_local, :ap_actor_url, :inbox_url]
    )
    |> Repo.update!()
  end

  defp failed_delivery(inbox, error) do
    %Delivery{}
    |> Delivery.changeset(%{
      activity_id: "https://local.test/activities/#{System.unique_integer([:positive])}",
      activity_type: "Create",
      target_inbox: inbox,
      status: "failed",
      error: error
    })
    |> Repo.insert!()
  end

  describe "candidates/1" do
    test "picks up inboxes past the 404/410 threshold" do
      inbox = "https://gone.example/users/x/inbox"
      identity = remote_user("gonex", "https://gone.example/users/x", inbox)

      for _ <- 1..5, do: failed_delivery(inbox, "HTTP 410: Gone")

      assert [%{identity: %{id: id}, failures: 5}] = DeadActors.candidates(failure_threshold: 5)
      assert id == identity.id
    end

    test "ignores inboxes below the threshold" do
      inbox = "https://gone.example/users/y/inbox"
      remote_user("goney", "https://gone.example/users/y", inbox)
      for _ <- 1..4, do: failed_delivery(inbox, "HTTP 404: nope")

      assert DeadActors.candidates(failure_threshold: 5) == []
    end

    test "ignores connection-level failures — a dead host is not a dead account" do
      inbox = "https://down.example/users/z/inbox"
      remote_user("downz", "https://down.example/users/z", inbox)
      for _ <- 1..10, do: failed_delivery(inbox, "Connection error: :nxdomain")

      assert DeadActors.candidates(failure_threshold: 5) == []
    end

    test "ignores local identities and already-retired ones" do
      inbox = "https://gone.example/users/w/inbox"
      identity = remote_user("gonew", "https://gone.example/users/w", inbox)
      for _ <- 1..6, do: failed_delivery(inbox, "HTTP 410: Gone")

      assert [_] = DeadActors.candidates(failure_threshold: 5)

      identity
      |> Hybridsocial.Accounts.Identity.soft_delete_changeset()
      |> Repo.update!()

      assert DeadActors.candidates(failure_threshold: 5) == []
    end
  end

  describe "retire/2" do
    test "drops follows in both directions and clears the inbox's dead letters" do
      inbox = "https://gone.example/users/dead/inbox"
      dead = remote_user("deadone", "https://gone.example/users/dead", inbox)
      local_a = create_user("locala", "locala@example.com")
      local_b = create_user("localb", "localb@example.com")

      {:ok, _} = Hybridsocial.Social.follow(dead.id, local_a.id)
      {:ok, _} = Hybridsocial.Social.follow(local_b.id, dead.id)
      for _ <- 1..3, do: failed_delivery(inbox, "HTTP 410: Gone")
      # A live peer's rows must survive.
      failed_delivery("https://alive.example/inbox", "HTTP 410: Gone")

      stats = DeadActors.retire(dead, "actor returned 410 Gone")

      assert stats.follows_removed == 2
      assert stats.dead_letters_dropped == 3
      # Content is kept by default — deleting the follow is what stops
      # delivery; wiping cached posts is a separate, opt-in decision.
      assert stats.posts_purged == 0

      assert Repo.aggregate(Follow, :count) == 0
      assert Repo.aggregate(Delivery, :count) == 1
      assert Repo.get(Hybridsocial.Accounts.Identity, dead.id).deleted_at == nil
    end

    test "audit-logs the retirement even with no admin behind it" do
      dead =
        remote_user(
          "audited",
          "https://gone.example/users/audited",
          "https://gone.example/users/audited/inbox"
        )

      DeadActors.retire(dead, "actor returned 410 Gone")

      entry =
        Hybridsocial.Moderation.AuditLog
        |> Ecto.Query.where(action: "federation.dead_actor_retired")
        |> Repo.one()

      assert entry.actor_id == nil
      assert entry.target_id == dead.id
      assert entry.details["reason"] == "actor returned 410 Gone"
    end
  end

  describe "handle_self_delete/1" do
    test "retires an actor that announces its own deletion" do
      inbox = "https://gone.example/users/selfdel/inbox"
      actor = "https://gone.example/users/selfdel"
      dead = remote_user("selfdel", actor, inbox)
      local = create_user("localc", "localc@example.com")
      {:ok, _} = Hybridsocial.Social.follow(dead.id, local.id)

      assert {:ok, stats} = DeadActors.handle_self_delete(actor)
      assert stats.follows_removed == 1
      assert Repo.aggregate(Follow, :count) == 0
    end

    test "an unknown actor is a no-op, not an error" do
      assert {:ok, :unknown_actor} =
               DeadActors.handle_self_delete("https://nowhere.example/users/nobody")
    end
  end

  describe "verify/1" do
    test "a missing actor URL is inconclusive, never gone" do
      identity = create_user("nourl", "nourl@example.com")
      assert DeadActors.verify(%{identity | ap_actor_url: nil}) == :unknown
    end
  end
end
