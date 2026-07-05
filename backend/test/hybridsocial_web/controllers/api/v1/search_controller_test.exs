defmodule HybridsocialWeb.Api.V1.SearchControllerTest do
  use HybridsocialWeb.ConnCase, async: true

  alias Hybridsocial.Social.Posts

  defp login(conn, email) do
    {:ok, tokens} = Hybridsocial.Auth.login(email, "password1234567890")
    put_req_header(conn, "authorization", "Bearer #{tokens.access_token}")
  end

  describe "GET /api/v1/search" do
    test "searches accounts without auth", %{conn: conn} do
      _user = create_user("searchctrl", "searchctrl@test.com")

      conn = get(conn, "/api/v1/search", %{"q" => "searchctrl"})
      response = json_response(conn, 200)

      assert is_list(response["accounts"])
      assert length(response["accounts"]) >= 1
      assert hd(response["accounts"])["handle"] == "searchctrl"
    end

    test "searches posts", %{conn: conn} do
      user = create_user("postfinder", "postfinder@test.com")
      {:ok, _post} = Posts.create_post(user.id, %{"content" => "Unique xvbrkm content"})

      conn = get(conn, "/api/v1/search", %{"q" => "xvbrkm", "type" => "posts"})
      response = json_response(conn, 200)

      assert is_list(response["statuses"])
      assert length(response["statuses"]) >= 1
    end

    test "searches hashtags", %{conn: conn} do
      user = create_user("hashfinder", "hashfinder@test.com")
      {:ok, _post} = Posts.create_post(user.id, %{"content" => "Check out #findthis123"})

      conn = get(conn, "/api/v1/search", %{"q" => "findthis123", "type" => "hashtags"})
      response = json_response(conn, 200)

      assert is_list(response["hashtags"])
      assert length(response["hashtags"]) >= 1
    end

    test "returns all types when no type specified", %{conn: conn} do
      _user = create_user("allsearch", "allsearch@test.com")

      conn = get(conn, "/api/v1/search", %{"q" => "allsearch"})
      response = json_response(conn, 200)

      assert Map.has_key?(response, "accounts")
      assert Map.has_key?(response, "statuses")
      assert Map.has_key?(response, "hashtags")
      assert Map.has_key?(response, "groups")
    end

    test "returns empty results for blank query", %{conn: conn} do
      conn = get(conn, "/api/v1/search", %{"q" => ""})
      response = json_response(conn, 200)

      assert response["accounts"] == []
      assert response["statuses"] == []
    end

    test "works with authenticated user", %{conn: conn} do
      user = create_user("authsearch", "authsearch@test.com")
      conn = login(conn, "authsearch@test.com")

      {:ok, _post} =
        Posts.create_post(user.id, %{
          "content" => "Private nqwtps content",
          "visibility" => "followers"
        })

      conn = get(conn, "/api/v1/search", %{"q" => "nqwtps", "type" => "posts"})
      response = json_response(conn, 200)

      assert length(response["statuses"]) >= 1
    end
  end

  describe "exact_remote_match?/2" do
    # Regression: searching `@user@domain` was incorrectly satisfied
    # by ANY local result containing the username substring, so
    # federation lookup never fired for users on instances we hadn't
    # talked to before. The gate must require an exact (user, host)
    # match before considering local results a hit.

    alias HybridsocialWeb.Api.V1.SearchController

    defp identity_with(attrs) do
      Map.merge(
        %Hybridsocial.Accounts.Identity{
          id: Ecto.UUID.generate(),
          handle: "placeholder"
        },
        attrs
      )
    end

    test "true when an identity's acct exactly matches the query" do
      identities = [
        identity_with(%{
          handle: "ahmad_bassamso_aaa",
          ap_actor_url: "https://bassam.social/users/ahmad"
        })
      ]

      assert SearchController.exact_remote_match?("@ahmad@bassam.social", identities)
    end

    test "case-insensitive comparison" do
      identities = [
        identity_with(%{
          handle: "ahmad_bassamso_aaa",
          ap_actor_url: "https://bassam.social/users/ahmad"
        })
      ]

      assert SearchController.exact_remote_match?("@AHMAD@BASSAM.SOCIAL", identities)
    end

    test "false when only a different-domain remote with same username matches" do
      identities = [
        identity_with(%{
          handle: "ahmad_mastodon_aaa",
          ap_actor_url: "https://mastodon.social/users/ahmad"
        })
      ]

      refute SearchController.exact_remote_match?("@ahmad@bassam.social", identities)
    end

    test "false when only a local user with same handle matches" do
      identities = [
        identity_with(%{handle: "ahmad", ap_actor_url: nil})
      ]

      refute SearchController.exact_remote_match?("@ahmad@bassam.social", identities)
    end

    test "false for empty result list" do
      refute SearchController.exact_remote_match?("@ahmad@bassam.social", [])
    end

    test "true when match is anywhere in the result list, not just first" do
      identities = [
        identity_with(%{handle: "ahmad", ap_actor_url: nil}),
        identity_with(%{
          handle: "ahmad_mastodon_aaa",
          ap_actor_url: "https://mastodon.social/users/ahmad"
        }),
        identity_with(%{
          handle: "ahmad_bassamso_aaa",
          ap_actor_url: "https://bassam.social/users/ahmad"
        })
      ]

      assert SearchController.exact_remote_match?("@ahmad@bassam.social", identities)
    end
  end
end
