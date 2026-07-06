defmodule HybridsocialWeb.Federation.LegacyActorRouteTest do
  @moduledoc """
  The Pleroma-style `/users/:nickname` actor routes serve identities
  imported from a retired instance at their original URI, and refuse to
  serve native users (who live at `/actors/<uuid>`).
  """
  use HybridsocialWeb.ConnCase, async: true

  alias Hybridsocial.Accounts
  alias Hybridsocial.Accounts.Identity
  alias Hybridsocial.Repo

  @pub "-----BEGIN PUBLIC KEY-----\nMIIBIjANBg...\n-----END PUBLIC KEY-----\n"
  @priv "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAK...\n-----END RSA PRIVATE KEY-----\n"

  defp import_actor(nickname) do
    ap_url = "#{HybridsocialWeb.Endpoint.url()}/users/#{nickname}"

    {:ok, _} =
      %{
        "type" => "user",
        "handle" => nickname,
        "display_name" => nickname,
        "ap_actor_url" => ap_url,
        "public_key" => @pub,
        "private_key" => @priv,
        "inbox_url" => ap_url <> "/inbox",
        "followers_url" => ap_url <> "/followers"
      }
      |> Identity.import_changeset()
      |> Repo.insert()

    ap_url
  end

  defp ap_get(conn, path) do
    conn |> put_req_header("accept", "application/activity+json") |> get(path)
  end

  test "GET /users/:nickname serves an imported actor at its original URI", %{conn: conn} do
    nick = "legacy#{:erlang.unique_integer([:positive])}"
    ap_url = import_actor(nick)

    json = conn |> ap_get("/users/#{nick}") |> json_response(200)

    assert json["id"] == ap_url
    assert json["publicKey"]["id"] == ap_url <> "#main-key"
    assert json["publicKey"]["publicKeyPem"] == @pub
    assert json["inbox"] == ap_url <> "/inbox"
    assert json["followers"] == ap_url <> "/followers"
  end

  test "GET /users/:nickname redirects a browser (text/html) to the web profile", %{conn: conn} do
    nick = "legacy#{:erlang.unique_integer([:positive])}"
    import_actor(nick)

    conn =
      conn
      |> put_req_header(
        "accept",
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      )
      |> get("/users/#{nick}")

    assert redirected_to(conn) == "/@#{nick}"
  end

  test "GET /users/:nickname/followers reports the imported collection id", %{conn: conn} do
    nick = "legacy#{:erlang.unique_integer([:positive])}"
    ap_url = import_actor(nick)

    json = conn |> ap_get("/users/#{nick}/followers") |> json_response(200)
    assert json["id"] == ap_url <> "/followers"
    assert json["type"] == "OrderedCollection"
  end

  test "GET /users/:nickname 404s for a native user; /actors/<uuid> still serves it", %{
    conn: conn
  } do
    uniq = :erlang.unique_integer([:positive])

    {:ok, native} =
      Accounts.register_user(%{
        "handle" => "native#{uniq}",
        "email" => "native#{uniq}@test.com",
        "display_name" => "Native",
        "password" => "correct-horse-battery-staple",
        "password_confirmation" => "correct-horse-battery-staple"
      })

    assert conn |> ap_get("/users/#{native.handle}") |> json_response(404)

    json = build_conn() |> ap_get("/actors/#{native.id}") |> json_response(200)
    assert json["id"] == "#{HybridsocialWeb.Endpoint.url()}/actors/#{native.id}"
  end
end
