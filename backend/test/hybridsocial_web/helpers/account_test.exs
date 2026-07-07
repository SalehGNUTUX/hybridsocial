defmodule HybridsocialWeb.Helpers.AccountTest do
  use ExUnit.Case, async: true

  alias HybridsocialWeb.Helpers.Account
  alias Hybridsocial.Accounts.Identity

  describe "remote_domain/1 and profile_url/1" do
    test "local identity has no remote domain or url" do
      identity = %Identity{is_local: true, ap_actor_url: "http://localhost:4002/actors/x"}
      assert Account.remote_domain(identity) == nil
      assert Account.profile_url(identity) == nil
    end

    test "remote identity exposes its origin host and HTML url" do
      identity = %Identity{
        is_local: false,
        ap_actor_url: "https://remote.example/users/bob",
        profile_url: "https://remote.example/@bob"
      }

      assert Account.remote_domain(identity) == "remote.example"
      assert Account.profile_url(identity) == "https://remote.example/@bob"
    end

    test "profile_url falls back to ap_actor_url when the HTML url is unknown" do
      identity = %Identity{
        is_local: false,
        ap_actor_url: "https://remote.example/users/bob",
        profile_url: nil
      }

      assert Account.profile_url(identity) == "https://remote.example/users/bob"
    end
  end

  describe "serialize_summary/1" do
    test "includes emojis, domain, and url for a remote identity" do
      emojis = [%{"shortcode" => "freebsd", "url" => "https://remote.example/f.png"}]

      summary =
        Account.serialize_summary(%Identity{
          id: "id",
          handle: "bob",
          display_name: ":freebsd:",
          is_local: false,
          ap_actor_url: "https://remote.example/users/bob",
          profile_url: "https://remote.example/@bob",
          emojis: emojis
        })

      assert summary.emojis == emojis
      assert summary.domain == "remote.example"
      assert summary.url == "https://remote.example/@bob"
    end
  end

  describe "api_type/1" do
    test "translates :organization (atom) to 'page'" do
      assert Account.api_type(:organization) == "page"
    end

    test "translates \"organization\" (string) to 'page'" do
      assert Account.api_type("organization") == "page"
    end

    test "passes through other atoms as strings" do
      assert Account.api_type(:user) == "user"
      assert Account.api_type(:bot) == "bot"
      assert Account.api_type(:group) == "group"
    end

    test "passes through other strings unchanged" do
      assert Account.api_type("user") == "user"
      assert Account.api_type("bot") == "bot"
      assert Account.api_type("group") == "group"
    end

    test "returns nil for invalid input" do
      assert Account.api_type(nil) == nil
      assert Account.api_type(42) == nil
    end
  end
end
