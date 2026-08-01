defmodule Hybridsocial.Federation.DeadLettersTest do
  use Hybridsocial.DataCase, async: true

  alias Hybridsocial.Federation.{DeadLetters, Delivery}
  alias Hybridsocial.Repo

  defp delivery(attrs) do
    %Delivery{}
    |> Delivery.changeset(
      Map.merge(
        %{
          activity_id: "https://local.test/activities/#{System.unique_integer([:positive])}",
          activity_type: "Create",
          target_inbox: "https://gone.example/users/x/inbox",
          status: "failed"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp backdate(%Delivery{} = d, days) do
    at = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    d
    |> Ecto.Changeset.change(inserted_at: at)
    |> Repo.update!()
  end

  describe "drop_domain/1" do
    test "drops every failed row for the domain and leaves the rest alone" do
      delivery(%{})
      delivery(%{})
      keep_pending = delivery(%{status: "pending"})
      keep_other = delivery(%{target_inbox: "https://alive.example/inbox"})

      assert DeadLetters.drop_domain("gone.example") == 2

      remaining = Repo.all(Delivery) |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.equal?(remaining, MapSet.new([keep_pending.id, keep_other.id]))
    end

    test "matches the host even when the inbox carries a port" do
      delivery(%{target_inbox: "https://gone.example:8443/users/x/inbox"})

      assert DeadLetters.drop_domain("gone.example") == 1
    end

    test "an unknown domain drops nothing" do
      delivery(%{})

      assert DeadLetters.drop_domain("never-heard-of.example") == 0
      assert Repo.aggregate(Delivery, :count) == 1
    end
  end

  describe "prune/1" do
    test "removes terminal rows past the cutoff and keeps live work" do
      backdate(delivery(%{status: "delivered"}), 40)
      backdate(delivery(%{status: "failed"}), 40)
      backdate(delivery(%{status: "pending"}), 40)
      backdate(delivery(%{status: "retrying"}), 40)
      recent = delivery(%{status: "failed"})

      assert {1, 1} = DeadLetters.prune(30)

      statuses = Repo.all(Delivery) |> Enum.map(& &1.status) |> Enum.sort()
      assert statuses == ["failed", "pending", "retrying"]
      assert Repo.get(Delivery, recent.id)
    end

    test "is a no-op when nothing is past the cutoff" do
      delivery(%{status: "delivered"})

      assert {0, 0} = DeadLetters.prune(30)
      assert Repo.aggregate(Delivery, :count) == 1
    end
  end
end
