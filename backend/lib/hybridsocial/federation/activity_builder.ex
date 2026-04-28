defmodule Hybridsocial.Federation.ActivityBuilder do
  @moduledoc """
  Builds ActivityPub activity objects from internal data structures.
  """

  @public "https://www.w3.org/ns/activitystreams#Public"

  # JSON-LD `@context` MUST be an array (or single object) per the
  # spec. Mastodon's strict JSON-LD parser rejects scalar strings —
  # interop tests against a real Mastodon instance fail with
  # "@context: invalid context" if you ship a bare string. We include
  # the security context (httpsig key publication uses it) so this
  # matches what Mastodon emits and what every other AP implementation
  # expects.
  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1"
  ]

  # --- Create ---

  def build_create(post) do
    post = maybe_preload(post, :identity)
    actor_url = actor_url(post.identity)
    note = build_note(post)

    %{
      "@context" => @context,
      "id" => activity_id(post.identity.id, "create", post.id),
      "type" => "Create",
      "actor" => actor_url,
      "published" => format_datetime(post.published_at || post.inserted_at),
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note
    }
  end

  # --- Update ---

  def build_update(post) do
    post = maybe_preload(post, :identity)
    actor_url = actor_url(post.identity)
    note = build_note(post)

    %{
      "@context" => @context,
      "id" => activity_id(post.identity.id, "update", post.id),
      "type" => "Update",
      "actor" => actor_url,
      "published" => format_datetime(post.edited_at || DateTime.utc_now()),
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note
    }
  end

  # --- Delete ---

  def build_delete(post) do
    post = maybe_preload(post, :identity)
    post = if post.visibility == "direct", do: preload_mentions(post), else: post
    actor_url = actor_url(post.identity)
    {to, cc} = determine_addressing(post)

    %{
      "@context" => @context,
      "id" => activity_id(post.identity.id, "delete", post.id),
      "type" => "Delete",
      "actor" => actor_url,
      "published" => format_datetime(DateTime.utc_now()),
      # Mirror the Create's audience — broadcasting a Delete wider
      # than the original post would leak that a private thread
      # existed. For public posts this is still Public+followers
      # (same as before). For direct, it's the mention list only.
      "to" => to,
      "cc" => cc,
      "object" => %{
        "id" => post_url(post.id),
        "type" => "Tombstone"
      }
    }
  end

  defp preload_mentions(%{mentions: %Ecto.Association.NotLoaded{}} = post) do
    Hybridsocial.Repo.preload(post, mentions: :identity)
  end

  defp preload_mentions(post), do: post

  # --- Follow ---

  def build_follow(follower_identity, followee_ap_id) do
    actor_url = actor_url(follower_identity)
    target_uuid = extract_uuid_from_url(followee_ap_id)

    %{
      "@context" => @context,
      "id" => activity_id(follower_identity.id, "follow", target_uuid),
      "type" => "Follow",
      "actor" => actor_url,
      "object" => followee_ap_id,
      "to" => [followee_ap_id]
    }
  end

  # --- Accept Follow ---

  def build_accept_follow(identity, follow_activity_id) do
    actor_url = actor_url(identity)
    target_uuid = extract_uuid_from_url(follow_activity_id)

    %{
      "@context" => @context,
      "id" => activity_id(identity.id, "accept", target_uuid),
      "type" => "Accept",
      "actor" => actor_url,
      "object" => follow_activity_id
    }
  end

  # --- Reject Follow ---

  def build_reject_follow(identity, follow_activity_id) do
    actor_url = actor_url(identity)
    target_uuid = extract_uuid_from_url(follow_activity_id)

    %{
      "@context" => @context,
      "id" => activity_id(identity.id, "reject", target_uuid),
      "type" => "Reject",
      "actor" => actor_url,
      "object" => follow_activity_id
    }
  end

  # --- Poll vote ---
  #
  # Mastodon convention: voting on a remote poll = posting a Note with
  # `inReplyTo: <Question id>`, `name: <option text>`, addressed to the
  # poll author. The author's instance tallies votes by name match
  # (which is why option names are unique within a poll). Each chosen
  # option ships as its own Create activity — multi-vote polls produce
  # one activity per choice.
  def build_poll_vote(identity, post, option) do
    actor = actor_url(identity)
    author = actor_ap_url(post.identity)
    object_url = post_object_url(post)

    note = %{
      "@context" => @context,
      "id" => "#{actor}/votes/#{post.id}/#{option.id}",
      "type" => "Note",
      "actor" => actor,
      "to" => [author],
      "name" => option.text,
      "inReplyTo" => object_url,
      "attributedTo" => actor,
      "published" => format_datetime(DateTime.utc_now())
    }

    %{
      "@context" => @context,
      "id" => "#{actor}/votes/#{post.id}/#{option.id}/activity",
      "type" => "Create",
      "actor" => actor,
      "to" => [author],
      "object" => note
    }
  end

  # --- Like ---

  def build_like(identity, post) do
    post = maybe_preload(post, :identity)
    actor_url = actor_url(identity)
    author_url = actor_ap_url(post.identity)
    audience_cc = reaction_audience_urls(post, identity)

    # The Like is primarily addressed to the post's author (matches
    # Mastodon's expectation), and `cc`'d to every remote actor that
    # has a cached copy of the post — local-author posts that remote
    # instances mirror via Follow, plus mentioned recipients on
    # direct posts. Without the cc fan-out, a like on a local post
    # would only ever live on the origin instance and the remote
    # mirrors would be stuck at "0 reactions" forever.
    %{
      "@context" => @context,
      "id" => activity_id(identity.id, "like", post.id),
      "type" => "Like",
      "actor" => actor_url,
      "to" => [author_url],
      "cc" => audience_cc,
      "object" => post_object_url(post)
    }
  end

  # --- EmojiReact (Pleroma extension, accepted by Mastodon as Like) ---
  #
  # Used for non-default reactions (love/care/wow/sad/angry/lol/...).
  # Peers that don't speak EmojiReact still treat the activity as a
  # Like because the shape is identical apart from `type` + `content`.
  def build_emoji_react(identity, post, emoji) do
    post = maybe_preload(post, :identity)
    actor_url = actor_url(identity)
    author_url = actor_ap_url(post.identity)
    audience_cc = reaction_audience_urls(post, identity)

    %{
      "@context" => @context,
      "id" => activity_id(identity.id, "emoji-react", post.id),
      "type" => "EmojiReact",
      "actor" => actor_url,
      "to" => [author_url],
      "cc" => audience_cc,
      "object" => post_object_url(post),
      "content" => emoji
    }
  end

  # Remote AP actor URLs that should receive a reaction activity for
  # `post`. Computes the union of the post author's remote followers
  # (so any peer that mirrored the post via Follow learns about the
  # reaction) and any mentioned actors (relevant for direct posts).
  # Drops the reactor's own URL — they already have the reaction
  # locally — and the post author's URL since it lives in `to`.
  defp reaction_audience_urls(post, identity) do
    import Ecto.Query

    excluded = MapSet.new([actor_url(identity), actor_ap_url(post.identity)])

    follower_urls =
      from(f in Hybridsocial.Social.Follow,
        join: i in Hybridsocial.Accounts.Identity,
        on: i.id == f.follower_id,
        where:
          f.followee_id == ^post.identity_id and
            f.status == :accepted and
            not is_nil(i.ap_actor_url) and
            i.ap_actor_url != "",
        select: i.ap_actor_url
      )
      |> Hybridsocial.Repo.all()

    mention_urls =
      case Map.get(post, :mentions) do
        list when is_list(list) ->
          Enum.flat_map(list, fn
            %{identity: %{ap_actor_url: url}} when is_binary(url) and url != "" -> [url]
            _ -> []
          end)

        _ ->
          []
      end

    (follower_urls ++ mention_urls)
    |> Enum.reject(fn url -> MapSet.member?(excluded, url) or local_url?(url) end)
    |> Enum.uniq()
  end

  # The Publisher already filters local URLs out at delivery time,
  # but pre-filtering here keeps the activity's `cc` honest about
  # who's actually being addressed remotely.
  defp local_url?(url) when is_binary(url), do: String.starts_with?(url, base_url())
  defp local_url?(_), do: false

  # Prefer the post's federated ap_id when present (mirror of a
  # remote post) so the receiving peer recognizes its own URL;
  # fall back to our local representation for purely local posts
  # — they'll never be the target of an outbound reaction in
  # practice, but the helper keeps both branches sane.
  defp post_object_url(%{ap_id: ap_id}) when is_binary(ap_id) and ap_id != "", do: ap_id
  defp post_object_url(post), do: post_url(post.id)

  # --- Announce (Boost) ---

  def build_announce(identity, post) do
    post = maybe_preload(post, :identity)
    actor_url = actor_url(identity)

    %{
      "@context" => @context,
      "id" => activity_id(identity.id, "announce", post.id),
      "type" => "Announce",
      "actor" => actor_url,
      "published" => format_datetime(DateTime.utc_now()),
      "to" => [@public],
      # Same fix as Like — when the boosted post is remote, this needs
      # the remote ap_actor_url so the post author's instance receives
      # the Announce. The bare local actor_url ended up matching our
      # base_url and getting filtered out as "local target".
      "cc" => [followers_url(identity), actor_ap_url(post.identity)],
      # Likewise the object URL needs to be the post's canonical AP
      # id when it's a remote post — so the receiving peer recognises
      # its own URL — falling back to our local representation only
      # for native posts.
      "object" => post_object_url(post)
    }
  end

  # --- Undo ---

  def build_undo(identity, activity_to_undo) do
    actor_url = actor_url(identity)
    target_uuid = extract_uuid_from_url(activity_to_undo["id"])

    %{
      "@context" => @context,
      "id" => activity_id(identity.id, "undo", target_uuid),
      "type" => "Undo",
      "actor" => actor_url,
      "to" => activity_to_undo["to"] || [],
      "object" => activity_to_undo
    }
  end

  # --- Block ---

  def build_block(identity, target_ap_id) do
    actor_url = actor_url(identity)
    target_uuid = extract_uuid_from_url(target_ap_id)

    %{
      "@context" => @context,
      "id" => activity_id(identity.id, "block", target_uuid),
      "type" => "Block",
      "actor" => actor_url,
      "object" => target_ap_id
    }
  end

  # --- Move ---

  def build_move(old_identity, new_ap_id) do
    actor_url = actor_url(old_identity)
    target_uuid = extract_uuid_from_url(new_ap_id)

    %{
      "@context" => @context,
      "id" => activity_id(old_identity.id, "move", target_uuid),
      "type" => "Move",
      "actor" => actor_url,
      "object" => actor_url,
      "target" => new_ap_id
    }
  end

  # --- Flag (Report) ---

  @doc """
  Build an AS Flag activity for forwarding a report to the reported
  actor's origin instance. Signed with the instance actor (per
  Mastodon/Pleroma convention — the reporter's identity stays out of
  the payload so the remote side can't retaliate). `object` collects
  the reported actor AP id plus the post AP id when there is one;
  `content` carries the reporter's description; `to` addresses the
  reported actor so their inbox knows how to route.
  """
  def build_flag(%Hybridsocial.Moderation.Report{} = report, reported_ap_id, post_ap_id)
      when is_binary(reported_ap_id) do
    alias Hybridsocial.Federation.InstanceActor

    objects =
      [reported_ap_id, post_ap_id]
      |> Enum.reject(&is_nil/1)

    %{
      "@context" => @context,
      "id" => "#{base_url()}/flags/#{report.id}",
      "type" => "Flag",
      "actor" => InstanceActor.ap_id(),
      "object" => objects,
      "content" => report.description || "",
      "to" => [reported_ap_id]
    }
  end

  # --- Add (Pin) ---

  def build_add(identity, post) do
    %{
      "@context" => @context,
      "id" => activity_id(identity.id, "add", post.id),
      "type" => "Add",
      "actor" => actor_url(identity),
      "object" => post_url(post.id),
      "target" => "#{base_url()}/actors/#{identity.id}/collections/featured"
    }
  end

  # --- Remove (Unpin) ---

  def build_remove(identity, post) do
    %{
      "@context" => @context,
      "id" => activity_id(identity.id, "remove", post.id),
      "type" => "Remove",
      "actor" => actor_url(identity),
      "object" => post_url(post.id),
      "target" => "#{base_url()}/actors/#{identity.id}/collections/featured"
    }
  end

  # --- Note builder ---

  @doc """
  Builds the Note/Article/Question JSON-LD object for a post. Exposed
  so the `/posts/:id` AP endpoint can serve the same shape that
  Create/Update activities embed as their `object` — lets remote
  peers dereference the post URL and get the same bytes.
  """
  def build_note(post) do
    {to, cc} = determine_addressing(post)

    note = %{
      "@context" => @context,
      "id" => post_url(post.id),
      "type" => "Note",
      "attributedTo" => actor_url(post.identity),
      "content" => post.content_html || post.content,
      "published" => format_datetime(post.published_at || post.inserted_at),
      "to" => to,
      "cc" => cc,
      "inReplyTo" => build_in_reply_to(post),
      "sensitive" => post.sensitive || false,
      "summary" => post.spoiler_text,
      "tag" => build_tags(post),
      "attachment" => build_attachments(post),
      # The AP `id` is the JSON-LD object URL; `url` is supposed to be
      # the human-readable page so a remote client's "Open original"
      # link lands on something a browser can render. We were emitting
      # `id == url == /posts/:id`, so clicking "View on origin" from
      # Mastodon dropped users on a JSON document.
      "url" => post_html_url(post.id)
    }

    # Direct-visibility posts participate in a "conversation" thread on
    # Mastodon-class peers. They use the `conversation`/`context`
    # string as an opaque grouping key in the DM column; without it
    # each of our replies appears as a standalone status. The URI
    # doesn't need to dereference — it's just a stable ID derived from
    # the thread root.
    note =
      if post.visibility == "direct" do
        thread_uri = conversation_uri_for(post)

        note
        |> Map.put("conversation", thread_uri)
        |> Map.put("context", thread_uri)
        |> Map.put("directMessage", true)
      else
        note
      end

    # Add contentMap for language-tagged content
    note =
      if post.language && post.language != "" do
        Map.put(note, "contentMap", %{post.language => note["content"]})
      else
        note
      end

    note =
      if post.edited_at do
        Map.put(note, "updated", format_datetime(post.edited_at))
      else
        note
      end

    # Handle poll posts: change type to Question and add poll data
    if post.post_type == "poll" do
      post = Hybridsocial.Repo.preload(post, poll: :options)

      case post.poll do
        nil ->
          note

        poll ->
          choice_key = if poll.multiple_choice, do: "anyOf", else: "oneOf"

          options =
            Enum.map(poll.options, fn opt ->
              %{
                "type" => "Note",
                "name" => opt.text,
                "replies" => %{"type" => "Collection", "totalItems" => opt.votes_count}
              }
            end)

          note
          |> Map.put("type", "Question")
          |> Map.put(choice_key, options)
          |> Map.put("endTime", format_datetime(poll.expires_at))
          |> Map.put("votersCount", poll.voters_count)
      end
    else
      note
    end
  end

  defp determine_addressing(post) do
    followers = followers_url(post.identity)

    # Base audience per visibility. Anything this doesn't match
    # (group/list/unknown) is NOT federated — returning empty lists
    # signals the Publisher to noop rather than default to Public,
    # which would silently widen the audience of a visibility we
    # don't know how to translate to ActivityStreams.
    #
    #   public    → addressed AS:Public, cc'd to followers.
    #   unlisted  → addressed to followers, AS:Public in cc. This
    #               is Mastodon's convention for "don't show in
    #               public timelines but anyone with the URL can
    #               read." Swapping to/cc is what makes it so.
    #   followers → addressed to followers collection only.
    #   direct    → addressed to the explicit mention list only.
    {base_to, base_cc} =
      case post.visibility do
        "public" -> {[@public], [followers]}
        "unlisted" -> {[followers], [@public]}
        "followers" -> {[followers], []}
        "direct" -> {direct_recipients(post), []}
        _ -> {[], []}
      end

    # Replies additionally address the parent author so their instance
    # receives the reply activity via inbox push. Without this the
    # parent's server never learns about the reply and our post never
    # shows up in the remote thread view.
    parent_author_url = parent_author_ap_url(post)

    cc =
      if parent_author_url && parent_author_url not in base_cc,
        do: base_cc ++ [parent_author_url],
        else: base_cc

    {base_to, cc}
  end

  # Build the `to` list for a direct-visibility post: every identity
  # recorded in `post_mentions` contributes its ap_actor_url (local or
  # remote). Falls back to mention hrefs parsed from content if the
  # mention rows aren't preloaded — defensive for paths that build the
  # note outside the federation flow (e.g. the AP object endpoint).
  defp direct_recipients(%{mentions: mentions}) when is_list(mentions) do
    mentions
    |> Enum.map(fn
      %{identity: %{ap_actor_url: url}} when is_binary(url) -> url
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp direct_recipients(post) do
    post.content
    |> extract_mentions()
    |> Enum.map(& &1["href"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Stable non-dereferenceable URI that groups all messages in a DM
  # thread under one Mastodon "conversation". Derived from the thread
  # root (top-level post in the reply chain) so reply depth doesn't
  # matter — every post in the tree shares the same key.
  defp conversation_uri_for(post) do
    %URI{host: host} = URI.parse(base_url())
    root_id = post.root_id || post.id
    "tag:#{host},2026:objectId=#{root_id}:objectType=Conversation"
  end

  defp parent_author_ap_url(%{parent_id: parent_id}) when is_binary(parent_id) do
    case Hybridsocial.Repo.get(Hybridsocial.Social.Post, parent_id) do
      %{identity_id: parent_identity_id} ->
        case Hybridsocial.Repo.get(Hybridsocial.Accounts.Identity, parent_identity_id) do
          %{ap_actor_url: ap_url} when is_binary(ap_url) -> ap_url
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parent_author_ap_url(_), do: nil

  defp build_in_reply_to(%{parent_ap_id: ap_id}) when is_binary(ap_id), do: ap_id

  defp build_in_reply_to(%{parent_id: nil}), do: nil

  defp build_in_reply_to(%{parent_id: parent_id}) when not is_nil(parent_id) do
    post_url(parent_id)
  end

  defp build_in_reply_to(_), do: nil

  defp build_tags(post) do
    hashtag_tags = extract_hashtags(post.content)
    mention_tags = extract_mentions(post.content)
    emoji_tags = build_emoji_tags(post.content)
    hashtag_tags ++ mention_tags ++ emoji_tags
  end

  defp extract_hashtags(nil), do: []

  defp extract_hashtags(content) do
    ~r/#([a-zA-Z0-9_]+)/
    |> Regex.scan(content)
    |> Enum.map(fn [_, tag] ->
      %{
        "type" => "Hashtag",
        "href" => "#{base_url()}/tags/#{String.downcase(tag)}",
        "name" => "##{String.downcase(tag)}"
      }
    end)
  end

  defp extract_mentions(content) do
    content
    |> Hybridsocial.Federation.LocalUrl.parse_mentions()
    |> Enum.map(fn {handle, domain} -> mention_tag(handle, domain) end)
    |> Enum.reject(&is_nil/1)
  end

  # Resolve a parsed mention to a stored identity and build the AP
  # tag. Drops mentions we can't resolve rather than emitting a
  # guessed URL — an unrecognized `href` means the remote server
  # won't deliver, and a local guess could accidentally point at a
  # different account with the same handle.
  defp mention_tag(handle, domain) do
    case Hybridsocial.Federation.LocalUrl.resolve_mention(handle, domain) do
      %Hybridsocial.Accounts.Identity{ap_actor_url: url} when is_binary(url) ->
        %{
          "type" => "Mention",
          "href" => url,
          "name" => mention_name(handle, domain)
        }

      _ ->
        nil
    end
  end

  defp mention_name(handle, nil), do: "@#{handle}"
  defp mention_name(handle, domain), do: "@#{handle}@#{domain}"

  defp build_emoji_tags(nil), do: []

  defp build_emoji_tags(content) do
    Regex.scan(~r/:([a-zA-Z0-9_]+):/, content)
    |> Enum.map(fn [_, shortcode] ->
      case Hybridsocial.Content.Emojis.get_emoji_by_shortcode(shortcode) do
        nil ->
          nil

        emoji ->
          %{
            "type" => "Emoji",
            "id" => emoji.image_url,
            "name" => ":#{emoji.shortcode}:",
            "icon" => %{
              "type" => "Image",
              "url" => emoji.image_url
            }
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # --- Media attachments ---

  defp build_attachments(post) do
    # Post schema has the association as `media_attachments` (the AP
    # builder used to grep for `post.media` and the wrong key meant
    # every Create/Update we federated arrived with `attachment: []`,
    # so remote peers never showed our images). Query MediaFile
    # directly by post_id so the result doesn't depend on whether the
    # caller preloaded the association.
    import Ecto.Query, only: [from: 2]

    medias =
      Hybridsocial.Repo.all(
        from m in Hybridsocial.Media.MediaFile,
          where: m.post_id == ^post.id and is_nil(m.deleted_at),
          order_by: [asc: m.inserted_at]
      )

    Enum.map(medias, fn m ->
      url =
        if is_binary(m.remote_url) and m.remote_url != "" do
          # Re-federate as the source URL — peers that already have
          # the byte cached should reuse it, and our media proxy is
          # an internal-routing detail, not a canonical origin.
          m.remote_url
        else
          Hybridsocial.Media.media_url(m)
        end

      attachment = %{
        "type" => media_ap_type(m.content_type),
        "mediaType" => m.content_type,
        "url" => url,
        "name" => m.alt_text || ""
      }

      attachment =
        if is_binary(m.blurhash) and m.blurhash != "" do
          Map.put(attachment, "blurhash", m.blurhash)
        else
          attachment
        end

      if m.width && m.height do
        Map.put(attachment, "width", m.width) |> Map.put("height", m.height)
      else
        attachment
      end
    end)
  end

  defp media_ap_type("image/" <> _), do: "Image"
  defp media_ap_type("video/" <> _), do: "Video"
  defp media_ap_type("audio/" <> _), do: "Audio"
  defp media_ap_type(_), do: "Document"

  # --- URL helpers ---

  defp activity_id(actor_uuid, action, target_uuid) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    "#{base_url()}/activities/#{actor_uuid}/#{action}/#{target_uuid}/#{timestamp}"
  end

  defp actor_url(identity) do
    "#{base_url()}/actors/#{identity.id}"
  end

  # AP-addressable URL for an identity. For remote identities use the
  # cached `ap_actor_url` so when we address (e.g.) a Like to the post
  # author, the Publisher routes it to the remote inbox. The bare
  # `actor_url/1` always builds a LOCAL URL — fine for the activity's
  # own `actor` field (we sign as the local user) but wrong for `to`/
  # `cc` when the addressee is remote, which is why reactions on
  # remote posts never federated: the only target was a local URL,
  # so `determine_recipients/2` saw zero remote inboxes.
  defp actor_ap_url(%{ap_actor_url: url}) when is_binary(url) and url != "", do: url
  defp actor_ap_url(identity), do: actor_url(identity)

  defp post_url(post_id) do
    "#{base_url()}/posts/#{post_id}"
  end

  # Human-readable post page (SvelteKit), distinct from the AP JSON-LD
  # endpoint at `/posts/:id`. Used for the AP `url` field so remote
  # "View original" links resolve to a viewable page.
  defp post_html_url(post_id) do
    "#{base_url()}/post/#{post_id}"
  end

  defp followers_url(identity) do
    "#{base_url()}/actors/#{identity.id}/followers"
  end

  defp base_url do
    HybridsocialWeb.Endpoint.url()
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp extract_uuid_from_url(nil), do: "unknown"

  defp extract_uuid_from_url(url) when is_binary(url) do
    # Try to extract a UUID from the URL, fall back to a hash of the URL
    case Regex.run(~r/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i, url) do
      [_, uuid] -> uuid
      nil -> :crypto.hash(:sha256, url) |> Base.url_encode64(padding: false) |> binary_part(0, 16)
    end
  end

  defp maybe_preload(%{identity: %Hybridsocial.Accounts.Identity{}} = post, :identity), do: post

  defp maybe_preload(post, :identity) do
    Hybridsocial.Repo.preload(post, :identity)
  end
end
