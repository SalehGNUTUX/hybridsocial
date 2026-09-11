defmodule Hybridsocial.Content.TranslationTest do
  @moduledoc """
  Covers the caching layer in front of the translation providers.

  The providers bill per character, so the thing worth locking down is that a
  repeat request for the same text does NOT reach the network again.
  """
  use Hybridsocial.DataCase, async: false

  alias Hybridsocial.{Cache, Config, Content.Translation}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Hybridsocial.Repo, {:shared, self()})
    start_supervised!(Config.Store)

    on_exit(fn ->
      Cache.flush_pattern("translation:*")
    end)

    :ok
  end

  describe "translate/3 when no backend is configured" do
    test "is disabled and never reaches a provider" do
      assert {:error, :translation_disabled} = Translation.translate("hola", "en")
      refute Translation.enabled?()
    end
  end

  describe "caching" do
    setup do
      Config.set("translation_backend", "libretranslate")
      # Point at an address nothing is listening on: any call that actually
      # escapes the cache fails loudly rather than silently costing money.
      Config.set("translation_api_url", "http://127.0.0.1:1")
      :ok
    end

    test "a cache hit is served without calling the provider" do
      key = cache_key_for("libretranslate", "hola mundo", "en", "auto")
      Cache.set(key, "hello world", 300)

      # The configured URL is unreachable, so a provider call could not
      # succeed — getting {:ok, _} proves the cache served it.
      assert {:ok, "hello world"} = Translation.translate("hola mundo", "en")
    end

    test "different target languages do not share a cache entry" do
      Cache.set(cache_key_for("libretranslate", "hola", "en", "auto"), "hello", 300)

      assert {:ok, "hello"} = Translation.translate("hola", "en")
      # French was never cached, so this must fall through to the (dead)
      # provider rather than wrongly returning the English hit.
      assert {:error, _} = Translation.translate("hola", "fr")
    end

    test "different backends do not share a cache entry" do
      Cache.set(cache_key_for("deepl", "hola", "en", "auto"), "hello from deepl", 300)

      # Configured backend is libretranslate; the deepl entry must not be used.
      assert {:error, _} = Translation.translate("hola", "en")
    end

    test "edited text misses the cache instead of serving the old translation" do
      Cache.set(cache_key_for("libretranslate", "original text", "en", "auto"), "stale", 300)

      assert {:ok, "stale"} = Translation.translate("original text", "en")
      # One character different — a different key, so no stale hit. This is
      # why the key hashes the text rather than a post id.
      assert {:error, _} = Translation.translate("original text!", "en")
    end

    test "a provider failure is not cached" do
      assert {:error, _} = Translation.translate("never translated", "en")

      refute Cache.get(cache_key_for("libretranslate", "never translated", "en", "auto")),
             "a transient provider error must not be pinned for the whole TTL"
    end

    test "ttl of 0 disables caching entirely" do
      Config.set("translation_cache_ttl_seconds", 0)
      key = cache_key_for("libretranslate", "hola", "en", "auto")
      Cache.set(key, "hello", 300)

      # Even with an entry present, caching is off, so it goes to the provider.
      assert {:error, _} = Translation.translate("hola", "en")
    end

    test "a non-integer ttl falls back to the default rather than crashing" do
      Config.set("translation_cache_ttl_seconds", "not a number")
      key = cache_key_for("libretranslate", "hola", "en", "auto")
      Cache.set(key, "hello", 300)

      assert {:ok, "hello"} = Translation.translate("hola", "en")
    end
  end

  # Mirrors the private key derivation in Translation.
  defp cache_key_for(backend, text, target, source) do
    digest =
      :crypto.hash(:sha256, [backend, <<0>>, source, <<0>>, target, <<0>>, text])
      |> Base.encode16(case: :lower)

    "translation:" <> digest
  end
end
