defmodule HybridsocialWeb.Api.V1.RecoveryControllerTest do
  use HybridsocialWeb.ConnCase, async: true

  alias Hybridsocial.Accounts

  defp register(handle) do
    uniq = :erlang.unique_integer([:positive])

    {:ok, identity} =
      Accounts.register_user(%{
        "handle" => "#{handle}_#{uniq}",
        "email" => "#{handle}_#{uniq}@test.com",
        "display_name" => handle,
        "password" => "password1234567890",
        "password_confirmation" => "password1234567890"
      })

    identity
  end

  defp auth_conn(conn, identity) do
    {:ok, access_token, _claims} = Hybridsocial.Auth.Token.generate_access_token(identity.id)
    put_req_header(conn, "authorization", "Bearer #{access_token}")
  end

  describe "POST /api/v1/accounts/recovery_code" do
    test "authenticated user can generate a recovery code", %{conn: conn} do
      identity = register("api_gen")

      conn =
        conn
        |> auth_conn(identity)
        |> post("/api/v1/accounts/recovery_code", %{"password" => "password1234567890"})

      body = json_response(conn, 200)
      assert is_binary(body["recovery_code"])
      assert String.length(body["recovery_code"]) == 23
      assert body["warning"] =~ "cannot be recovered"
    end

    test "wrong password is rejected with 403", %{conn: conn} do
      identity = register("api_gen_wrong")

      conn =
        conn
        |> auth_conn(identity)
        |> post("/api/v1/accounts/recovery_code", %{"password" => "wrong"})

      assert json_response(conn, 403)["error"] == "auth.invalid_password"
    end
  end

  describe "GET /api/v1/accounts/recovery_code" do
    test "reports whether a code is set (no plaintext ever leaks)", %{conn: conn} do
      identity = register("api_status")

      # Before setting anything.
      conn1 = conn |> auth_conn(identity) |> get("/api/v1/accounts/recovery_code")

      assert json_response(conn1, 200) == %{
               "enabled" => false,
               "generated_at" => nil,
               "last_used_at" => nil
             }

      # After generating.
      {:ok, _, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      conn2 = build_conn() |> auth_conn(identity) |> get("/api/v1/accounts/recovery_code")
      response = json_response(conn2, 200)
      assert response["enabled"] == true
      refute Map.has_key?(response, "recovery_code")
    end
  end

  describe "POST /api/v1/auth/recover" do
    test "resets password and returns a new code", %{conn: conn} do
      identity = register("api_recover")
      {:ok, code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      conn =
        post(conn, "/api/v1/auth/recover", %{
          "handle" => identity.handle,
          "recovery_code" => code,
          "new_password" => "newpass1234567890xy",
          "new_password_confirmation" => "newpass1234567890xy"
        })

      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert is_binary(body["new_recovery_code"])
      refute body["new_recovery_code"] == code
    end

    test "wrong code returns 401, no detail", %{conn: conn} do
      identity = register("rec_wrong")
      {:ok, _, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      bad = "A2345-B2345-C2345-D2345"

      conn =
        post(conn, "/api/v1/auth/recover", %{
          "handle" => identity.handle,
          "recovery_code" => bad,
          "new_password" => "newpass1234567890xy",
          "new_password_confirmation" => "newpass1234567890xy"
        })

      assert json_response(conn, 401)["error"] == "auth.invalid_recovery"
    end

    test "unknown handle returns 401 (not 404)", %{conn: conn} do
      conn =
        post(conn, "/api/v1/auth/recover", %{
          "handle" => "totally-not-real",
          "recovery_code" => "A2345-B2345-C2345-D2345",
          "new_password" => "newpass1234567890xy",
          "new_password_confirmation" => "newpass1234567890xy"
        })

      assert json_response(conn, 401)["error"] == "auth.invalid_recovery"
    end

    test "missing params return 400", %{conn: conn} do
      conn = post(conn, "/api/v1/auth/recover", %{"handle" => "x"})
      assert json_response(conn, 400)["error"] == "validation.failed"
    end
  end

  describe "DELETE /api/v1/accounts/recovery_code" do
    test "clears the stored code when given current password", %{conn: conn} do
      identity = register("api_clear")
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
