defmodule Hybridsocial.AnalyticsLocalityTest do
  use Hybridsocial.DataCase, async: true

  alias Hybridsocial.Analytics
  alias Hybridsocial.Social.Posts

  defp remote_identity(handle) do
    ap = "https://remote.example/users/#{handle}"

    %Hybridsocial.Accounts.Identity{}
    |> Ecto.Changeset.cast(
      %{
        id: Ecto.UUID.generate(),
        type: "user",
        handle: handle,
        ap_actor_url: ap,
        is_local: false
      },
      [:id, :type, :handle, :ap_actor_url, :is_local]
    )
    |> Repo.insert!()
  end

  defp post!(identity_id, content) do
    {:ok, p} =
      Posts.create_post(identity_id, %{
        "content" => content,
        "post_type" => "text",
        "visibility" => "public"
      })

    p
  end

  test "post_volume counts only local posts; federated_post_volume counts only remote" do
    local = create_user("an_local")
    remote = remote_identity("an_remote")

    post!(local.id, "local one")
    post!(local.id, "local two")
    post!(remote.id, "remote one")

    local_total = Analytics.post_volume(1) |> Enum.map(& &1.count) |> Enum.sum()
    fed_total = Analytics.federated_post_volume(1) |> Enum.map(& &1.count) |> Enum.sum()

    assert local_total == 2
    assert fed_total == 1
  end

  test "active_users excludes remote actors" do
    local = create_user("an_local2")
    remote = remote_identity("an_remote2")

    post!(local.id, "hello")
    post!(remote.id, "hello from afar")

    daily = Analytics.active_users(1) |> Enum.map(& &1.count) |> Enum.sum()
    assert daily == 1
  end

  test "active_users_distinct counts a user once, not once per active day" do
    a = create_user("an_a")
    b = create_user("an_b")

    # Two posts from the same account on the same day, plus one from another.
    post!(a.id, "first")
    post!(a.id, "second")
    post!(b.id, "only")

    # Summing daily buckets happens to match here (one day), but the
    # distinct count is the figure the header must use.
    assert Analytics.active_users_distinct(1) == 2
  end

  test "summary separates local posts from ingested federated posts" do
    local = create_user("an_sum")
    remote = remote_identity("an_sum_remote")

    post!(local.id, "mine")
    post!(remote.id, "theirs")
    post!(remote.id, "theirs again")

    s = Analytics.summary()

    assert s.total_posts == 1
    assert s.federated_posts == 2
    # `remote_identities` keys off is_local, not the presence of an
    # ap_actor_url — locals have one of those too.
    assert s.federation.remote_identities == 1
  end
end
