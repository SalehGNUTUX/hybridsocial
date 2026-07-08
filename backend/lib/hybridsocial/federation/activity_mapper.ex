defmodule Hybridsocial.Federation.ActivityMapper do
  @moduledoc """
  Maps ActivityPub objects to internal model attributes.
  """

  @emoji_map %{
    "❤️" => "love",
    "❤" => "love",
    "😂" => "lol",
    "🤣" => "lol",
    "😢" => "sad",
    "😭" => "sad",
    "😡" => "angry",
    "😠" => "angry",
    "🤗" => "care",
    "😱" => "wtf",
    "😲" => "wtf",
    "👍" => "like",
    "⭐" => "like"
  }

  @doc """
  Converts a Note/Article/Question AP object to internal post attributes.
  """
  def to_post(%{"type" => "Question"} = ap_object) do
    base = to_post_base(ap_object)
    options = ap_object["oneOf"] || ap_object["anyOf"] || []
    multiple = ap_object["anyOf"] != nil

    # Extract option text + vote count per option. Remote peers
    # (Mastodon, Pleroma, …) ship votes inside `replies.totalItems`
    # per option, with the running unique-voter total at the top
    # level as `votersCount`.
    poll_options =
      Enum.map(options, fn opt ->
        %{
          "name" => opt["name"],
          "votes_count" => extract_vote_count(opt)
        }
      end)

    base
    |> Map.merge(%{
      "post_type" => "poll",
      "poll_options" => poll_options,
      "poll_multiple" => multiple,
      "poll_expires_at" => ap_object["endTime"],
      "poll_voters_count" => extract_voters_count(ap_object)
    })
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  def to_post(ap_object) when is_map(ap_object) do
    to_post_base(ap_object)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp extract_vote_count(%{"replies" => %{"totalItems" => n}}) when is_integer(n), do: n
  defp extract_vote_count(_), do: 0

  defp extract_voters_count(%{"votersCount" => n}) when is_integer(n), do: n
  defp extract_voters_count(_), do: 0

  defp to_post_base(ap_object) do
    visibility = determine_visibility(ap_object)
    post_type = determine_post_type(ap_object)

    # `content` is the plaintext column; `content_html` holds the
    # rendered HTML we display. Remote peers send HTML in `content`,
    # so we strip it here — the same stripper is reused by the DM
    # ingest path so plaintext extraction is consistent across both.
    raw_html = ap_object["content"]
    plaintext = Hybridsocial.Content.HtmlStripper.to_plaintext(raw_html)

    attrs = %{
      "ap_id" => ap_object["id"],
      "content" => plaintext,
      "content_html" => raw_html,
      "post_type" => post_type,
      "visibility" => visibility,
      "sensitive" => ap_object["sensitive"] || false,
      "spoiler_text" => ap_object["summary"],
      "language" => extract_language(ap_object),
      "published_at" => parse_datetime(ap_object["published"]),
      "emojis" => extract_emojis(ap_object["tag"])
    }

    maybe_put(attrs, "parent_ap_id", ap_object["inReplyTo"])
  end

  # AP `Note.tag` is a mixed array — hashtags, mentions, and custom
  # emojis. Pull just the Emoji entries and normalize to the shape
  # the renderer wants: `%{"shortcode" => "blob_smile", "url" =>
  # "https://example/emoji/blob_smile.png", "static_url" => ...}`.
  # Strips surrounding colons from `name` and drops entries missing
  # an image URL (some peers ship malformed Emoji objects).
  @doc """
  Pull custom-emoji entries out of an AP `tag` value (a list, a single map,
  or nil), normalized to `%{"shortcode" => _, "url" => _, "static_url" => _}`.
  Shared by post ingest (`to_post/1`) and actor ingest (profile emojis).
  """
  def extract_emojis(nil), do: []
  def extract_emojis(tag) when is_list(tag), do: Enum.flat_map(tag, &emoji_entry/1)
  def extract_emojis(tag) when is_map(tag), do: emoji_entry(tag)
  def extract_emojis(_), do: []

  @doc """
  Pull hashtag entries out of an AP `tag` value. Remote instances declare
  hashtags as `%{"type" => "Hashtag", "name" => "#photography", ...}`
  entries in the same mixed `tag` array that carries Mentions and Emojis.
  Returns `{lowercase_name, display}` pairs — the exact shape
  `Hybridsocial.Social.Posts.extract_hashtags/1` produces — so federation
  ingest can feed them through the same upsert/link path as local posts.
  Each `name` is validated against the local tag charset (letter-led,
  Unicode-aware) so a malformed remote value can't inject junk into the
  `hashtags` table.
  """
  def extract_hashtags(nil), do: []

  def extract_hashtags(tag) when is_list(tag) do
    tag |> Enum.flat_map(&hashtag_entry/1) |> Enum.uniq_by(fn {name, _} -> name end)
  end

  def extract_hashtags(tag) when is_map(tag), do: hashtag_entry(tag)
  def extract_hashtags(_), do: []

  defp hashtag_entry(%{"type" => "Hashtag", "name" => name}) when is_binary(name) do
    cleaned = name |> String.trim() |> String.trim_leading("#")

    case Regex.run(~r/^(\p{L}[\p{L}\p{M}\p{N}_]{0,100})$/u, cleaned) do
      [_, tag] -> [{String.downcase(tag), tag}]
      _ -> []
    end
  end

  defp hashtag_entry(_), do: []

  @doc """
  Best-effort normalization of an AP actor `url` (which may be a string, a
  Link object, or a list of them) into a single http(s) URL string, or nil.
  """
  def normalize_profile_url(url) when is_binary(url), do: if(http_url?(url), do: url, else: nil)
  def normalize_profile_url(%{"href" => href}), do: normalize_profile_url(href)
  def normalize_profile_url([first | _]), do: normalize_profile_url(first)
  def normalize_profile_url(_), do: nil

  defp emoji_entry(%{"type" => "Emoji", "name" => name} = tag) when is_binary(name) do
    shortcode = name |> String.trim() |> String.trim(":")
    url = extract_emoji_url(tag["icon"])

    if shortcode != "" and is_binary(url) and http_url?(url) do
      [%{"shortcode" => shortcode, "url" => url, "static_url" => url}]
    else
      []
    end
  end

  defp emoji_entry(_), do: []

  defp extract_emoji_url(%{"url" => url}) when is_binary(url), do: url
  defp extract_emoji_url(%{"href" => url}) when is_binary(url), do: url
  defp extract_emoji_url(url) when is_binary(url), do: url
  defp extract_emoji_url(_), do: nil

  defp http_url?(url) when is_binary(url) do
    String.starts_with?(url, "http://") or String.starts_with?(url, "https://")
  end

  defp http_url?(_), do: false

  @doc """
  Converts an AP Actor to remote_actor attributes.
  """
  def to_actor(ap_actor) when is_map(ap_actor) do
    domain = extract_domain(ap_actor["id"])

    %{
      ap_id: ap_actor["id"],
      handle: ap_actor["preferredUsername"],
      domain: domain,
      display_name: ap_actor["name"],
      avatar_url: extract_icon_url(ap_actor["icon"]),
      public_key: extract_public_key(ap_actor),
      inbox_url: ap_actor["inbox"],
      outbox_url: ap_actor["outbox"],
      followers_url: ap_actor["followers"],
      shared_inbox_url: get_in(ap_actor, ["endpoints", "sharedInbox"])
    }
  end

  @doc """
  Maps an emoji or content string to a reaction type.
  Falls back to :like for unknown emoji.
  """
  def to_reaction_type(nil), do: "like"
  def to_reaction_type(""), do: "like"

  def to_reaction_type(content) when is_binary(content) do
    # Try direct match first, then try first grapheme
    case Map.get(@emoji_map, content) do
      nil ->
        grapheme = String.graphemes(content) |> List.first()
        Map.get(@emoji_map, grapheme, "like")

      type ->
        type
    end
  end

  @doc """
  Extracts the domain from an AP ID URL.
  """
  def extract_domain(nil), do: nil

  def extract_domain(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  # Private helpers

  defp determine_visibility(ap_object) do
    to = List.wrap(ap_object["to"])
    cc = List.wrap(ap_object["cc"])
    all_recipients = to ++ cc

    public = "https://www.w3.org/ns/activitystreams#Public"

    cond do
      public in to -> "public"
      public in cc -> "public"
      has_followers_address?(all_recipients) -> "followers"
      true -> "direct"
    end
  end

  defp has_followers_address?(recipients) do
    Enum.any?(recipients, fn r ->
      is_binary(r) and String.ends_with?(r, "/followers")
    end)
  end

  defp determine_post_type(ap_object) do
    case ap_object["type"] do
      "Article" -> "article"
      _ -> "text"
    end
  end

  defp extract_language(ap_object) do
    case ap_object["contentMap"] do
      map when is_map(map) ->
        map |> Map.keys() |> List.first()

      _ ->
        nil
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        # Ensure microsecond precision for Ecto's utc_datetime_usec
        %{dt | microsecond: {elem(dt.microsecond, 0), 6}}

      _ ->
        nil
    end
  end

  defp extract_icon_url(%{"url" => url}) when is_binary(url), do: url
  defp extract_icon_url(_), do: nil

  defp extract_public_key(ap_actor) do
    case ap_actor["publicKey"] do
      %{"publicKeyPem" => pem} when is_binary(pem) -> pem
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
