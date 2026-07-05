defmodule HybridsocialWeb.Api.V1.RecoveryControllerTest do
  use HybridsocialWeb.ConnCase, async: true

  alias Hybridsocial.Accounts
  alias Hybridsocial.Accounts.User
  alias Hybridsocial.Repo

  defp register(handle) do
    uniq = :erlang.unique_integer([:positive])
    email = "#{handle}_#{uniq}@test.com"
    identity = create_user("#{handle}_#{uniq}", email)
    {identity, email}
  end

  defp enable_2fa(identity) do
    user = Repo.get_by!(User, identity_id: identity.id)
    raw_secret = NimbleTOTP.secret()
    encoded = Base.encode32(raw_secret, padding: false)

    {:ok, _user} =
      user
      |> Ecto.Changeset.change(otp_secret: encoded, otp_enabled: true)
      |> Repo.update()

    raw_secret
  end

  defp totp_code(secret), do: NimbleTOTP.verification_code(secret)

  describe "POST /api/v1/accounts/recovery_code" do
    test "authenticated user with 2FA enabled can generate a code", %{conn: conn} do
      {identity, _email} = register("api_gen")
      enable_2fa(identity)

      conn =
        conn
        |> auth_conn(identity)
        |> post("/api/v1/accounts/recovery_code", %{"password" => "password1234567890"})

      body = json_response(conn, 200)
      assert is_binary(body["recovery_code"])
      assert String.length(body["recovery_code"]) == 23
      assert body["warning"] =~ "cannot be recovered"
    end

    test "rejects with 403 when 2FA is not enabled", %{conn: conn} do
      {identity, _email} = register("api_no2fa")

      conn =
        conn
        |> auth_conn(identity)
        |> post("/api/v1/accounts/recovery_code", %{"password" => "password1234567890"})

      body = json_response(conn, 403)
      assert body["error"] == "recovery.two_factor_required"
      assert body["message"] =~ "Two-factor"
    end

    test "wrong password is rejected with 403", %{conn: conn} do
      {identity, _email} = register("api_g_wrong")
      enable_2fa(identity)

      conn =
        conn
        |> auth_conn(identity)
        |> post("/api/v1/accounts/recovery_code", %{"password" => "wrong"})

      assert json_response(conn, 403)["error"] == "auth.invalid_password"
    end
  end

  describe "GET /api/v1/accounts/recovery_code" do
    test "reports whether a code is set (no plaintext ever leaks)", %{conn: conn} do
      {identity, _email} = register("api_status")
      enable_2fa(identity)

      conn1 = conn |> auth_conn(identity) |> get("/api/v1/accounts/recovery_code")

      assert json_response(conn1, 200) == %{
               "enabled" => false,
               "generated_at" => nil,
               "last_used_at" => nil
             }

      {:ok, _, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      conn2 = build_conn() |> auth_conn(identity) |> get("/api/v1/accounts/recovery_code")
      response = json_response(conn2, 200)
      assert response["enabled"] == true
      refute Map.has_key?(response, "recovery_code")
    end
  end

  describe "POST /api/v1/auth/recover/validate (step 1)" do
    test "issues a signed recovery_token on success", %{conn: conn} do
      {identity, current_email} = register("rv_ok")
      secret = enable_2fa(identity)
      {:ok, code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      conn =
        post(conn, "/api/v1/auth/recover/validate", %{
          "handle" => identity.handle,
          "recovery_code" => code,
          "otp_code" => totp_code(secret),
          "current_email" => current_email
        })

      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert is_binary(body["recovery_token"])
      assert body["expires_in"] == 600
    end

    test "wrong code returns 401 with generic message", %{conn: conn} do
      {identity, current_email} = register("rv_wc")
      secret = enable_2fa(identity)
      {:ok, _code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      conn =
        post(conn, "/api/v1/auth/recover/validate", %{
          "handle" => identity.handle,
          "recovery_code" => "A2345-B2345-C2345-D2345",
          "otp_code" => totp_code(secret),
          "current_email" => current_email
        })

      assert json_response(conn, 401)["error"] == "auth.invalid_recovery"
    end

    test "wrong OTP returns 401 with generic message", %{conn: conn} do
      {identity, current_email} = register("rv_wo")
      enable_2fa(identity)
      {:ok, code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      conn =
        post(conn, "/api/v1/auth/recover/validate", %{
          "handle" => identity.handle,
          "recovery_code" => code,
          "otp_code" => "000000",
          "current_email" => current_email
        })

      assert json_response(conn, 401)["error"] == "auth.invalid_recovery"
    end

    test "wrong current email returns 401 with generic message", %{conn: conn} do
      {identity, _email} = register("rv_we")
      secret = enable_2fa(identity)
      {:ok, code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      conn =
        post(conn, "/api/v1/auth/recover/validate", %{
          "handle" => identity.handle,
          "recovery_code" => code,
          "otp_code" => totp_code(secret),
          "current_email" => "not-the-real@test.com"
        })

      assert json_response(conn, 401)["error"] == "auth.invalid_recovery"
    end

    test "unknown handle returns 401 (not 404)", %{conn: conn} do
      conn =
        post(conn, "/api/v1/auth/recover/validate", %{
          "handle" => "totally-not-real",
          "recovery_code" => "A2345-B2345-C2345-D2345",
          "otp_code" => "123456",
          "current_email" => "ghost@test.com"
        })

      assert json_response(conn, 401)["error"] == "auth.invalid_recovery"
    end

    test "missing params return 400", %{conn: conn} do
      conn = post(conn, "/api/v1/auth/recover/validate", %{"handle" => "x"})
      body = json_response(conn, 400)
      assert body["error"] == "validation.failed"
      assert "recovery_code" in body["required"]
      assert "otp_code" in body["required"]
      assert "current_email" in body["required"]
    end
  end

  describe "POST /api/v1/auth/recover/complete (step 2)" do
    defp validate_and_get_token(conn, identity, current_email, code, secret) do
      post_conn =
        post(conn, "/api/v1/auth/recover/validate", %{
          "handle" => identity.handle,
          "recovery_code" => code,
          "otp_code" => totp_code(secret),
          "current_email" => current_email
        })

      json_response(post_conn, 200)["recovery_token"]
    end

    test "applies password + email reset and issues new code", %{conn: conn} do
      {identity, current_email} = register("rc_ok")
      secret = enable_2fa(identity)
      {:ok, code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")
      token = validate_and_get_token(conn, identity, current_email, code, secret)

      uniq = :erlang.unique_integer([:positive])
      new_email = "rc_ok_#{uniq}_new@test.com"

      complete =
        post(build_conn(), "/api/v1/auth/recover/complete", %{
          "recovery_token" => token,
          "new_email" => new_email,
          "new_password" => "newpass1234567890xy",
          "new_password_confirmation" => "newpass1234567890xy"
        })

      body = json_response(complete, 200)
      assert body["status"] == "ok"
      assert is_binary(body["new_recovery_code"])
      refute body["new_recovery_code"] == code

      user = Repo.get_by!(User, identity_id: identity.id)
      assert user.email == new_email
      assert user.confirmed_at != nil
    end

    test "rejects invalid token with 401", %{conn: conn} do
      conn =
        post(conn, "/api/v1/auth/recover/complete", %{
          "recovery_token" => "not-a-valid-token",
          "new_email" => "x@test.com",
          "new_password" => "newpass1234567890xy",
          "new_password_confirmation" => "newpass1234567890xy"
        })

      assert json_response(conn, 401)["error"] == "recovery.token_invalid"
    end

    test "rejects missing params with 400", %{conn: conn} do
      conn = post(conn, "/api/v1/auth/recover/complete", %{"recovery_token" => "x"})
      body = json_response(conn, 400)
      assert body["error"] == "validation.failed"
      assert "new_email" in body["required"]
      assert "new_password" in body["required"]
    end

    test "invalid new email returns 422 with details", %{conn: conn} do
      {identity, current_email} = register("rc_em")
      secret = enable_2fa(identity)
      {:ok, code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")
      token = validate_and_get_token(conn, identity, current_email, code, secret)

      complete =
        post(build_conn(), "/api/v1/auth/recover/complete", %{
          "recovery_token" => token,
          "new_email" => "not-an-email",
          "new_password" => "newpass1234567890xy",
          "new_password_confirmation" => "newpass1234567890xy"
        })

      body = json_response(complete, 422)
      assert body["error"] == "validation.failed"
      assert body["details"] != nil
    end
  end

  describe "DELETE /api/v1/accounts/recovery_code" do
    test "clears the stored code when given current password", %{conn: conn} do
      {identity, _email} = register("api_clr")
      enable_2fa(identity)
      {:ok, _, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      conn =
        conn
        |> auth_conn(identity)
        |> delete("/api/v1/accounts/recovery_code", %{"password" => "password1234567890"})

      assert json_response(conn, 200)["status"] == "ok"

      refreshed = Accounts.get_identity(identity.id)
      assert refreshed.recovery_code_hash == nil
    end
  end
end
