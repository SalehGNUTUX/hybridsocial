defmodule Hybridsocial.Social.PostsAudioGateTest do
  use Hybridsocial.DataCase, async: false

  alias Hybridsocial.Social.Posts
  alias Hybridsocial.Config

  # Tier-gating only kicks in when the tiered system is ON. Without
  # this, `limits_for/1` short-circuits to Pro and every user can
  # post audio — fine for dev but the opposite of what we're
  # trying to exercise here.
  setup do
    Config.set("tiers_enabled", true)
    on_exit(fn -> Config.set("tiers_enabled", false) end)
    :ok
  end

  defp create_user(handle, email, tier) do
    identity = create_user(handle, email)

    {:ok, identity} =
      identity
      |> Ecto.Changeset.change(verification_tier: tier)
      |> Hybridsocial.Repo.update()

    identity
  end

  describe "audio post tier gate" do
    test "free tier rejects post_type=audio" do
      identity = create_user("freeaudio", "freeaudio@test.com", "free")

      assert {:error, :audio_not_allowed} =
               Posts.create_post(
                 identity.id,
                 %{"post_type" => "audio", "visibility" => "public"},
                 identity
               )
    end

    test "verified_starter accepts post_type=audio" do
      identity = create_user("staraudio", "staraudio@test.com", "verified_starter")

      assert {:ok, post} =
               Posts.create_post(
                 identity.id,
                 %{"post_type" => "audio", "visibility" => "public"},
                 identity
               )

      assert post.post_type == "audio"
    end

    test "verified_pro accepts post_type=audio" do
      identity = create_user("proaudio", "proaudio@test.com", "verified_pro")

      assert {:ok, post} =
               Posts.create_post(
                 identity.id,
                 %{"post_type" => "audio", "visibility" => "public"},
                 identity
               )

      assert post.post_type == "audio"
    end
  end
end
