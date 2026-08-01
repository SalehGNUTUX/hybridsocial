defmodule HybridsocialWeb.MastodonCompatTest do
  @moduledoc """
  End-to-end coverage of the endpoints a Mastodon client actually calls, in
  the order it calls them. Each test asserts on the wire shape, since that is
  the whole contract — a field renamed here is a client that fails to parse.
  """
  use HybridsocialWeb.ConnCase, async: true

  alias Hybridsocial.Auth.OAuth
  alias Hybridsocial.Social.Posts

  # Drives the compat layer explicitly. The token-based inference is covered
  # by its own test below.
  defp mastodon_conn(conn, identity) do
    conn
    |> auth_conn(identity)
    |> put_req_header("x-api-compat", "mastodon")
  end

  defp post_for(identity, content \\ "hello world") do
    {:ok, post} = Posts.create_post(identity.id, %{"content" => content}, identity)
    Hybridsocial.Repo.preload(post, [:identity, :quote])
  end

  describe "GET /api/v1/accounts/verify_credentials" do
    test "answers with the account behind the token", %{conn: conn} do
      identity = create_user("verifyme", "verifyme@example.com")

      resp =
        conn
        |> mastodon_conn(identity)
        |> get("/api/v1/accounts/verify_credentials")
        |> json_response(200)

      assert resp["username"] == "verifyme"
      assert resp["acct"] == "verifyme"
      assert resp["id"] == identity.id
      assert resp["source"]["privacy"] == "public"
      # Every field Mastodon declares non-null has to be present.
      for key <- ~w(display_name note url avatar avatar_static header header_static
                    locked bot created_at followers_count following_count
                    statuses_count emojis fields) do
        assert Map.has_key?(resp, key), "missing #{key}"
        refute is_nil(resp[key]), "#{key} was null"
      end
    end

    test "does not collide with the /accounts/:id route", %{conn: conn} do
      identity = create_user("collide", "collide@example.com")

      # Before the literal route existed this fell through to show/2 and 400'd
      # on the UUID cast.
      conn
      |> auth_conn(identity)
      |> get("/api/v1/accounts/verify_credentials")
      |> json_response(200)
    end
  end

  describe "statuses" do
    test "a timeline status carries Mastodon's field names", %{conn: conn} do
      identity = create_user("poster", "poster@example.com")
      _post = post_for(identity)

      [status | _] =
        conn
        |> mastodon_conn(identity)
        |> get("/api/v1/timelines/public")
        |> json_response(200)

      assert status["content"] =~ "hello world"
      assert status["replies_count"] == 0
      assert status["reblogs_count"] == 0
      assert status["favourites_count"] == 0
      assert status["reblogged"] == false
      assert status["favourited"] == false
      assert Map.has_key?(status, "reblog")
      assert status["account"]["username"] == "poster"
      assert status["visibility"] == "public"
      assert status["media_attachments"] == []
    end

    test "the native shape is untouched without the compat flag", %{conn: conn} do
      identity = create_user("native", "native@example.com")
      _post = post_for(identity)

      [status | _] =
        conn
        |> auth_conn(identity)
        |> get("/api/v1/timelines/public")
        |> json_response(200)

      assert status["reply_count"] == 0
      assert status["boost_count"] == 0
      refute Map.has_key?(status, "replies_count")
      assert status["account"]["handle"] == "native"
    end

    test "posting accepts Mastodon's parameters", %{conn: conn} do
      identity = create_user("mastopost", "mastopost@example.com")

      resp =
        conn
        |> mastodon_conn(identity)
        |> post("/api/v1/statuses", %{
          "status" => "posted from a third-party client",
          "visibility" => "private"
        })
        |> json_response(201)

      assert resp["content"] =~ "posted from a third-party client"
      assert resp["visibility"] == "private"
      assert resp["account"]["username"] == "mastopost"
    end

    test "replying uses in_reply_to_id", %{conn: conn} do
      identity = create_user("replier", "replier@example.com")
      parent = post_for(identity)

      resp =
        conn
        |> mastodon_conn(identity)
        |> post("/api/v1/statuses", %{"status" => "a reply", "in_reply_to_id" => parent.id})
        |> json_response(201)

      assert resp["in_reply_to_id"] == parent.id
    end

    test "favourite and unfavourite answer with the status", %{conn: conn} do
      author = create_user("favauthor", "favauthor@example.com")
      reader = create_user("favreader", "favreader@example.com")
      post = post_for(author)

      favourited =
        conn
        |> mastodon_conn(reader)
        |> post("/api/v1/statuses/#{post.id}/favourite")
        |> json_response(200)

      assert favourited["id"] == post.id
      assert favourited["favourited"] == true
      assert favourited["favourites_count"] == 1

      unfavourited =
        conn
        |> mastodon_conn(reader)
        |> post("/api/v1/statuses/#{post.id}/unfavourite")
        |> json_response(200)

      assert unfavourited["favourited"] == false
      assert unfavourited["favourites_count"] == 0
    end

    test "reblog and unreblog answer with the status", %{conn: conn} do
      author = create_user("rbauthor", "rbauthor@example.com")
      reader = create_user("rbreader", "rbreader@example.com")
      post = post_for(author)

      reblogged =
        conn
        |> mastodon_conn(reader)
        |> post("/api/v1/statuses/#{post.id}/reblog")
        |> json_response(200)

      assert reblogged["reblogs_count"] == 1

      unreblogged =
        conn
        |> mastodon_conn(reader)
        |> post("/api/v1/statuses/#{post.id}/unreblog")
        |> json_response(200)

      assert unreblogged["reblogs_count"] == 0
    end

    test "context comes back as ancestors and descendants", %{conn: conn} do
      identity = create_user("threader", "threader@example.com")
      parent = post_for(identity, "root")

      {:ok, _reply} =
        Posts.create_post(
          identity.id,
          %{"content" => "child", "parent_id" => parent.id},
          identity
        )

      resp =
        conn
        |> mastodon_conn(identity)
        |> get("/api/v1/statuses/#{parent.id}/context")
        |> json_response(200)

      assert resp["ancestors"] == []
      assert [descendant] = resp["descendants"]
      assert descendant["content"] =~ "child"
      assert descendant["account"]["username"] == "threader"
    end
  end

  describe "relationships" do
    test "following answers with a complete relationship", %{conn: conn} do
      follower = create_user("rel_follower", "rel_follower@example.com")
      target = create_user("rel_target", "rel_target@example.com")

      resp =
        conn
        |> mastodon_conn(follower)
        |> post("/api/v1/accounts/#{target.id}/follow")
        |> json_response(200)

      assert resp["id"] == target.id
      assert resp["following"] == true

      for key <- ~w(followed_by requested blocking blocked_by muting
                    muting_notifications showing_reblogs notifying
                    domain_blocking endorsed note) do
        assert Map.has_key?(resp, key), "missing #{key}"
        refute is_nil(resp[key]), "#{key} was null"
      end
    end

    test "unfollowing answers with a complete relationship", %{conn: conn} do
      follower = create_user("unf_follower", "unf_follower@example.com")
      target = create_user("unf_target", "unf_target@example.com")

      conn |> mastodon_conn(follower) |> post("/api/v1/accounts/#{target.id}/follow")

      resp =
        conn
        |> mastodon_conn(follower)
        |> post("/api/v1/accounts/#{target.id}/unfollow")
        |> json_response(200)

      assert resp["following"] == false
      assert resp["showing_reblogs"] == true
    end
  end

  describe "GET /api/v1/notifications" do
    test "is a bare array of Mastodon notifications", %{conn: conn} do
      author = create_user("notifauthor", "notifauthor@example.com")
      actor = create_user("notifactor", "notifactor@example.com")
      post = post_for(author)

      {:ok, _} = Posts.react(post.id, actor.id, "like", [])

      resp =
        conn
        |> mastodon_conn(author)
        |> get("/api/v1/notifications")
        |> json_response(200)

      assert is_list(resp)
      assert [notification | _] = resp
      # Our "reaction" is Mastodon's "favourite".
      assert notification["type"] == "favourite"
      assert notification["account"]["username"] == "notifactor"
      # The embedded status is fully serialized: its account is non-null in
      # Mastodon's model, and the preview shape has no account at all.
      assert notification["status"]["id"] == post.id
      assert notification["status"]["account"]["username"] == "notifauthor"
    end

    test "our own client still gets the paginated envelope", %{conn: conn} do
      identity = create_user("envelope", "envelope@example.com")

      resp =
        conn
        |> auth_conn(identity)
        |> get("/api/v1/notifications")
        |> json_response(200)

      assert Map.has_key?(resp, "data")
      assert Map.has_key?(resp, "next_cursor")
    end
  end

  describe "instance" do
    test "v1 keeps Mastodon's keys", %{conn: conn} do
      resp =
        conn
        |> put_req_header("x-api-compat", "mastodon")
        |> get("/api/v1/instance")
        |> json_response(200)

      assert is_binary(resp["uri"])
      assert is_binary(resp["title"])
      assert is_map(resp["stats"])
      assert is_integer(resp["stats"]["user_count"])
      assert is_map(resp["configuration"]["statuses"])
    end

    test "v2 is served for 4.x clients", %{conn: conn} do
      resp = conn |> get("/api/v2/instance") |> json_response(200)

      assert is_binary(resp["domain"])
      assert is_binary(resp["title"])
      assert is_map(resp["registrations"])
      assert Map.has_key?(resp["registrations"], "enabled")
      assert is_map(resp["contact"])
    end
  end

  describe "search" do
    test "v2 returns accounts, statuses and hashtags", %{conn: conn} do
      identity = create_user("searchme", "searchme@example.com")

      resp =
        conn
        |> mastodon_conn(identity)
        |> get("/api/v2/search", %{"q" => "searchme"})
        |> json_response(200)

      assert is_list(resp["accounts"])
      assert is_list(resp["statuses"])
      assert is_list(resp["hashtags"])
      # `posts` and `groups` are ours; a Mastodon client would choke on the
      # extra keys being the only ones present.
      refute Map.has_key?(resp, "groups")
    end
  end

  describe "shape inference" do
    test "a third-party OAuth token selects Mastodon's shape with no header", %{conn: conn} do
      identity = create_user("inferred", "inferred@example.com")
      token = third_party_token(conn, identity)

      resp =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/accounts/verify_credentials")
        |> json_response(200)

      assert resp["username"] == "inferred"
      refute Map.has_key?(resp, "handle")
    end

    test "a first-party session token keeps the native shape", %{conn: conn} do
      identity = create_user("firstparty", "firstparty@example.com")

      resp =
        conn
        |> auth_conn(identity)
        |> get("/api/v1/accounts/#{identity.id}")
        |> json_response(200)

      assert resp["handle"] == "firstparty"
      refute Map.has_key?(resp, "username")
    end

    test "the header can force the native shape back", %{conn: conn} do
      identity = create_user("forced", "forced@example.com")
      token = third_party_token(conn, identity)

      resp =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("x-api-compat", "native")
        |> get("/api/v1/accounts/#{identity.id}")
        |> json_response(200)

      assert resp["handle"] == "forced"
    end
  end

  # Completes the real authorization-code flow so the resulting token is
  # bound to an application, which is what the inference keys on.
  defp third_party_token(conn, identity) do
    {:ok, app, secret} =
      OAuth.create_application(
        %{
          "client_name" => "Husky",
          "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
          "scopes" => "read write follow push"
        },
        nil
      )

    auth =
      conn
      |> auth_conn(identity)
      |> post("/oauth/authorize", %{
        "response_type" => "code",
        "client_id" => app.client_id,
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
        "scope" => "read write"
      })
      |> json_response(200)

    Phoenix.ConnTest.build_conn()
    |> post("/oauth/token", %{
      "grant_type" => "authorization_code",
      "code" => auth["code"],
      "client_id" => app.client_id,
      "client_secret" => secret,
      "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
  end
end
