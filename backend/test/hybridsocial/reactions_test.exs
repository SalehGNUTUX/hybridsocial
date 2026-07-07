defmodule Hybridsocial.ReactionsTest do
  use Hybridsocial.DataCase, async: true

  alias Hybridsocial.Reactions

  # A seed migration inserts exactly 7 premium reactions (the @max_premium
  # cap), and migrations commit outside the sandbox, so every test sees
  # those rows as baseline. Clear them inside each test's sandbox
  # transaction (rolled back after) so create_premium/list_enabled tests
  # start from an empty premium table.
  setup do
    Repo.delete_all(Hybridsocial.Reactions.PremiumReactionEmoji)
    :ok
  end

  describe "default_reaction?/1" do
    test "returns true for the seven standard shortcodes" do
      for code <- ~w(like love care angry sad lol wow) do
        assert Reactions.default_reaction?(code)
      end
    end

    test "returns false for anything else" do
      refute Reactions.default_reaction?("rocket")
      refute Reactions.default_reaction?("")
      refute Reactions.default_reaction?(nil)
    end
  end

  describe "create_premium/2" do
    test "stores a unicode-character reaction" do
      assert {:ok, emoji} =
               Reactions.create_premium(
                 %{"shortcode" => "rocket", "character" => "🚀"},
                 Ecto.UUID.generate()
               )

      assert emoji.shortcode == "rocket"
      assert emoji.character == "🚀"
      assert emoji.enabled
    end

    test "stores an image-url reaction" do
      assert {:ok, emoji} =
               Reactions.create_premium(
                 %{"shortcode" => "logo", "image_url" => "https://example.com/logo.svg"},
                 Ecto.UUID.generate()
               )

      assert emoji.image_url == "https://example.com/logo.svg"
    end

    test "rejects entry with neither character nor image" do
      assert {:error, changeset} =
               Reactions.create_premium(%{"shortcode" => "empty"}, Ecto.UUID.generate())

      assert {_, _} = changeset.errors[:character]
    end

    test "rejects invalid shortcodes" do
      for bad <- ["UPPER", "with-dash", "", "!", String.duplicate("x", 33)] do
        assert {:error, changeset} =
                 Reactions.create_premium(
                   %{"shortcode" => bad, "character" => "🔥"},
                   Ecto.UUID.generate()
                 )

        assert {_, _} = changeset.errors[:shortcode]
      end
    end

    test "rejects duplicates" do
      Reactions.create_premium(
        %{"shortcode" => "uniq", "character" => "🔥"},
        Ecto.UUID.generate()
      )

      assert {:error, changeset} =
               Reactions.create_premium(
                 %{"shortcode" => "uniq", "character" => "💧"},
                 Ecto.UUID.generate()
               )

      assert {_, _} = changeset.errors[:shortcode]
    end

    test "refuses past the 7-entry cap" do
      admin = Ecto.UUID.generate()

      for i <- 1..7 do
        assert {:ok, _} =
                 Reactions.create_premium(
                   %{"shortcode" => "fill_#{i}", "character" => "🎉"},
                   admin
                 )
      end

      assert {:error, :cap_reached} =
               Reactions.create_premium(
                 %{"shortcode" => "overflow", "character" => "🎈"},
                 admin
               )
    end
  end

  describe "premium_reaction?/1" do
    test "true only when an enabled row matches" do
      {:ok, _} =
        Reactions.create_premium(
          %{"shortcode" => "fire", "character" => "🔥", "enabled" => true},
          Ecto.UUID.generate()
        )

      {:ok, _} =
        Reactions.create_premium(
          %{"shortcode" => "ice", "character" => "🧊", "enabled" => false},
          Ecto.UUID.generate()
        )

      assert Reactions.premium_reaction?("fire")
      refute Reactions.premium_reaction?("ice")
      refute Reactions.premium_reaction?("does_not_exist")
    end
  end

  describe "list_enabled_premium/0" do
    test "returns only enabled rows ordered by position" do
      assert {:ok, _} =
               Reactions.create_premium(
                 %{"shortcode" => "alpha", "character" => "A", "position" => 2},
                 Ecto.UUID.generate()
               )

      assert {:ok, _} =
               Reactions.create_premium(
                 %{"shortcode" => "bravo", "character" => "B", "position" => 0},
                 Ecto.UUID.generate()
               )

      # `enabled: false` requires the update path since create defaults to true.
      {:ok, charlie} =
        Reactions.create_premium(
          %{"shortcode" => "charlie", "character" => "C", "position" => 1},
          Ecto.UUID.generate()
        )

      assert {:ok, _} = Reactions.update_premium(charlie.id, %{"enabled" => false})

      shortcodes =
        Reactions.list_enabled_premium()
        |> Enum.map(& &1.shortcode)

      assert shortcodes == ["bravo", "alpha"]
    end
  end

  describe "delete_premium/1" do
    test "removes the row" do
      {:ok, emoji} =
        Reactions.create_premium(
          %{"shortcode" => "del_me", "character" => "🗑"},
          Ecto.UUID.generate()
        )

      assert {:ok, _} = Reactions.delete_premium(emoji.id)
      refute Reactions.premium_reaction?("del_me")
    end

    test "returns :not_found for missing IDs" do
      assert {:error, :not_found} = Reactions.delete_premium(Ecto.UUID.generate())
    end
  end
end
