defmodule HybridsocialWeb.Api.V1.OAuthControllerTest do
  use HybridsocialWeb.ConnCase, async: true

  alias Hybridsocial.Auth
  alias Hybridsocial.Auth.OAuth

  defp create_user_and_login(conn) do
    identity = create_user("oauthtestuser", "oauthtest@example.com")
    {:ok, tokens} = Auth.login("oauthtest@example.com", "password1234567890")

    authed_conn =
      conn
      |> put_req_header("authorization", "Bearer #{tokens.access_token}")

    {identity, authed_conn, tokens}
  end

  defp create_app(identity_id, attrs \\ %{}) do
    {:ok, app, secret} =
      OAuth.create_application(
        Map.merge(
          %{
            "name" => "Test App",
            "redirect_uris" => ["https://example.com/callback"],
            "scopes" => ["read", "write"]
          },
          attrs
        ),
        identity_id
      )

    {app, secret}
  end

  defp generate_pkce do
    code_verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    code_challenge =
      :crypto.hash(:sha256, code_verifier)
      |> Base.url_encode64(padding: false)

    {code_verifier, code_challenge}
  end

  describe "POST /api/v1/apps" do
    test "creates an app when authenticated", %{conn: conn} do
      {_identity, authed_conn, _tokens} = create_user_and_login(conn)

      resp =
        authed_conn
        |> post("/api/v1/apps", %{
          "name" => "My Cool App",
          "redirect_uris" => ["https://myapp.com/callback"],
          "website" => "https://myapp.com"
        })
        |> json_response(200)

      assert resp["name"] == "My Cool App"
      assert resp["client_id"] != nil
      assert resp["client_secret"] != nil
      assert resp["redirect_uris"] == ["https://myapp.com/callback"]
    end

    # A third-party client has no user at the point it registers, so this
    # endpoint has to work unauthenticated or the handshake can never start.
    test "registers an app with no session, in the Mastodon param shape", %{conn: conn} do
      resp =
        conn
        |> post("/api/v1/apps", %{
          "client_name" => "Husky",
          "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
          "scopes" => "read write follow push"
        })
        |> json_response(200)

      assert resp["name"] == "Husky"
      assert resp["client_id"] != nil
      assert resp["client_secret"] != nil
      # Singular `redirect_uri` is what older clients read.
      assert resp["redirect_uri"] == "urn:ietf:wg:oauth:2.0:oob"
      assert resp["scopes"] == ["read", "write", "follow", "push"]
      assert Map.has_key?(resp, "vapid_key")
    end

    test "accepts a native custom-scheme callback", %{conn: conn} do
      resp =
        conn
        |> post("/api/v1/apps", %{
          "client_name" => "Tusky",
          "redirect_uris" => "tusky://oauth",
          "scopes" => "read"
        })
        |> json_response(200)

      assert resp["redirect_uris"] == ["tusky://oauth"]
    end

    test "rejects a script-executing callback", %{conn: conn} do
      resp =
        conn
        |> post("/api/v1/apps", %{
          "client_name" => "Bad App",
          "redirect_uris" => "javascript:alert(1)"
        })
        |> json_response(422)

      assert resp["error"] == "validation.failed"
    end

    test "rejects an unknown scope", %{conn: conn} do
      resp =
        conn
        |> post("/api/v1/apps", %{"client_name" => "App", "scopes" => "read wildcard"})
        |> json_response(422)

      assert resp["error"] == "validation.failed"
    end

    test "defaults to the out-of-band callback when none is given", %{conn: conn} do
      resp =
        conn
        |> post("/api/v1/apps", %{"client_name" => "CLI tool"})
        |> json_response(200)

      assert resp["redirect_uris"] == ["urn:ietf:wg:oauth:2.0:oob"]
    end
  end

  describe "GET /api/v1/apps/info" do
    test "returns public metadata for the consent screen", %{conn: conn} do
      identity = create_user("infouser", "info@example.com")
      {app, _secret} = create_app(identity.id)

      resp =
        conn
        |> get("/api/v1/apps/info", %{"client_id" => app.client_id})
        |> json_response(200)

      assert resp["name"] == "Test App"
      assert resp["scopes"] == ["read", "write"]
      refute Map.has_key?(resp, "client_secret")
    end

    test "404s for an unknown client_id", %{conn: conn} do
      conn
      |> get("/api/v1/apps/info", %{"client_id" => "nope"})
      |> json_response(404)
    end
  end

  describe "GET /oauth/authorize" do
    test "redirects a browser to the web consent screen", %{conn: conn} do
      identity = create_user("browseruser", "browser@example.com")
      {app, _secret} = create_app(identity.id)

      conn =
        get(conn, "/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback",
          "scope" => "read write",
          "state" => "xyz"
        })

      assert conn.status == 302
      location = hd(get_resp_header(conn, "location"))
      assert location =~ "/authorize?"
      assert location =~ "client_id=#{URI.encode_www_form(app.client_id)}"
      assert location =~ "state=xyz"
    end

    # Bouncing an error to an unverified callback would be the open redirect
    # the redirect_uri check exists to prevent.
    test "does not redirect when the callback is not registered", %{conn: conn} do
      identity = create_user("evaluser", "eval@example.com")
      {app, _secret} = create_app(identity.id)

      conn =
        get(conn, "/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://evil.example/callback"
        })

      assert conn.status == 400
      assert get_resp_header(conn, "location") == []
    end

    test "does not redirect for an unknown client_id", %{conn: conn} do
      conn =
        get(conn, "/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => "unknown",
          "redirect_uri" => "https://evil.example/callback"
        })

      assert conn.status == 400
      assert get_resp_header(conn, "location") == []
    end

    test "reports an unsupported response_type back to the registered callback", %{conn: conn} do
      identity = create_user("rtypeuser", "rtype@example.com")
      {app, _secret} = create_app(identity.id)

      conn =
        get(conn, "/oauth/authorize", %{
          "response_type" => "token",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback",
          "state" => "abc"
        })

      assert conn.status == 302
      location = hd(get_resp_header(conn, "location"))
      assert location =~ "https://example.com/callback?"
      assert location =~ "error=unsupported_response_type"
      assert location =~ "state=abc"
    end
  end

  describe "GET /api/v1/apps" do
    test "lists own apps", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {_app, _secret} = create_app(identity.id)

      resp =
        authed_conn
        |> get("/api/v1/apps")
        |> json_response(200)

      assert length(resp) == 1
      assert hd(resp)["name"] == "Test App"
      # client_secret should NOT be in listing
      refute Map.has_key?(hd(resp), "client_secret")
    end
  end

  describe "DELETE /api/v1/apps/:id" do
    test "deletes own app", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, _secret} = create_app(identity.id)

      resp =
        authed_conn
        |> delete("/api/v1/apps/#{app.id}")
        |> json_response(200)

      assert resp["message"] == "oauth.app_deleted"
    end

    test "returns 404 for nonexistent app", %{conn: conn} do
      {_identity, authed_conn, _tokens} = create_user_and_login(conn)

      authed_conn
      |> delete("/api/v1/apps/#{Ecto.UUID.generate()}")
      |> json_response(404)
    end
  end

  describe "POST /oauth/authorize" do
    test "creates authorization code with PKCE", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, _secret} = create_app(identity.id)
      {_code_verifier, code_challenge} = generate_pkce()

      resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback",
          "scope" => "read write",
          "code_challenge" => code_challenge
        })
        |> json_response(200)

      assert resp["code"] != nil
      assert resp["redirect_uri"] == "https://example.com/callback"
    end

    test "rejects invalid response_type", %{conn: conn} do
      {_identity, authed_conn, _tokens} = create_user_and_login(conn)

      resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "token",
          "client_id" => "something",
          "redirect_uri" => "https://example.com/callback",
          "code_challenge" => "challenge"
        })
        |> json_response(400)

      assert resp["error"] == "oauth.unsupported_response_type"
    end

    # Confidential clients (every Mastodon client) send no challenge; they
    # authenticate with client_secret at the token endpoint instead.
    test "issues a code without PKCE", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, _secret} = create_app(identity.id)

      resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      assert resp["code"] != nil
    end

    test "narrows requested scopes to what the app registered", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, _secret} = create_app(identity.id, %{"scopes" => ["read"]})

      resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback",
          "scope" => "read write follow"
        })
        |> json_response(200)

      assert resp["scope"] == "read"
    end

    test "rejects invalid redirect_uri", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, _secret} = create_app(identity.id)
      {_code_verifier, code_challenge} = generate_pkce()

      resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://evil.com/callback",
          "code_challenge" => code_challenge
        })
        |> json_response(400)

      assert resp["error"] == "oauth.invalid_redirect_uri"
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn
      |> post("/oauth/authorize", %{})
      |> json_response(401)
    end
  end

  describe "POST /oauth/token" do
    test "exchanges code for tokens with valid PKCE", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, _secret} = create_app(identity.id)
      {code_verifier, code_challenge} = generate_pkce()

      # Get authorization code
      auth_resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback",
          "scope" => "read write",
          "code_challenge" => code_challenge
        })
        |> json_response(200)

      # Exchange code for tokens (public endpoint)
      token_resp =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => auth_resp["code"],
          "code_verifier" => code_verifier,
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      assert token_resp["access_token"] != nil
      assert token_resp["refresh_token"] != nil
      assert token_resp["token_type"] == "Bearer"
      assert token_resp["expires_in"] > 0
    end

    test "rejects invalid code_verifier", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, _secret} = create_app(identity.id)
      {_code_verifier, code_challenge} = generate_pkce()

      auth_resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback",
          "scope" => "read",
          "code_challenge" => code_challenge
        })
        |> json_response(200)

      resp =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => auth_resp["code"],
          "code_verifier" => "wrong_verifier",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(400)

      assert resp["error"] == "invalid_code_verifier"
    end

    test "rejects unsupported grant_type", %{conn: conn} do
      resp =
        conn
        |> post("/oauth/token", %{"grant_type" => "password"})
        |> json_response(400)

      assert resp["error"] == "unsupported_grant_type"
    end

    test "exchanges a challenge-less code for tokens with the client secret", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, secret} = create_app(identity.id)

      auth_resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback",
          "scope" => "read write"
        })
        |> json_response(200)

      token_resp =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => auth_resp["code"],
          "client_id" => app.client_id,
          "client_secret" => secret,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      assert token_resp["access_token"] != nil
      assert token_resp["created_at"] > 0
      # Third-party tokens outlive the 15-minute first-party session token,
      # because Mastodon clients never call the refresh grant.
      assert token_resp["expires_in"] > 15 * 60
    end

    test "accepts client credentials via HTTP Basic", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, secret} = create_app(identity.id)

      auth_resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      basic = Base.encode64("#{app.client_id}:#{secret}")

      token_resp =
        conn
        |> put_req_header("authorization", "Basic #{basic}")
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => auth_resp["code"],
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      assert token_resp["access_token"] != nil
    end

    # Without this, dropping the code_challenge would be a way to downgrade
    # out of PKCE and redeem an intercepted code with no proof at all.
    test "refuses a challenge-less code when the client secret is wrong", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, _secret} = create_app(identity.id)

      auth_resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      resp =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => auth_resp["code"],
          "client_id" => app.client_id,
          "client_secret" => "not-the-secret",
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(401)

      assert resp["error"] == "invalid_client"
    end

    test "refuses a challenge-less code with no client secret at all", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, _secret} = create_app(identity.id)

      auth_resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      conn
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => auth_resp["code"],
        "client_id" => app.client_id,
        "redirect_uri" => "https://example.com/callback"
      })
      |> json_response(401)
    end

    test "rotates a refresh token", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, secret} = create_app(identity.id)

      auth_resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      first =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => auth_resp["code"],
          "client_id" => app.client_id,
          "client_secret" => secret,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      second =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first["refresh_token"],
          "client_id" => app.client_id,
          "client_secret" => secret
        })
        |> json_response(200)

      assert second["access_token"] != first["access_token"]

      # The spent refresh token is dead.
      conn
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => first["refresh_token"],
        "client_id" => app.client_id,
        "client_secret" => secret
      })
      |> json_response(400)
    end

    test "refuses the refresh grant without client authentication", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, secret} = create_app(identity.id)

      auth_resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      first =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => auth_resp["code"],
          "client_id" => app.client_id,
          "client_secret" => secret,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      conn
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => first["refresh_token"],
        "client_id" => app.client_id
      })
      |> json_response(401)
    end
  end

  # The consent screen names the scopes a client asked for; if nothing
  # enforced them it would be describing access the token doesn't actually
  # have limits on.
  describe "granted scopes" do
    defp token_for_scopes(conn, identity, scopes) do
      {app, secret} = create_app(identity.id, %{"scopes" => scopes})

      {:ok, tokens} = Auth.login("scopeuser@example.com", "password1234567890")

      auth_resp =
        conn
        |> put_req_header("authorization", "Bearer #{tokens.access_token}")
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback",
          "scope" => Enum.join(scopes, " ")
        })
        |> json_response(200)

      Phoenix.ConnTest.build_conn()
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => auth_resp["code"],
        "client_id" => app.client_id,
        "client_secret" => secret,
        "redirect_uri" => "https://example.com/callback"
      })
      |> json_response(200)
      |> Map.fetch!("access_token")
    end

    test "a read-only token can read but not write", %{conn: conn} do
      identity = create_user("scopeuser", "scopeuser@example.com")
      token = token_for_scopes(conn, identity, ["read"])

      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/notifications")
      |> json_response(200)

      resp =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/statuses", %{"content" => "should not post"})
        |> json_response(403)

      assert resp["error"] == "oauth.insufficient_scope"
    end

    test "a write token can write", %{conn: conn} do
      identity = create_user("scopeuser", "scopeuser@example.com")
      token = token_for_scopes(conn, identity, ["read", "write"])

      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/statuses", %{"content" => "hello from a scoped token"})
      |> json_response(201)
    end

    test "a non-admin token cannot reach the admin API", %{conn: conn} do
      identity = create_user("scopeuser", "scopeuser@example.com")
      token = token_for_scopes(conn, identity, ["read", "write"])

      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/admin/sudo")
      |> json_response(403)
    end
  end

  describe "POST /oauth/revoke" do
    test "revokes a token", %{conn: conn} do
      {identity, authed_conn, _tokens} = create_user_and_login(conn)
      {app, _secret} = create_app(identity.id)
      {code_verifier, code_challenge} = generate_pkce()

      auth_resp =
        authed_conn
        |> post("/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback",
          "scope" => "read",
          "code_challenge" => code_challenge
        })
        |> json_response(200)

      token_resp =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => auth_resp["code"],
          "code_verifier" => code_verifier,
          "client_id" => app.client_id,
          "redirect_uri" => "https://example.com/callback"
        })
        |> json_response(200)

      # Revoke the access token
      resp =
        conn
        |> post("/oauth/revoke", %{"token" => token_resp["access_token"]})
        |> json_response(200)

      assert resp == %{}
    end

    test "returns 200 even for nonexistent token (RFC 7009)", %{conn: conn} do
      resp =
        conn
        |> post("/oauth/revoke", %{"token" => "nonexistent_token"})
        |> json_response(200)

      assert resp == %{}
    end

    test "returns error when token param missing", %{conn: conn} do
      resp =
        conn
        |> post("/oauth/revoke", %{})
        |> json_response(400)

      assert resp["error"] == "oauth.token_required"
    end
  end
end
