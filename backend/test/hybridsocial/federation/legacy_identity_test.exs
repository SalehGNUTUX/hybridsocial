defmodule Hybridsocial.Federation.LegacyIdentityTest do
  @moduledoc """
  Foundation for importing actors from a retired Pleroma/Rebased instance:
  a local identity can keep a foreign-shaped `ap_actor_url` + imported
  keypair and still be classified local.
  """
  use Hybridsocial.DataCase, async: true

  alias Hybridsocial.Accounts
  alias Hybridsocial.Accounts.Identity
  alias Hybridsocial.Federation.{ActorSerializer, LocalUrl}
  alias Hybridsocial.Repo

  defp register_native(handle) do
    uniq = :erlang.unique_integer([:positive])

    {:ok, identity} =
      Accounts.register_user(%{
        "handle" => "#{handle}_#{uniq}",
        "email" => "#{handle}_#{uniq}@test.com",
        "display_name" => handle,
        "password" => "correct-horse-battery-staple",
        "password_confirmation" => "correct-horse-battery-staple"
      })

    identity
  end

  # Minimal well-formed PEM stand-ins — the storage layer treats them as
  # opaque strings; wire-level signing is exercised elsewhere.
  @pub "-----BEGIN PUBLIC KEY-----\nMIIBIjANBg...\n-----END PUBLIC KEY-----\n"
  @priv "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAK...\n-----END RSA PRIVATE KEY-----\n"

  defp import_actor(handle, ap_url) do
    %{
      "type" => "user",
      "handle" => handle,
      "display_name" => handle,
      "ap_actor_url" => ap_url,
      "public_key" => @pub,
      "private_key" => @priv,
      "inbox_url" => ap_url <> "/inbox",
      "outbox_url" => ap_url <> "/outbox",
      "followers_url" => ap_url <> "/followers",
      "following_url" => ap_url <> "/following"
    }
    |> Identity.import_changeset()
    |> Repo.insert()
  end

  describe "import_changeset/2" do
    test "preserves the imported URI and keypair, marks the actor local" do
      handle = "legacy_#{:erlang.unique_integer([:positive])}"
      ap_url = "https://bassam.social/users/#{handle}"

      assert {:ok, identity} = import_actor(handle, ap_url)

      # Original identity preserved verbatim — not regenerated.
      assert identity.ap_actor_url == ap_url
      assert identity.public_key == @pub
      assert identity.private_key == @priv
      assert identity.inbox_url == ap_url <> "/inbox"
      assert identity.following_url == ap_url <> "/following"
      assert identity.is_local == true
    end

    test "requires the identity-defining fields" do
      cs = Identity.import_changeset(%{"type" => "user", "handle" => "x"})
      refute cs.valid?
      assert %{ap_actor_url: _, public_key: _, private_key: _} = errors_on(cs)
    end
  end

  describe "LocalUrl.local_identity?/1" do
    test "true for an imported actor despite its foreign-shaped URL" do
      handle = "legacy_#{:erlang.unique_integer([:positive])}"
      {:ok, identity} = import_actor(handle, "https://bassam.social/users/#{handle}")
      assert LocalUrl.local_identity?(identity)
    end

    test "true for a natively-registered user" do
      uniq = :erlang.unique_integer([:positive])

      {:ok, identity} =
        Accounts.register_user(%{
          "handle" => "native_#{uniq}",
          "email" => "native_#{uniq}@test.com",
          "display_name" => "Native",
          "password" => "correct-horse-battery-staple",
          "password_confirmation" => "correct-horse-battery-staple"
        })

      assert identity.is_local == true
      assert LocalUrl.local_identity?(identity)
    end

    test "false for a remote identity, regardless of URL" do
      assert LocalUrl.local_identity?(%Identity{
               is_local: false,
               ap_actor_url: "https://remote.social/users/bob"
             }) ==
               false
    end

    test "falls back to the URL prefix only when is_local is nil" do
      base = LocalUrl.base_url()

      assert LocalUrl.local_identity?(%Identity{
               is_local: nil,
               ap_actor_url: base <> "/actors/abc"
             })

      refute LocalUrl.local_identity?(%Identity{
               is_local: nil,
               ap_actor_url: "https://remote.social/users/bob"
             })
    end
  end

  describe "ActorSerializer.to_ap/1" do
    test "native user is byte-identical to the /actors/<uuid> scheme (no regression)" do
      native = register_native("nativ")
      base = LocalUrl.base_url()
      actor = "#{base}/actors/#{native.id}"

      ap = ActorSerializer.to_ap(native)

      assert ap["id"] == actor
      assert ap["url"] == actor
      assert ap["inbox"] == "#{actor}/inbox"
      assert ap["outbox"] == "#{actor}/outbox"
      assert ap["followers"] == "#{actor}/followers"
      assert ap["following"] == "#{actor}/following"
      assert ap["featured"] == "#{actor}/collections/featured"
      assert ap["publicKey"]["id"] == "#{actor}#main-key"
      assert ap["publicKey"]["owner"] == actor
      assert ap["endpoints"]["sharedInbox"] == "#{base}/inbox"
    end

    test "outgoing activity actor field uses the stored URL for imported actors" do
      handle = "legacy_#{:erlang.unique_integer([:positive])}"
      ap_url = "https://bassam.social/users/#{handle}"
      {:ok, identity} = import_actor(handle, ap_url)

      follow =
        Hybridsocial.Federation.ActivityBuilder.build_follow(
          identity,
          "https://mastodon.example/users/bob"
        )

      # The actor MUST match the keyId/actor-doc id, or remotes drop it.
      assert follow["actor"] == ap_url
      assert follow["object"] == "https://mastodon.example/users/bob"
    end

    test "native actor field stays on the /actors/<uuid> scheme" do
      native = register_native("nativeactor")

      follow =
        Hybridsocial.Federation.ActivityBuilder.build_follow(
          native,
          "https://mastodon.example/users/bob"
        )

      assert follow["actor"] == "#{LocalUrl.base_url()}/actors/#{native.id}"
    end

    test "imported actor serializes with its original Pleroma URI + key" do
      handle = "legacy_#{:erlang.unique_integer([:positive])}"
      ap_url = "https://bassam.social/users/#{handle}"
      {:ok, identity} = import_actor(handle, ap_url)

      ap = ActorSerializer.to_ap(identity)

      assert ap["id"] == ap_url
      assert ap["url"] == ap_url
      assert ap["inbox"] == "#{ap_url}/inbox"
      assert ap["following"] == "#{ap_url}/following"
      assert ap["featured"] == "#{ap_url}/collections/featured"
      assert ap["publicKey"]["id"] == "#{ap_url}#main-key"
      assert ap["publicKey"]["owner"] == ap_url
      assert ap["publicKey"]["publicKeyPem"] == @pub
    end
  end
end
