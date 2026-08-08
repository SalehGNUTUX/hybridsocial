defmodule HybridsocialWeb.Api.V1.AdminControllerTest do
  use HybridsocialWeb.ConnCase

  alias Hybridsocial.Moderation
  alias Hybridsocial.Auth.RBAC

  # User/admin/moderator factories and the auth_conn/admin_conn helpers
  # come from Hybridsocial.AccountsFixtures (auto-imported by ConnCase).
  # admin_conn/2 also opens the sudo window every admin route requires.

  describe "admin reports" do
    setup %{conn: conn} do
      admin = create_user("admin1", "admin1@test.com") |> make_admin()
      user = create_user("user1", "user1@test.com")
      reported = create_user("reported1", "reported1@test.com")

      {:ok, report} =
        Moderation.create_report(user.id, %{
          "reported_id" => reported.id,
          "category" => "spam",
          "description" => "Test report"
        })

      %{
        conn: admin_conn(conn, admin),
        admin: admin,
        user: user,
        reported: reported,
        report: report
      }
    end

    test "GET /api/v1/admin/reports lists reports", %{conn: conn} do
      conn = get(conn, "/api/v1/admin/reports")
      assert %{"data" => data} = json_response(conn, 200)
      assert length(data) == 1
    end

    test "GET /api/v1/admin/reports/:id shows a report", %{conn: conn, report: report} do
      conn = get(conn, "/api/v1/admin/reports/#{report.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == report.id
    end

    test "POST /api/v1/admin/reports/:id/resolve resolves report", %{conn: conn, report: report} do
      conn =
        post(conn, "/api/v1/admin/reports/#{report.id}/resolve", %{"action_taken" => "warned"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "resolved"
      assert data["action_taken"] == "warned"
    end

    test "POST /api/v1/admin/reports/:id/assign assigns report", %{
      conn: conn,
      report: report,
      admin: admin
    } do
      conn = post(conn, "/api/v1/admin/reports/#{report.id}/assign", %{})
      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "investigating"
      assert data["assigned_to"] == admin.id
    end
  end

  describe "moderator access" do
    setup %{conn: conn} do
      moderator = create_user("mod1", "mod1@test.com") |> make_moderator()
      user = create_user("user2", "user2@test.com")
      reported = create_user("reported2", "reported2@test.com")

      {:ok, report} =
        Moderation.create_report(user.id, %{
          "reported_id" => reported.id,
          "category" => "spam",
          "description" => "Test report"
        })

      %{conn: admin_conn(conn, moderator), moderator: moderator, report: report}
    end

    test "moderator can view reports", %{conn: conn} do
      conn = get(conn, "/api/v1/admin/reports")
      assert %{"data" => _} = json_response(conn, 200)
    end

    test "moderator can view audit log", %{conn: conn, moderator: moderator} do
      Moderation.log(moderator.id, "test.action", nil, nil, %{})
      conn = get(conn, "/api/v1/admin/audit_log")
      assert %{"data" => _} = json_response(conn, 200)
    end

    test "moderator cannot manage federation", %{conn: conn} do
      conn = get(conn, "/api/v1/admin/banned_domains")
      assert json_response(conn, 403)["error"] == "permission.denied"
    end

    test "moderator cannot manage relays", %{conn: conn} do
      conn = get(conn, "/api/v1/admin/relays")
      assert json_response(conn, 403)["error"] == "permission.denied"
    end
  end

  describe "admin audit log" do
    setup %{conn: conn} do
      admin = create_user("admin2", "admin2@test.com") |> make_admin()
      Moderation.log(admin.id, "test.action", nil, nil, %{})

      %{conn: admin_conn(conn, admin), admin: admin}
    end

    test "GET /api/v1/admin/audit_log lists entries", %{conn: conn} do
      conn = get(conn, "/api/v1/admin/audit_log")
      assert %{"data" => data} = json_response(conn, 200)
      assert length(data) >= 1
    end
  end

  describe "admin accounts" do
    setup %{conn: conn} do
      admin = create_user("admin3", "admin3@test.com") |> make_admin()
      user = create_user("target1", "target1@test.com")

      %{conn: admin_conn(conn, admin), admin: admin, user: user}
    end

    test "GET /api/v1/admin/accounts lists accounts", %{conn: conn} do
      conn = get(conn, "/api/v1/admin/accounts")
      assert %{"data" => data} = json_response(conn, 200)
      assert length(data) >= 2
    end

    test "POST /api/v1/admin/accounts/:id/action suspends user", %{conn: conn, user: user} do
      conn = post(conn, "/api/v1/admin/accounts/#{user.id}/action", %{"action" => "suspend"})
      assert %{"data" => data} = json_response(conn, 200)
      assert data["is_suspended"] == true
    end

    test "POST /api/v1/admin/accounts/:id/action unsuspends user", %{conn: conn, user: user} do
      # First suspend
      post(conn, "/api/v1/admin/accounts/#{user.id}/action", %{"action" => "suspend"})
      # Then unsuspend
      conn = post(conn, "/api/v1/admin/accounts/#{user.id}/action", %{"action" => "unsuspend"})
      assert %{"data" => data} = json_response(conn, 200)
      assert data["is_suspended"] == false
    end

    test "POST /api/v1/admin/accounts/:id/action warns user", %{conn: conn, user: user} do
      conn =
        post(conn, "/api/v1/admin/accounts/#{user.id}/action", %{
          "action" => "warn",
          "reason" => "Violation"
        })

      assert %{"data" => _data, "message" => "account.warned"} = json_response(conn, 200)
    end

    test "PUT /api/v1/admin/users/:id/profile clears avatar and header", %{conn: conn, user: user} do
      # Give the user an avatar + header, then null them via the endpoint.
      {:ok, _} =
        Hybridsocial.Accounts.admin_update_identity(user, %{
          "avatar_url" => "https://cdn.example/a.png",
          "header_url" => "https://cdn.example/h.png"
        })

      conn =
        put(conn, "/api/v1/admin/users/#{user.id}/profile", %{
          "avatar_url" => nil,
          "header_url" => nil
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["avatar_url"] == nil
      assert data["header_url"] == nil

      reloaded = Hybridsocial.Accounts.get_identity(user.id)
      assert reloaded.avatar_url == nil
      assert reloaded.header_url == nil
    end
  end

  describe "admin content filters" do
    setup %{conn: conn} do
      admin = create_user("admin4", "admin4@test.com") |> make_admin()

      %{conn: admin_conn(conn, admin), admin: admin}
    end

    test "POST /api/v1/admin/content_filters creates a filter", %{conn: conn} do
      params = %{"type" => "word", "pattern" => "badword", "action" => "reject"}
      conn = post(conn, "/api/v1/admin/content_filters", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["pattern"] == "badword"
    end

    test "GET /api/v1/admin/content_filters lists filters", %{conn: conn} do
      Moderation.create_filter(%{"type" => "word", "pattern" => "bad", "action" => "reject"})

      conn = get(conn, "/api/v1/admin/content_filters")
      assert %{"data" => data} = json_response(conn, 200)
      assert length(data) == 1
    end

    test "DELETE /api/v1/admin/content_filters/:id deletes a filter", %{conn: conn} do
      {:ok, filter} =
        Moderation.create_filter(%{"type" => "word", "pattern" => "bad", "action" => "reject"})

      conn = delete(conn, "/api/v1/admin/content_filters/#{filter.id}")
      assert json_response(conn, 200)["message"] == "filter.deleted"
    end
  end

  describe "admin banned domains" do
    setup %{conn: conn} do
      admin = create_user("admin5", "admin5@test.com") |> make_admin()

      %{conn: admin_conn(conn, admin), admin: admin}
    end

    test "POST /api/v1/admin/banned_domains bans a domain", %{conn: conn} do
      params = %{"domain" => "spam.com", "type" => "email", "reason" => "Spam"}
      conn = post(conn, "/api/v1/admin/banned_domains", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["domain"] == "spam.com"
    end

    test "GET /api/v1/admin/banned_domains lists banned domains", %{conn: conn, admin: admin} do
      Moderation.ban_domain("spam.com", "email", "reason", admin.id)

      conn = get(conn, "/api/v1/admin/banned_domains")
      assert %{"data" => data} = json_response(conn, 200)
      assert length(data) == 1
    end

    test "DELETE /api/v1/admin/banned_domains/:domain unbans a domain", %{
      conn: conn,
      admin: admin
    } do
      Moderation.ban_domain("spam.com", "email", "reason", admin.id)

      conn = delete(conn, "/api/v1/admin/banned_domains/spam.com")
      assert json_response(conn, 200)["message"] == "domain.unbanned"
    end
  end

  describe "non-admin access" do
    test "returns 403 for non-admin users", %{conn: conn} do
      user = create_user("regular1", "regular1@test.com")
      conn = admin_conn(conn, user)

      conn = get(conn, "/api/v1/admin/reports")
      assert json_response(conn, 403)["error"] == "auth.forbidden"
    end

    test "returns 401 for unauthenticated users", %{conn: conn} do
      conn = get(conn, "/api/v1/admin/reports")
      assert json_response(conn, 401)["error"] == "auth.unauthorized"
    end
  end

  describe "federation dead letters + delivery kill switch" do
    setup %{conn: conn} do
      admin = create_user("fedadmin", "fedadmin@test.com") |> make_admin()

      for _ <- 1..3 do
        %Hybridsocial.Federation.Delivery{}
        |> Hybridsocial.Federation.Delivery.changeset(%{
          activity_id: "https://local.test/activities/#{System.unique_integer([:positive])}",
          activity_type: "Create",
          target_inbox: "https://gone.example/users/x/inbox",
          status: "failed"
        })
        |> Hybridsocial.Repo.insert!()
      end

      %{conn: admin_conn(conn, admin)}
    end

    test "GET dead_letters reports whole-queue counts per domain", %{conn: conn} do
      conn = get(conn, "/api/v1/admin/federation/dead_letters")
      assert %{"total" => 3, "by_domain" => by_domain} = json_response(conn, 200)
      assert [%{"domain" => "gone.example", "count" => 3}] = by_domain
    end

    test "POST dead_letters/drop_domain clears the whole domain", %{conn: conn} do
      conn =
        post(conn, "/api/v1/admin/federation/dead_letters/drop_domain", %{domain: "gone.example"})

      assert %{"dropped" => 3} = json_response(conn, 200)
      assert Hybridsocial.Repo.aggregate(Hybridsocial.Federation.Delivery, :count) == 0
    end

    test "disabling delivery drops the queue and blocks further attempts", %{conn: conn} do
      conn =
        post(conn, "/api/v1/admin/federation/delivery_disabled", %{
          domain: "gone.example",
          reason: "instance shut down",
          drop_dead_letters: true
        })

      assert %{"delivery_disabled" => true, "dropped" => 3} = json_response(conn, 200)
      refute Hybridsocial.Federation.CircuitBreaker.allow?("https://gone.example/users/x/inbox")
      assert Hybridsocial.Repo.aggregate(Hybridsocial.Federation.Delivery, :count) == 0
    end

    test "the disabled list round-trips through enable", %{conn: conn} do
      post(conn, "/api/v1/admin/federation/delivery_disabled", %{domain: "gone.example"})

      conn2 = get(conn, "/api/v1/admin/federation/delivery_disabled")
      assert %{"data" => [%{"domain" => "gone.example"}]} = json_response(conn2, 200)

      conn3 = delete(conn, "/api/v1/admin/federation/delivery_disabled/gone.example")
      assert %{"delivery_disabled" => false} = json_response(conn3, 200)
      assert Hybridsocial.Federation.CircuitBreaker.allow?("https://gone.example/users/x/inbox")
    end

    test "a non-admin cannot stop delivery", %{conn: _conn} do
      user = create_user("fednobody", "fednobody@test.com")

      conn =
        build_conn()
        |> auth_conn(user)
        |> post("/api/v1/admin/federation/delivery_disabled", %{domain: "gone.example"})

      assert json_response(conn, 403)
      refute Hybridsocial.Federation.CircuitBreaker.delivery_disabled?("gone.example")
    end
  end

  describe "permission-based access control" do
    test "community_manager cannot access reports", %{conn: conn} do
      cm = create_user("cm1", "cm1@test.com")
      {:ok, _} = RBAC.assign_role(cm.id, "community_manager", cm.id)
      enable_otp(cm)
      conn = admin_conn(conn, cm)

      conn = get(conn, "/api/v1/admin/reports")
      assert json_response(conn, 403)["error"] == "permission.denied"
    end

    test "community_manager can access content filters", %{conn: conn} do
      cm = create_user("cm2", "cm2@test.com")
      {:ok, _} = RBAC.assign_role(cm.id, "community_manager", cm.id)
      enable_otp(cm)
      conn = admin_conn(conn, cm)

      conn = get(conn, "/api/v1/admin/content_filters")
      assert %{"data" => _} = json_response(conn, 200)
    end
  end

  describe "admin account content (issue #166)" do
    setup %{conn: conn} do
      admin = create_user("adm_content", "adm_content@test.com") |> make_admin()
      user = create_user("usr_content", "usr_content@test.com")
      %{conn: admin_conn(conn, admin), user: user}
    end

    defp mk(identity, attrs) do
      {:ok, post} =
        Hybridsocial.Social.Posts.create_post(
          identity.id,
          Map.merge(%{"content" => "x", "visibility" => "public"}, attrs)
        )

      post
    end

    test "counts split posts, replies and media", %{conn: conn, user: user} do
      parent = mk(user, %{"content" => "top level"})
      mk(user, %{"content" => "another top level"})
      mk(user, %{"content" => "a reply", "parent_id" => parent.id})

      with_media = mk(user, %{"content" => "has media"})

      Hybridsocial.Repo.insert!(%Hybridsocial.Media.MediaFile{
        identity_id: user.id,
        post_id: with_media.id,
        content_type: "image/png",
        file_size: 1_000,
        storage_path: "test/#{with_media.id}.png",
        width: 800,
        height: 600
      })

      body = json_response(get(conn, "/api/v1/admin/users/#{user.id}"), 200)

      assert body["post_count"] == 3
      assert body["reply_count"] == 1
      assert body["media_count"] == 1
    end

    test "statuses tabs return posts, replies and media separately", %{conn: conn, user: user} do
      parent = mk(user, %{"content" => "top level"})
      reply = mk(user, %{"content" => "a reply", "parent_id" => parent.id})

      posts = json_response(get(conn, "/api/v1/admin/users/#{user.id}/statuses?type=posts"), 200)
      ids = Enum.map(posts, & &1["id"])
      assert parent.id in ids
      refute reply.id in ids

      replies =
        json_response(get(conn, "/api/v1/admin/users/#{user.id}/statuses?type=replies"), 200)

      reply_ids = Enum.map(replies, & &1["id"])
      assert reply.id in reply_ids
      refute parent.id in reply_ids
    end

    test "NEVER exposes direct-visibility statuses (those are DMs)", %{conn: conn, user: user} do
      public_post = mk(user, %{"content" => "public"})
      dm = mk(user, %{"content" => "a private message", "visibility" => "direct"})

      for type <- ["posts", "replies", "media", "anything"] do
        body =
          json_response(get(conn, "/api/v1/admin/users/#{user.id}/statuses?type=#{type}"), 200)

        refute dm.id in Enum.map(body, & &1["id"]),
               "direct-visibility status leaked into the #{type} tab"
      end

      assert public_post.id in Enum.map(
               json_response(get(conn, "/api/v1/admin/users/#{user.id}/statuses"), 200),
               & &1["id"]
             )

      # ...and the counts don't include it either.
      detail = json_response(get(conn, "/api/v1/admin/users/#{user.id}"), 200)
      assert detail["post_count"] == 1
    end

    test "requires the users.view permission", %{user: user} do
      stranger = create_user("nosy", "nosy@test.com")

      conn =
        auth_conn(Phoenix.ConnTest.build_conn(), stranger)
        |> get("/api/v1/admin/users/#{user.id}/statuses")

      assert conn.status in [401, 403]
    end
  end
end
