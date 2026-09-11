defmodule Hybridsocial.Content.Translation do
  @moduledoc """
  Post translation service. Supports configurable translation backends.
  Default: LibreTranslate (free, self-hostable).

  Successful translations are cached (see `translate/3`) because the providers
  bill per character: without it, cost scales with how many people *read* a
  post rather than with how much gets written.
  """

  require Logger

  @cache_ttl_key "translation_cache_ttl_seconds"
  @default_cache_ttl 86_400

  @doc """
  Translates `text` into `target_lang`, returning `{:ok, translated}`.

  Results are cached in Valkey, keyed on a digest of
  `(backend, source_lang, target_lang, text)`:

    * **text, not post id** — two posts quoting the same sentence share a
      single provider call, and an *edited* post hashes differently, so a
      stale translation of the old body can never be served. That's why the
      key doesn't need the post id plumbed through.
    * **backend included** — switching provider must not serve the previous
      one's output.

  Only successes are cached. Caching an error would pin a transient provider
  outage for the whole TTL. TTL comes from the DB-backed
  `translation_cache_ttl_seconds` (default 24h); set it to `0` to disable
  caching entirely.
  """
  def translate(text, target_lang, source_lang \\ "auto") do
    backend = Hybridsocial.Config.get("translation_backend", "none")

    case backend do
      "libretranslate" ->
        with_cache(backend, text, target_lang, source_lang, fn ->
          translate_libre(text, target_lang, source_lang)
        end)

      "deepl" ->
        with_cache(backend, text, target_lang, source_lang, fn ->
          translate_deepl(text, target_lang, source_lang)
        end)

      _ ->
        {:error, :translation_disabled}
    end
  end

  defp with_cache(backend, text, target, source, fun) do
    case cache_ttl() do
      ttl when ttl > 0 ->
        key = cache_key(backend, text, target, source)

        case Hybridsocial.Cache.get(key) do
          nil ->
            case fun.() do
              {:ok, translated} = ok ->
                Hybridsocial.Cache.set(key, translated, ttl)
                ok

              error ->
                error
            end

          cached ->
            {:ok, cached}
        end

      _ ->
        fun.()
    end
  end

  defp cache_ttl do
    case Hybridsocial.Config.get(@cache_ttl_key, @default_cache_ttl) do
      n when is_integer(n) -> n
      n when is_binary(n) -> String.to_integer(n)
      _ -> @default_cache_ttl
    end
  rescue
    # Config values are stored untyped; a garbage value must not take
    # translation down, it should just fall back to the default TTL.
    ArgumentError -> @default_cache_ttl
  end

  defp cache_key(backend, text, target, source) do
    digest =
      :crypto.hash(:sha256, [backend, <<0>>, source, <<0>>, target, <<0>>, text])
      |> Base.encode16(case: :lower)

    "translation:" <> digest
  end

  def enabled? do
    Hybridsocial.Config.get("translation_backend", "none") != "none"
  end

  defp translate_libre(text, target, source) do
    url = Hybridsocial.Config.get("translation_api_url", "https://libretranslate.com")
    api_key = Hybridsocial.Config.get("translation_api_key", "")

    body =
      Jason.encode!(%{
        q: text,
        source: source,
        target: target,
        api_key: api_key
      })

    case Hybridsocial.HTTP.post("#{url}/translate", body, [{"Content-Type", "application/json"}],
           recv_timeout: 10_000
         ) do
      {:ok, %{status_code: 200, body: resp}} ->
        case Jason.decode(resp) do
          {:ok, %{"translatedText" => translated}} -> {:ok, translated}
          _ -> {:error, :parse_error}
        end

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp translate_deepl(text, target, _source) do
    api_key = Hybridsocial.Config.get("translation_api_key", "")
    url = "https://api-free.deepl.com/v2/translate"

    body =
      URI.encode_query(%{
        "text" => text,
        "target_lang" => String.upcase(target),
        "auth_key" => api_key
      })

    case Hybridsocial.HTTP.post(
           url,
           body,
           [{"Content-Type", "application/x-www-form-urlencoded"}],
           recv_timeout: 10_000
         ) do
      {:ok, %{status_code: 200, body: resp}} ->
        case Jason.decode(resp) do
          {:ok, %{"translations" => [%{"text" => translated} | _]}} -> {:ok, translated}
          _ -> {:error, :parse_error}
        end

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
