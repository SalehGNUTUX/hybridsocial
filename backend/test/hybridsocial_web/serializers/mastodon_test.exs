defmodule HybridsocialWeb.Serializers.MastodonTest do
  @moduledoc """
  Unit tests for the projection into Mastodon's shapes. No DB — these guard
  the field mapping and, above all, the non-null contract: Mastodon's client
  models declare most fields non-nullable, so a null lands as a
  deserialization crash rather than an empty row.
  """
  use ExUnit.Case, async: true

  alias HybridsocialWeb.Serializers.Mastodon

  defp post_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        id: "post-1",
        uri: "https://example.test/posts/post-1",
        url: "https://example.test/post/post-1",
        content: "*hello*",
        content_html: "<p><em>hello</em></p>",
        visibility: "followers",
        sensitive: false,
        spoiler_text: nil,
        language: "en",
        reply_count: 3,
        boost_count: 2,
        reaction_count: 7,
        is_pinned: false,
        is_boosted: true,
        is_bookmarked: false,
        is_muted: false,
        current_user_reaction: "like",
        created_at: ~U[2026-01-01 00:00:00Z],
        edited_at: nil,
        parent_id: "post-0",
        in_reply_to_account_id: "acct-9",
        account: account_fixture(),
        media_attachments: [],
        mentions: [],
        tags: [],
        emojis: [],
        card: nil,
        poll: nil
      },
      overrides
    )
  end

  defp account_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        id: "acct-1",
        handle: "alice",
        acct: "alice",
        display_name: "Alice",
        bio: "raw bio",
        bio_html: "<p>raw bio</p>",
        avatar_url: "https://cdn.test/a.png",
        header_url: nil,
        is_locked: false,
        is_bot: false,
        type: "user",
        followers_count: 5,
        following_count: 4,
        created_at: ~U[2025-01-01 00:00:00Z],
        emojis: [],
        profile_fields: []
      },
      overrides
    )
  end

  describe "status/1" do
    test "maps our counters and viewer state onto Mastodon's names" do
      status = Mastodon.status(post_fixture())

      assert status.replies_count == 3
      assert status.reblogs_count == 2
      assert status.favourites_count == 7
      assert status.reblogged == true
      assert status.favourited == true
      assert status.bookmarked == false
      assert status.in_reply_to_id == "post-0"
      assert status.in_reply_to_account_id == "acct-9"
    end

    test "content is HTML and the raw source moves to text" do
      status = Mastodon.status(post_fixture())

      assert status.content == "<p><em>hello</em></p>"
      assert status.text == "*hello*"
    end

    test "followers-only becomes private" do
      assert Mastodon.status(post_fixture()).visibility == "private"
      assert Mastodon.status(post_fixture(%{visibility: "public"})).visibility == "public"
      assert Mastodon.status(post_fixture(%{visibility: "direct"})).visibility == "direct"
    end

    # Our group and list scopes have no Mastodon equivalent. Whatever they map
    # to must not be broader than the original audience.
    test "scopes with no equivalent never widen" do
      assert Mastodon.status(post_fixture(%{visibility: "group"})).visibility == "unlisted"
      assert Mastodon.status(post_fixture(%{visibility: "list"})).visibility == "private"
    end

    test "no reaction means not favourited" do
      status = Mastodon.status(post_fixture(%{current_user_reaction: nil}))
      refute status.favourited
    end

    test "spoiler_text is empty rather than null" do
      assert Mastodon.status(post_fixture()).spoiler_text == ""
    end

    test "reads payloads that came back out of the cache with string keys" do
      cached = %{
        "id" => "post-2",
        "content_html" => "<p>cached</p>",
        "reply_count" => 1,
        "visibility" => "public",
        "account" => %{"id" => "acct-1", "handle" => "bob"}
      }

      status = Mastodon.status(cached)

      assert status.id == "post-2"
      assert status.content == "<p>cached</p>"
      assert status.replies_count == 1
      assert status.account.username == "bob"
    end

    test "a boost entry becomes the reblog wrapper" do
      entry = %{
        id: "boost-1",
        type: "boost",
        created_at: ~U[2026-02-02 00:00:00Z],
        account: account_fixture(%{id: "acct-2", handle: "booster"}),
        post: post_fixture()
      }

      status = Mastodon.status(entry)

      # The outer status is the boost: authored by the booster, empty body.
      assert status.id == "boost-1"
      assert status.account.username == "booster"
      assert status.content == ""
      assert status.reblogged == true
      # ...and it carries the original, with the original's author and counts.
      assert status.reblog.id == "post-1"
      assert status.reblog.account.username == "alice"
      assert status.reblog.replies_count == 3
      # Counts belong to the original, not the wrapper.
      assert status.favourites_count == 0
      assert status.reblogs_count == 0
    end
  end

  describe "statuses/1" do
    # Our thread view inserts placeholders for deleted posts. Mastodon has no
    # equivalent, and a status with a null account fails to deserialize.
    test "drops tombstones instead of emitting an authorless status" do
      tombstone = %{id: "gone", type: "tombstone", content: nil, content_html: nil}

      assert Mastodon.statuses([post_fixture(), tombstone]) |> length() == 1
      assert Mastodon.status(tombstone) == nil
    end
  end

  describe "context/1" do
    test "keeps ancestors and descendants separate" do
      ctx = Mastodon.context(%{ancestors: [post_fixture()], descendants: []})

      assert [ancestor] = ctx.ancestors
      assert ancestor.id == "post-1"
      assert ctx.descendants == []
    end
  end

  describe "account/1" do
    test "renames our fields to Mastodon's" do
      account = Mastodon.account(account_fixture())

      assert account.username == "alice"
      assert account.display_name == "Alice"
      assert account.note == "<p>raw bio</p>"
      assert account.locked == false
      assert account.bot == false
      assert account.followers_count == 5
      assert account.following_count == 4
    end

    test "fills every non-null field when ours are missing" do
      account = Mastodon.account(%{id: "acct-3", handle: "bare"})

      assert account.display_name == "bare"
      assert account.note == ""
      assert account.avatar != nil
      assert account.avatar_static != nil
      assert account.header == ""
      assert account.followers_count == 0
      assert account.following_count == 0
      assert account.statuses_count == 0
      assert account.fields == []
      assert account.emojis == []
      assert account.url != nil
    end

    test "hidden follow counts read as zero, not null" do
      account = Mastodon.account(account_fixture(%{followers_count: nil, following_count: nil}))

      assert account.followers_count == 0
      assert account.following_count == 0
    end

    test "a relative avatar path is made absolute" do
      account = Mastodon.account(account_fixture(%{avatar_url: "/uploads/a.png"}))
      assert String.starts_with?(account.avatar, "http")
    end

    test "an organization identity is flagged as a group" do
      assert Mastodon.account(account_fixture(%{type: "group"})).group == true
      assert Mastodon.account(account_fixture()).group == false
    end
  end

  describe "notification/1" do
    test "maps our types onto Mastodon's vocabulary" do
      for {ours, theirs} <- [
            {"reaction", "favourite"},
            {"boost", "reblog"},
            {"reply", "mention"},
            {"mention", "mention"},
            {"follow", "follow"},
            {"follow_request", "follow_request"}
          ] do
        notif = %{id: "n1", type: ours, created_at: ~U[2026-01-01 00:00:00Z], account: nil}
        assert Mastodon.notification(notif).type == theirs
      end
    end

    test "an unknown type degrades to mention rather than breaking the list" do
      notif = %{id: "n2", type: "something_new", created_at: nil, account: nil}
      assert Mastodon.notification(notif).type == "mention"
    end
  end

  describe "relationship/1" do
    test "fills the fields we do not model" do
      rel = Mastodon.relationship(%{id: "acct-1", following: true, muting: false})

      assert rel.following == true
      assert rel.showing_reblogs == true
      assert rel.notifying == false
      assert rel.endorsed == false
      assert rel.note == ""
      assert rel.domain_blocking == false
    end
  end

  describe "normalize_status_params/1" do
    test "maps Mastodon's status fields onto ours" do
      params =
        Mastodon.normalize_status_params(%{
          "status" => "hello",
          "in_reply_to_id" => "post-1",
          "visibility" => "private"
        })

      assert params["content"] == "hello"
      assert params["parent_id"] == "post-1"
      assert params["visibility"] == "followers"
    end

    test "does not clobber a value the caller already sent" do
      params = Mastodon.normalize_status_params(%{"status" => "a", "content" => "b"})
      assert params["content"] == "b"
    end

    test "leaves our own params untouched" do
      params = Mastodon.normalize_status_params(%{"content" => "hi", "visibility" => "followers"})

      assert params["content"] == "hi"
      assert params["visibility"] == "followers"
    end

    test "expands the nested poll into our flat fields" do
      params =
        Mastodon.normalize_status_params(%{
          "status" => "pick one",
          "poll" => %{"options" => ["a", "b"], "expires_in" => "3600", "multiple" => "true"}
        })

      assert params["post_type"] == "poll"
      assert params["options"] == ["a", "b"]
      assert params["multiple_choice"] == true
      assert %DateTime{} = params["expires_at"]
    end
  end
end
