defmodule HybridsocialWeb.Api.V1.StatusTranslateTest do
  @moduledoc """
  Covers `POST /api/v1/statuses/:id/translate`.

  Its own module rather than a block in `StatusControllerTest` because these
  need `Config.Store`, which isn't started in `:test` and has to share the
  sandbox connection — incompatible with that file's `async: true`.
  """
  use HybridsocialWeb.ConnCase, async: false

  alias Hybridsocial.Social.Posts

  setup %{conn: conn} do
    Ecto.Adapters.SQL.Sandbox.mode(Hybridsocial.Repo, {:shared, self()})
    start_supervised!(Hybridsocial.Config.Store)

    identity = create_user("xlate_user", "xlate_user@test.com")
    {:ok, tokens} = Hybridsocial.Auth.login("xlate_user@test.com", "password1234567890")
    conn = put_req_header(conn, "authorization", "Bearer #{tokens.access_token}")

    %{conn: conn, identity: identity}
  end

  test "is unavailable until an admin configures a backend", %{conn: conn, identity: identity} do
    {:ok, post_record} = Posts.create_post(identity.id, %{"content" => "hola"})

    conn = post(conn, "/api/v1/statuses/#{post_record.id}/translate", %{"target_lang" => "en"})

    # Off by default — no post text is sent anywhere until it's switched on.
    assert json_response(conn, 503)["error"] == "translation.disabled"
  end

  test "404s for a post the viewer cannot see, even with a backend enabled", %{conn: conn} do
    Hybridsocial.Config.set("translation_backend", "libretranslate")
    author = create_user("xlate_author", "xlate_author@test.com")

    {:ok, private} =
      Posts.create_post(author.id, %{"content" => "secret", "visibility" => "direct"})

    conn = post(conn, "/api/v1/statuses/#{private.id}/translate", %{"target_lang" => "en"})

    # Must fail the visibility check BEFORE any text reaches the provider,
    # otherwise translate becomes a read primitive for posts you can't see.
    assert json_response(conn, 404)["error"] == "status.not_found"
  end

  test "404s for a post that does not exist", %{conn: conn} do
    Hybridsocial.Config.set("translation_backend", "libretranslate")
    missing = Ecto.UUID.generate()

    conn = post(conn, "/api/v1/statuses/#{missing}/translate", %{"target_lang" => "en"})

    assert json_response(conn, 404)["error"] == "status.not_found"
  end

  test "requires authentication" do
    conn = post(build_conn(), "/api/v1/statuses/#{Ecto.UUID.generate()}/translate", %{})
    assert json_response(conn, 401)
  end
end
