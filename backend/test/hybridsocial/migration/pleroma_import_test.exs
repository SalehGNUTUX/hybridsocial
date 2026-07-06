defmodule Hybridsocial.Migration.PleromaImportTest do
  use Hybridsocial.DataCase, async: true

  import Ecto.Query

  alias Hybridsocial.Migration.PleromaImport
  alias Hybridsocial.Accounts.Identity
  alias Hybridsocial.Federation.ActorSerializer
  alias Hybridsocial.Repo
  alias Hybridsocial.Social.{Follow, Post}
  alias Hybridsocial.Media.MediaFile

  defp note_map(actor, id, in_reply_to, content) do
    m = %{
      "id" => id,
      "type" => "Note",
      "actor" => actor,
      "attributedTo" => actor,
      "content" => "<p>#{content}</p>",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [actor <> "/followers"],
      "published" => "2023-01-01T00:00:00Z",
      "sensitive" => false,
      "tag" => [],
      "attachment" => []
    }

    if in_reply_to, do: Map.put(m, "inReplyTo", in_reply_to), else: m
  end

  # A real RSA private key PEM, exactly as Pleroma stores in `users.keys`.
  defp real_private_pem do
    priv = :public_key.generate_key({:rsa, 2048, 65537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, priv)
    :public_key.pem_encode([entry])
  end

  defp pleroma_user(nickname) do
    ap = "https://bassam.social/users/#{nickname}"

    %{
      "id" => Ecto.UUID.generate(),
      "nickname" => nickname,
      "ap_id" => ap,
      "name" => "The #{nickname}",
      "bio" => "<p>hello &amp; <b>world</b></p>",
      "raw_bio" => nil,
      "keys" => real_private_pem(),
      "follower_address" => ap <> "/followers",
      "following_address" => ap <> "/following",
      "featured_address" => ap <> "/collections/featured",
      "inbox" => nil,
      "shared_inbox" => nil,
      "actor_type" => "Person",
      "email" => "#{nickname}@x.test",
      "avatar" => %{"url" => [%{"href" => "https://bassam.social/media/av.jpg"}]},
      "banner" => %{},
      "also_known_as" => [],
      "is_locked" => false,
      "is_discoverable" => true,
      "birthday" => nil,
      "location" => nil
    }
  end

  test "creates a login User account (email + blind index) so the user can reset" do
    nick = "bassam#{:erlang.unique_integer([:positive])}"
    u = pleroma_user(nick)

    assert {:ok, identity} = PleromaImport.import_user(u)

    user = Hybridsocial.Accounts.get_user_by_email(u["email"])
    assert user
    assert user.identity_id == identity.id
    assert user.confirmed_at, "pre-existing users should be confirmed"
  end

  test "a user with no email gets an identity only (no login row)" do
    nick = "noemail#{:erlang.unique_integer([:positive])}"
    u = pleroma_user(nick) |> Map.delete("email")

    assert {:ok, identity} = PleromaImport.import_user(u)
    refute Hybridsocial.Repo.get(Hybridsocial.Accounts.User, identity.id)
  end

  test "imports a Pleroma user, preserving URI + deriving the public key" do
    nick = "plero#{:erlang.unique_integer([:positive])}"
    u = pleroma_user(nick)

    assert {:ok, identity} = PleromaImport.import_user(u)

    assert identity.handle == nick
    assert identity.ap_actor_url == u["ap_id"]
    assert identity.private_key == u["keys"]
    assert identity.is_local == true
    assert identity.followers_url == u["ap_id"] <> "/followers"
    # inbox / shared_inbox are derived (Pleroma leaves them null for locals)
    assert identity.inbox_url == u["ap_id"] <> "/inbox"
    assert identity.shared_inbox_url == "https://bassam.social/inbox"
    assert identity.avatar_url == "https://bassam.social/media/av.jpg"
    assert identity.bio =~ "world"
    refute identity.bio =~ "<"

    # Derived public key is valid and matches the private key.
    {:ok, derived} = PleromaImport.derive_public_key(u["keys"])
    assert identity.public_key == derived
    assert identity.public_key =~ "PUBLIC KEY"

    # And it serializes at its original Pleroma URI with the derived key.
    ap = ActorSerializer.to_ap(identity)
    assert ap["id"] == u["ap_id"]
    assert ap["publicKey"]["id"] == u["ap_id"] <> "#main-key"
    assert ap["publicKey"]["publicKeyPem"] == identity.public_key
  end

  test "is idempotent on ap_actor_url (safe to re-run)" do
    nick = "plerodup#{:erlang.unique_integer([:positive])}"
    u = pleroma_user(nick)

    assert {:ok, a} = PleromaImport.import_user(u)
    assert {:ok, b} = PleromaImport.import_user(u)
    assert a.id == b.id
    assert Repo.aggregate(from(i in Identity, where: i.handle == ^nick), :count) == 1
  end

  test "derived public key verifies a signature made with the private key" do
    # This is the crux of federation continuity: a remote server fetches
    # our actor (with the derived public key) and verifies a signature we
    # made with the imported private key. Prove the round-trip holds.
    priv_pem = real_private_pem()
    {:ok, pub_pem} = PleromaImport.derive_public_key(priv_pem)

    [priv_entry] = :public_key.pem_decode(priv_pem)
    priv = :public_key.pem_entry_decode(priv_entry)
    [pub_entry] = :public_key.pem_decode(pub_pem)
    pub = :public_key.pem_entry_decode(pub_entry)

    message = "(request-target): post /inbox\nhost: bassam.social\ndate: today"
    signature = :public_key.sign(message, :sha256, priv)

    assert :public_key.verify(message, :sha256, signature, pub)
    refute :public_key.verify(message <> "tampered", :sha256, signature, pub)
  end

  test "imports remote endpoints + follows, mapping Pleroma state to status" do
    a = pleroma_user("fa#{:erlang.unique_integer([:positive])}")
    b = pleroma_user("fb#{:erlang.unique_integer([:positive])}")
    {:ok, _} = PleromaImport.import_user(a)
    {:ok, _} = PleromaImport.import_user(b)

    remote = %{
      "id" => Ecto.UUID.generate(),
      "nickname" => "bob",
      "ap_id" => "https://mastodon.example/users/bob#{:erlang.unique_integer([:positive])}",
      "name" => "Bob",
      "actor_type" => "Person",
      "public_key" => "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n",
      "inbox" => nil,
      "follower_address" => nil,
      "avatar" => %{}
    }

    assert %{ok: 1} = PleromaImport.import_remote_actors([remote])
    # remote endpoint is a non-local identity with the source uuid
    ri = Repo.get_by(Identity, ap_actor_url: remote["ap_id"])
    assert ri.is_local == false
    assert ri.id == remote["id"]

    follows = [
      %{"follower_id" => a["id"], "following_id" => b["id"], "state" => 2},
      %{"follower_id" => a["id"], "following_id" => remote["id"], "state" => 1},
      # missing endpoint → skip
      %{"follower_id" => b["id"], "following_id" => Ecto.UUID.generate(), "state" => 2},
      # rejected → skip
      %{"follower_id" => b["id"], "following_id" => a["id"], "state" => 3}
    ]

    summary = PleromaImport.import_follows(follows)
    assert summary.ok == 2
    assert summary.skipped == 2

    assert Repo.get_by(Follow, follower_id: a["id"], followee_id: b["id"]).status == :accepted
    assert Repo.get_by(Follow, follower_id: a["id"], followee_id: remote["id"]).status == :pending
  end

  test "imports notes as posts, resolves threading + reply counts" do
    au = pleroma_user("pau#{:erlang.unique_integer([:positive])}")
    {:ok, author} = PleromaImport.import_user(au)
    map = PleromaImport.local_author_map()
    uniq = :erlang.unique_integer([:positive])

    root_note =
      note_map(au["ap_id"], "https://bassam.social/objects/root#{uniq}", nil, "hello world")

    assert {:ok, root} = PleromaImport.import_post(root_note, map)
    assert root.identity_id == author.id
    assert root.ap_id == root_note["id"]
    assert root.content =~ "hello world"
    assert root.visibility == "public"

    reply_note =
      note_map(
        au["ap_id"],
        "https://bassam.social/objects/reply#{uniq}",
        root_note["id"],
        "a reply"
      )

    assert {:ok, reply} = PleromaImport.import_post(reply_note, map)
    assert reply.parent_ap_id == root_note["id"]

    PleromaImport.link_post_threads()
    assert Repo.get(Post, reply.id).parent_id == root.id
    assert Repo.get(Post, reply.id).root_id == root.id
    assert Repo.get(Post, root.id).reply_count == 1
  end

  test "skips notes whose author isn't a local import" do
    map = PleromaImport.local_author_map()

    note =
      note_map(
        "https://mastodon.example/users/bob",
        "https://mastodon.example/objects/x",
        nil,
        "hi"
      )

    assert {:skip, _} = PleromaImport.import_post(note, map)
  end

  test "imports Pleroma array-form attachments as remote media" do
    au = pleroma_user("pam#{:erlang.unique_integer([:positive])}")
    {:ok, _} = PleromaImport.import_user(au)
    map = PleromaImport.local_author_map()
    uniq = :erlang.unique_integer([:positive])

    note =
      note_map(au["ap_id"], "https://bassam.social/objects/media#{uniq}", nil, "pic")
      |> Map.put("attachment", [
        %{
          "type" => "Document",
          "mediaType" => "image/png",
          "name" => "alt",
          "url" => [%{"href" => "https://media.bassam.social/x.png", "mediaType" => "image/png"}]
        }
      ])

    {:ok, post} = PleromaImport.import_post(note, map)
    media = Repo.all(from(m in MediaFile, where: m.post_id == ^post.id))
    assert length(media) == 1
    assert hd(media).remote_url == "https://media.bassam.social/x.png"
  end

  test "import_users summarizes outcomes" do
    users = [
      pleroma_user("bulk#{:erlang.unique_integer([:positive])}"),
      pleroma_user("bulk#{:erlang.unique_integer([:positive])}")
    ]

    summary = PleromaImport.import_users(users)
    assert summary.ok == 2
    assert summary.failed == []
  end
end
