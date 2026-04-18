defmodule Hybridsocial.Social.Posts do
  @moduledoc """
  Context module for managing posts, reactions, boosts, and hashtags.
  """
  import Ecto.Query
  alias Hybridsocial.Repo
  alias Hybridsocial.Social.{Post, PostRevision, Reaction, Boost, Hashtag, Polls}
  alias Hybridsocial.Premium.TierLimits
  alias Hybridsocial.Content.Emojis

  @default_page_size 20

  # --- Post CRUD ---

  def create_post(identity_id, attrs, identity \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    limits = resolve_limits(identity)
    edit_expires_at = compute_edit_expires_at(now, limits[:edit_window] || 900)
    markdown_level = resolve_markdown_level(attrs, limits)
    content_html = maybe_render_content_html(attrs["content"], markdown_level)

    # Allocate the post ID up-front so we can stamp its canonical AP
    # URL into `ap_id` in the same insert. With this, `get_post_by_ap_id/1`
    # becomes an indexed lookup for both local and remote rows, and
    # every Delete/Update activity we emit references a value the
    # inbox can hand straight back to the DB.
    post_id = Map.get(attrs, "id") || Ecto.UUID.generate()
    ap_id = "#{HybridsocialWeb.Endpoint.url()}/posts/#{post_id}"

    scheduled_at = Map.get(attrs, "scheduled_at") || Map.get(attrs, :scheduled_at)

    # Scheduled posts stay unpublished until the worker picks them up;
    # everything else publishes immediately. We write `published_at`
    # here (not in the changeset helper) because the two-state rule
    # matters for federation timing — federate iff published_at is set.
    published_at =
      if future_datetime?(scheduled_at), do: nil, else: now

    post_attrs =
      attrs
      |> Map.put("id", post_id)
      |> Map.put("ap_id", ap_id)
      |> Map.put("identity_id", identity_id)
      |> Map.put("published_at", published_at)
      |> Map.put("content_html", content_html)
      |> maybe_resolve_root_id()
      |> maybe_resolve_parent_ap_id()

    changeset =
      %Post{}
      |> Post.create_changeset(post_attrs, char_limit: limits[:char_limit] || 5000)
      |> Ecto.Changeset.put_change(:published_at, published_at)
      |> maybe_put_edit_expires_at(edit_expires_at)

    with :ok <- validate_premium_emojis(attrs["content"], identity) do
      insert_post(changeset, attrs)
    end
  end

  defp resolve_limits(nil), do: TierLimits.limits_for_tier("verified_pro")
  defp resolve_limits(identity), do: TierLimits.limits_for(identity)

  # 0 means unlimited editing — TierLimits convention, mirrored by
  # the UI; don't stamp an edit_expires_at in that case.
  defp compute_edit_expires_at(_now, 0), do: nil

  defp compute_edit_expires_at(now, window) do
    now |> DateTime.add(window, :second) |> DateTime.truncate(:microsecond)
  end

  # Markdown level is capped by the author's tier (free → plaintext,
  # verified_pro → full GFM). The composer can opt *down* from that
  # ceiling by passing `markdown: false` (e.g. a pro user posting
  # plain-text). We never let the client opt *up* past their tier.
  defp resolve_markdown_level(attrs, limits) do
    tier_level = limits[:markdown] || "basic"

    case Map.get(attrs, "markdown") do
      false -> "none"
      "false" -> "none"
      0 -> "none"
      _ -> tier_level
    end
  end

  defp maybe_render_content_html(nil, _level), do: nil

  defp maybe_render_content_html(content, level),
    do: Hybridsocial.Content.Sanitizer.sanitize_post_content(content, level)

  defp maybe_put_edit_expires_at(changeset, nil), do: changeset

  defp maybe_put_edit_expires_at(changeset, expires_at),
    do: Ecto.Changeset.put_change(changeset, :edit_expires_at, expires_at)

  defp validate_premium_emojis(nil, _identity), do: :ok
  defp validate_premium_emojis(_content, nil), do: :ok

  defp validate_premium_emojis(content, identity) do
    case Emojis.validate_premium_emoji_access(content, identity) do
      :ok -> :ok
      {:error, shortcodes} -> {:error, :premium_emojis_required, shortcodes}
    end
  end

  defp insert_post(changeset, attrs) do
    case Repo.insert(changeset) do
      {:ok, post} ->
        if post.content, do: extract_and_link_hashtags(post)

        if post.post_type == "poll" do
          poll_attrs = Map.take(attrs, ["options", "multiple_choice", "expires_at"])
          Polls.create_poll(post.id, poll_attrs)
        end

        attach_media(post, Map.get(attrs, "media_ids") || Map.get(attrs, :media_ids) || [])

        # Record mentions so direct-visibility posts surface in the
        # Direct tab for recipients (not just the author) and so
        # mention-based access checks can tell "addressed to you" from
        # "a followers-only post you happened to see the link for".
        mention_ids = persist_local_mentions(post, attrs)
        notify_mentions(post, mention_ids)

        # Increment parent's reply count + notify parent's author if
        # the reply is visible to them. Self-replies are skipped
        # inside notify_reply via the self-notification guard.
        if post.parent_id do
          Post
          |> where([p], p.id == ^post.parent_id)
          |> Repo.update_all(inc: [reply_count: 1])

          notify_reply_to_parent(post)
        end

        # Quote posts notify the quoted author.
        if post.quote_id do
          notify_quote(post)
        end

        post = Repo.preload(post, [:media_attachments, :identity, poll: :options])

        # Scheduled posts defer every side effect that depends on
        # them being "live": no federation, no direct-post fan-out,
        # no PubSub notifications. The scheduler calls
        # `run_post_published_hooks/1` later, at publish time.
        if scheduled_for_future?(post) do
          {:ok, post}
        else
          {:ok, run_post_published_hooks(post)}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp scheduled_for_future?(%Post{scheduled_at: nil}), do: false

  defp scheduled_for_future?(%Post{scheduled_at: scheduled_at, published_at: published_at}) do
    # If `published_at` is already set, we've republished — not
    # scheduled. If `scheduled_at` is in the past, same deal.
    is_nil(published_at) and DateTime.compare(scheduled_at, DateTime.utc_now()) == :gt
  end

  defp future_datetime?(nil), do: false

  defp future_datetime?(%DateTime{} = dt),
    do: DateTime.compare(dt, DateTime.utc_now()) == :gt

  defp future_datetime?(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.compare(dt, DateTime.utc_now()) == :gt
      _ -> false
    end
  end

  defp future_datetime?(_), do: false

  @doc """
  Fires the side effects that always follow a post becoming
  "published" — search indexing, direct-post realtime fan-out, and
  federation. Extracted so the scheduled-post worker can run them
  at publish time, since a scheduled post skips the normal create
  path and would otherwise federate nothing.

  Returns the post unchanged so it can be piped.
  """
  def run_post_published_hooks(%Post{} = post) do
    post = Repo.preload(post, [:media_attachments, :identity, poll: :options])

    # Broadcast for OpenSearch indexing
    Phoenix.PubSub.broadcast(Hybridsocial.PubSub, "posts", {:post_created, post})

    # Fan direct posts out to the recipients' SSE streams so the
    # Direct tab live-updates without a refresh.
    broadcast_direct_post_to_participants(post)

    # Federate public/followers-visible posts to remote followers.
    # Direct + private posts stay local unless sent as a DM; they
    # go through a different delivery path (inbox push for
    # mentioned remote users only).
    maybe_federate_create(post)

    Hybridsocial.Moderation.fire_webhook("post.created", %{
      id: post.id,
      author_id: post.identity_id,
      author_handle: post.identity && post.identity.handle,
      visibility: post.visibility,
      content: post.content,
      created_at: post.inserted_at
    })

    post
  end

  # Fires a Create{Note} activity out to the post author's remote
  # followers via the federation publisher. Runs async in the delivery
  # task supervisor so slow / dead peers don't hold up the insert.
  # Private-visibility + direct posts don't fan out publicly —
  # Publisher.publish handles the audience scoping based on `to`/`cc`.
  defp maybe_federate_create(%Post{visibility: vis} = post)
       when vis in ["public", "followers", "unlisted", "direct"] do
    if post.identity && post.identity.private_key do
      Task.Supervisor.start_child(
        Hybridsocial.Federation.DeliveryTaskSupervisor,
        fn ->
          # Direct posts need their mentions preloaded so the activity
          # builder can target each recipient explicitly; other
          # visibilities fan out via followers/Public addressing and
          # don't need them.
          post =
            if vis == "direct",
              do: Hybridsocial.Repo.preload(post, mentions: :identity),
              else: post

          activity = Hybridsocial.Federation.ActivityBuilder.build_create(post)
          Hybridsocial.Federation.Publisher.publish(activity, post.identity)
        end
      )
    end

    :ok
  end

  defp maybe_federate_create(_post), do: :ok

  @doc """
  Pushes a newly-created direct post to the SSE topic for every local
  participant (author + mentioned identities). The frontend's
  chat-stream already subscribes to `user:<id>`, so adding the
  `direct.new_post` event there lets the profile's Direct tab
  append without polling. No-op for non-direct visibilities — the
  home timeline has its own broadcast path.
  """
  def broadcast_direct_post_to_participants(%Post{visibility: "direct"} = post) do
    post = Repo.preload(post, [:identity, mentions: :identity])

    recipient_ids =
      [post.identity_id | Enum.map(post.mentions, & &1.identity_id)]
      |> Enum.uniq()
      |> Enum.filter(&local_identity?/1)

    # Serialize once; every recipient gets the same payload. No
    # viewer-specific fields here (reactions, bookmarks etc. are
    # fetched on demand when the UI renders the bubble).
    serialized =
      HybridsocialWeb.Serializers.PostSerializer.serialize(post, current_identity_id: nil)

    for rid <- recipient_ids do
      Phoenix.PubSub.broadcast(
        Hybridsocial.PubSub,
        "user:#{rid}",
        %{event: "direct.new_post", payload: serialized}
      )
    end

    :ok
  end

  def broadcast_direct_post_to_participants(_post), do: :ok

  # Accepts either a loaded `%Identity{}` or a binary id. The two
  # clauses are grouped so credo's "same name/arity should be
  # contiguous" warning stays quiet even though callers mix both
  # shapes.
  defp local_identity?(%Hybridsocial.Accounts.Identity{} = identity),
    do: Hybridsocial.Federation.LocalUrl.local_identity?(identity)

  defp local_identity?(identity_id) when is_binary(identity_id) do
    case Repo.get(Hybridsocial.Accounts.Identity, identity_id) do
      %Hybridsocial.Accounts.Identity{} = id ->
        Hybridsocial.Federation.LocalUrl.local_identity?(id)

      _ ->
        false
    end
  end

  # Populates `post_mentions` for a locally-authored post. Sources:
  #   1. Explicit `mentioned_identity_ids` attr — set by flows that
  #      know the audience before composing (e.g. the DM→direct-post
  #      fallback when a user "DMs" a Mastodon account).
  #   2. `@handle` / `@handle@domain` patterns in the post content —
  #      resolved through Accounts so the mention points at the same
  #      identity row the serializer renders.
  defp persist_local_mentions(%Post{id: post_id, content: content}, attrs) do
    explicit_ids =
      attrs
      |> (&(Map.get(&1, "mentioned_identity_ids") || Map.get(&1, :mentioned_identity_ids) || [])).()
      |> List.wrap()

    parsed_ids =
      content
      |> extract_handles()
      |> Enum.map(&resolve_handle_to_identity_id/1)
      |> Enum.reject(&is_nil/1)

    ids = Enum.uniq(explicit_ids ++ parsed_ids)

    for identity_id <- ids do
      %Hybridsocial.Social.PostMention{}
      |> Hybridsocial.Social.PostMention.changeset(%{
        post_id: post_id,
        identity_id: identity_id
      })
      |> Repo.insert(on_conflict: :nothing)
    end

    ids
  end

  defp extract_handles(content), do: Hybridsocial.Federation.LocalUrl.parse_mentions(content)

  # Resolve `@handle` with no explicit domain: must be a local identity.
  defp resolve_handle_to_identity_id({handle, domain}) do
    case Hybridsocial.Federation.LocalUrl.resolve_mention(handle, domain) do
      %Hybridsocial.Accounts.Identity{id: id} -> id
      nil -> nil
    end
  end

  # Attaches the listed media files to the post. Only media owned by the post's
  # author and not already attached to another post are linked; anything else
  # is silently skipped so a bad media_id can't fail a post insert.
  defp attach_media(_post, []), do: :ok
  defp attach_media(_post, nil), do: :ok

  defp attach_media(%Post{id: post_id, identity_id: owner_id}, media_ids)
       when is_list(media_ids) do
    query =
      from m in Hybridsocial.Media.MediaFile,
        where:
          m.id in ^media_ids and
            m.identity_id == ^owner_id and
            is_nil(m.deleted_at) and
            is_nil(m.post_id)

    Repo.update_all(query, set: [post_id: post_id, updated_at: DateTime.utc_now()])
    :ok
  end

  @doc """
  Resolves root_id from parent chain. If the post has a parent_id but no root_id,
  walks up the parent chain to find the root post.
  """
  def maybe_resolve_root_id(%{"parent_id" => parent_id} = attrs)
      when is_binary(parent_id) and parent_id != "" do
    if Map.get(attrs, "root_id") do
      attrs
    else
      case Repo.get(Post, parent_id) do
        nil ->
          attrs

        parent ->
          root_id = parent.root_id || parent.id
          Map.put(attrs, "root_id", root_id)
      end
    end
  end

  def maybe_resolve_root_id(attrs), do: attrs

  @doc """
  If this post is a reply to a mirrored remote post, copy the parent's
  `ap_id` into our `parent_ap_id` so our outbound Create carries the
  ORIGINAL remote URL in `inReplyTo` — not our local mirror URL, which
  the remote wouldn't recognize. Without this, replies from our users
  to federated posts never thread properly on the origin instance.
  """
  def maybe_resolve_parent_ap_id(%{"parent_id" => parent_id} = attrs)
      when is_binary(parent_id) and parent_id != "" do
    if Map.get(attrs, "parent_ap_id") do
      attrs
    else
      case Repo.get(Post, parent_id) do
        %Post{ap_id: ap_id} when is_binary(ap_id) ->
          Map.put(attrs, "parent_ap_id", ap_id)

        _ ->
          attrs
      end
    end
  end

  def maybe_resolve_parent_ap_id(attrs), do: attrs

  def edit_post(post_id, identity_id, attrs, identity \\ nil) do
    with {:ok, post} <- get_owned_post(post_id, identity_id),
         :ok <- validate_premium_emojis(attrs["content"], identity) do
      limits =
        if identity do
          TierLimits.limits_for(identity)
        else
          TierLimits.limits_for_tier("verified_pro")
        end

      revision_number = get_next_revision_number(post_id)

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:revision, fn _ ->
        %PostRevision{}
        |> PostRevision.changeset(%{
          post_id: post.id,
          content: post.content,
          content_html: post.content_html,
          edited_at: post.edited_at || post.inserted_at,
          revision_number: revision_number
        })
      end)
      |> Ecto.Multi.update(:post, fn _ ->
        Post.edit_changeset(post, attrs, char_limit: limits[:char_limit] || 5000)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{post: post}} ->
          if post.content, do: extract_and_link_hashtags(post)

          # Mentions can change between versions. For a direct post
          # that means access changes: someone removed from the
          # mention list should lose read access, and a newly added
          # mention needs to be granted and notified. resync_post_mentions
          # returns the union of old + new identity IDs so the Update
          # activity can be federated wide enough to reach the
          # former audience (so their copy updates/disappears).
          {new_ids, removed_ids} = resync_post_mentions(post, attrs)

          if new_ids != [] do
            notify_mentions(post, new_ids)
          end

          Phoenix.PubSub.broadcast(Hybridsocial.PubSub, "posts", {:post_updated, post})

          # Federate Update to the post's new audience, plus removed
          # recipients so their mirror gets the new content (which
          # drops them from the addressing). Mastodon-class peers
          # drop inbox messages from actors they're not "seeing" the
          # post via, so this is best-effort cleanup.
          federate_update(post, removed_ids)

          {:ok, post}

        {:error, :post, changeset, _} ->
          {:error, changeset}

        {:error, :revision, changeset, _} ->
          {:error, changeset}
      end
    end
  end

  # Diff old post_mentions against the new content's resolved mentions
  # and reconcile. Returns `{new_ids, removed_ids}` so callers can
  # both notify the additions and widen Update federation to include
  # the removals for one more delivery.
  defp resync_post_mentions(%Post{id: post_id, content: content}, _attrs) do
    import Ecto.Query

    current =
      Repo.all(
        from pm in Hybridsocial.Social.PostMention,
          where: pm.post_id == ^post_id,
          select: pm.identity_id
      )

    desired_ids =
      content
      |> (fn c -> Hybridsocial.Federation.LocalUrl.parse_mentions(c) end).()
      |> Enum.map(fn {h, d} ->
        case Hybridsocial.Federation.LocalUrl.resolve_mention(h, d) do
          %Hybridsocial.Accounts.Identity{id: id} -> id
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    to_add = desired_ids -- current
    to_remove = current -- desired_ids

    for identity_id <- to_add do
      %Hybridsocial.Social.PostMention{}
      |> Hybridsocial.Social.PostMention.changeset(%{
        post_id: post_id,
        identity_id: identity_id
      })
      |> Repo.insert(on_conflict: :nothing)
    end

    if to_remove != [] do
      Repo.delete_all(
        from pm in Hybridsocial.Social.PostMention,
          where: pm.post_id == ^post_id and pm.identity_id in ^to_remove
      )
    end

    {to_add, to_remove}
  end

  defp federate_update(%Post{visibility: vis} = post, extra_recipient_ids)
       when vis in ["public", "unlisted", "followers", "direct"] do
    post = Repo.preload(post, [:identity, mentions: :identity])

    if post.identity && post.identity.private_key do
      Task.Supervisor.start_child(
        Hybridsocial.Federation.DeliveryTaskSupervisor,
        fn ->
          activity = Hybridsocial.Federation.ActivityBuilder.build_update(post)
          activity = widen_addressing(activity, extra_recipient_ids)
          Hybridsocial.Federation.Publisher.publish(activity, post.identity)
        end
      )
    end

    :ok
  end

  defp federate_update(_post, _extra), do: :ok

  # For a direct post, append removed recipients' ap_actor_urls to the
  # Update's `to` list so their side gets the new version / drops the
  # old one. No-op for other visibilities since the audience is
  # collection-based, not per-recipient.
  defp widen_addressing(activity, []), do: activity

  defp widen_addressing(%{"object" => %{"type" => "Note"} = note} = activity, extra_ids) do
    extra_urls =
      Hybridsocial.Repo.all(
        from i in Hybridsocial.Accounts.Identity,
          where: i.id in ^extra_ids and not is_nil(i.ap_actor_url),
          select: i.ap_actor_url
      )

    existing = List.wrap(activity["to"])
    widened = Enum.uniq(existing ++ extra_urls)

    activity
    |> Map.put("to", widened)
    |> Map.put("object", Map.put(note, "to", widened))
  end

  defp widen_addressing(activity, _), do: activity

  defp notify_mentions(%Post{} = post, identity_ids) do
    Hybridsocial.Notifications.notify_mention(post.identity_id, post, identity_ids)
  end

  defp notify_reply_to_parent(%Post{parent_id: parent_id} = post)
       when is_binary(parent_id) do
    case get_post(parent_id) do
      nil ->
        :ok

      %Post{} = parent ->
        Hybridsocial.Notifications.notify_reply(post.identity_id, post, parent)
    end
  end

  defp notify_reply_to_parent(_), do: :ok

  defp notify_quote(%Post{quote_id: quote_id} = post) when is_binary(quote_id) do
    case get_post(quote_id) do
      nil ->
        :ok

      %Post{identity_id: quoted_author_id} ->
        Hybridsocial.Notifications.create_notification(%{
          recipient_id: quoted_author_id,
          actor_id: post.identity_id,
          type: "quote",
          target_type: "post",
          target_id: post.id
        })
    end
  end

  defp notify_quote(_), do: :ok

  def delete_post(post_id, identity_id) do
    with {:ok, post} <- get_owned_post(post_id, identity_id) do
      case post |> Post.soft_delete_changeset() |> Repo.update() do
        {:ok, deleted} ->
          Phoenix.PubSub.broadcast(Hybridsocial.PubSub, "posts", {:post_deleted, post_id})
          federate_delete(deleted)

          Hybridsocial.Moderation.fire_webhook("post.deleted", %{
            id: deleted.id,
            author_id: deleted.identity_id,
            deleted_at: deleted.deleted_at
          })

          {:ok, deleted}

        error ->
          error
      end
    end
  end

  # Fan a Delete activity out to the post's original audience so
  # remote mirrors disappear too. Only for locally-authored posts
  # that actually federated — remote-origin posts (mirrors on our
  # side) shouldn't emit Deletes; the peer would reject them for
  # origin mismatch anyway.
  defp federate_delete(%Post{} = post) do
    post = Repo.preload(post, [:identity, mentions: :identity])

    cond do
      post.identity == nil ->
        :ok

      not local_identity?(post.identity) ->
        :ok

      post.visibility not in ["public", "unlisted", "followers", "direct"] ->
        :ok

      true ->
        Task.Supervisor.start_child(
          Hybridsocial.Federation.DeliveryTaskSupervisor,
          fn ->
            activity = Hybridsocial.Federation.ActivityBuilder.build_delete(post)
            Hybridsocial.Federation.Publisher.publish(activity, post.identity)
          end
        )

        :ok
    end
  end

  # --- Post queries ---

  def get_post(id) do
    Post
    |> where([p], is_nil(p.deleted_at))
    |> Repo.get(id)
  end

  def get_post!(id) do
    Post
    |> where([p], is_nil(p.deleted_at))
    |> Repo.get!(id)
  end

  def get_post_with_context(id) do
    Post
    |> where([p], is_nil(p.deleted_at))
    |> Repo.get(id)
    |> case do
      nil -> nil
      post -> Repo.preload(post, [:identity, :parent, :quote, poll: :options])
    end
  end

  @doc """
  Returns the post only if the viewer is allowed to read it. Direct
  posts require the viewer to be the author or a recorded mention;
  followers-only posts require follower status; public/unlisted are
  readable by anyone (auth still enforced at the controller level
  when a DM-free surface is needed). `nil` viewer means anonymous.
  """
  def get_post_for_viewer(id, viewer_identity_id) do
    case get_post(id) do
      nil -> nil
      post -> if viewer_can_read?(post, viewer_identity_id), do: post, else: nil
    end
  end

  @doc """
  Same as `get_post_for_viewer/2` but preloads the context
  associations used by the AP serializer + UI.
  """
  def get_post_with_context_for_viewer(id, viewer_identity_id) do
    case get_post_with_context(id) do
      nil -> nil
      post -> if viewer_can_read?(post, viewer_identity_id), do: post, else: nil
    end
  end

  @doc """
  Predicate form of the viewer access check. Used by controllers and
  activity handlers that already have the post in hand.
  """
  def viewer_can_read?(post, viewer_id)

  def viewer_can_read?(
        %Post{visibility: vis, identity_id: author_id, id: post_id} = post,
        viewer_id
      ) do
    cond do
      vis in ["public", "unlisted"] ->
        true

      is_nil(viewer_id) ->
        false

      viewer_id == author_id ->
        true

      vis == "direct" ->
        mentioned?(post_id, viewer_id)

      vis == "followers" ->
        # Followers-only: viewer must follow the author.
        Hybridsocial.Social.following?(viewer_id, author_id)

      vis == "list" ->
        list_member?(post.list_id, viewer_id)

      vis == "group" ->
        group_member?(post.group_id, viewer_id)

      true ->
        false
    end
  end

  def viewer_can_read?(_, _), do: false

  defp list_member?(nil, _viewer_id), do: false

  defp list_member?(list_id, viewer_id) do
    Repo.exists?(
      from lm in Hybridsocial.Social.ListMember,
        where: lm.list_id == ^list_id and lm.identity_id == ^viewer_id
    )
  end

  defp group_member?(nil, _viewer_id), do: false

  defp group_member?(group_id, viewer_id) do
    Repo.exists?(
      from gm in Hybridsocial.Groups.GroupMember,
        where: gm.group_id == ^group_id and gm.identity_id == ^viewer_id
    )
  end

  defp mentioned?(post_id, identity_id) do
    Repo.exists?(
      from pm in Hybridsocial.Social.PostMention,
        where: pm.post_id == ^post_id and pm.identity_id == ^identity_id
    )
  end

  @doc """
  Fetch many posts in one round-trip. Accepts up to `@max_batch_ids`
  IDs; extras are silently dropped. Missing / soft-deleted IDs are
  skipped (no 404 — the caller knows which IDs they asked for).
  """
  @max_batch_ids 100
  def list_posts_by_ids(ids) when is_list(ids) do
    clean_ids =
      ids
      |> Enum.filter(&is_binary/1)
      |> Enum.take(@max_batch_ids)

    case clean_ids do
      [] ->
        []

      ids ->
        Post
        |> where([p], p.id in ^ids)
        |> where([p], is_nil(p.deleted_at))
        |> Repo.all()
        |> Repo.preload([:identity, :quote, poll: :options])
    end
  end

  def get_thread(post_id) do
    case get_post(post_id) do
      nil ->
        {:error, :not_found}

      post ->
        # Walk up the parent chain to get true ancestors
        ancestors = collect_ancestors(post, [])

        # Descendants: direct replies to this post, and their children
        descendants =
          Post
          |> where([p], is_nil(p.deleted_at))
          |> where([p], p.parent_id == ^post_id or p.root_id == ^post_id)
          |> where([p], p.id != ^post.id)
          |> order_by([p], asc: p.published_at)
          |> Repo.all()
          |> Repo.preload(:identity)

        {:ok, %{ancestors: ancestors, descendants: descendants}}
    end
  end

  # Walk up parent chain to collect true ancestors (max 20 to prevent loops)
  # Includes soft-deleted posts so they render as tombstones
  defp collect_ancestors(%{parent_id: nil}, acc), do: Enum.reverse(acc)
  defp collect_ancestors(_, acc) when length(acc) >= 20, do: Enum.reverse(acc)

  defp collect_ancestors(%{parent_id: parent_id}, acc) when is_binary(parent_id) do
    case Repo.get(Post, parent_id) do
      nil ->
        Enum.reverse(acc)

      parent ->
        parent = Repo.preload(parent, :identity)
        collect_ancestors(parent, [parent | acc])
    end
  end

  defp collect_ancestors(_, acc), do: Enum.reverse(acc)

  def get_revisions(post_id) do
    PostRevision
    |> where([r], r.post_id == ^post_id)
    |> order_by([r], asc: r.revision_number)
    |> Repo.all()
  end

  # --- Reactions ---

  def react(post_id, identity_id, type, opts \\ []) do
    with {:ok, post} <- get_existing_post(post_id) do
      case get_existing_reaction(post_id, identity_id) do
        nil ->
          %Reaction{}
          |> Reaction.changeset(%{post_id: post_id, identity_id: identity_id, type: type}, opts)
          |> Repo.insert()
          |> case do
            {:ok, reaction} ->
              update_reaction_count(post_id, 1)
              # Bell the post's author. Self-reactions are filtered
              # out by create_notification, so we don't guard here.
              Hybridsocial.Notifications.notify_reaction(identity_id, post)
              {:ok, reaction}

            error ->
              error
          end

        existing ->
          # Reaction already exists — either same type (idempotent
          # no-op) or different type (updating emoji). Re-notifying
          # would double-bell, so skip.
          existing
          |> Reaction.changeset(%{type: type}, opts)
          |> Repo.update()
      end
    end
  end

  def unreact(post_id, identity_id) do
    case get_existing_reaction(post_id, identity_id) do
      nil ->
        {:error, :not_found}

      reaction ->
        case Repo.delete(reaction) do
          {:ok, reaction} ->
            update_reaction_count(post_id, -1)
            {:ok, reaction}

          error ->
            error
        end
    end
  end

  def get_reactions(post_id) do
    Reaction
    |> where([r], r.post_id == ^post_id)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
    |> Repo.preload(:identity)
  end

  # --- Boosts ---

  def boost(post_id, identity_id) do
    with {:ok, post} <- get_existing_post(post_id),
         :ok <- check_boost_allowed(post, identity_id) do
      %Boost{}
      |> Boost.changeset(%{post_id: post_id, identity_id: identity_id})
      |> Repo.insert()
      |> case do
        {:ok, boost} ->
          update_boost_count(post_id, 1)
          Hybridsocial.Notifications.notify_boost(identity_id, post)
          {:ok, boost}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # Boosting has two gates: the viewer must be able to read the post
  # in the first place (else it 404s, matching `show`), and the post
  # must be boostable — direct/followers posts aren't, because a
  # boost fans them out to followers which violates the original
  # audience.
  defp check_boost_allowed(post, identity_id) do
    cond do
      not viewer_can_read?(post, identity_id) ->
        {:error, :not_found}

      post.visibility in ["direct", "followers", "list", "group"] ->
        {:error, :boost_not_allowed}

      true ->
        :ok
    end
  end

  def unboost(post_id, identity_id) do
    case get_existing_boost(post_id, identity_id) do
      nil ->
        {:error, :not_found}

      boost ->
        case Repo.delete(boost) do
          {:ok, boost} ->
            update_boost_count(post_id, -1)
            {:ok, boost}

          error ->
            error
        end
    end
  end

  # --- Quote posts ---

  def quote_post(identity_id, quoted_post_id, attrs) do
    with {:ok, _quoted} <- get_existing_post(quoted_post_id) do
      attrs
      |> Map.put("quote_id", quoted_post_id)
      |> then(&create_post(identity_id, &1))
    end
  end

  # --- Pin/Unpin ---

  def reacted_posts(identity_id, opts \\ []) do
    max_id = Keyword.get(opts, :max_id)

    # Get post IDs from reactions, ordered by reaction time
    reaction_query =
      Reaction
      |> where([r], r.identity_id == ^identity_id)
      |> order_by([r], desc: r.inserted_at)
      |> select([r], r.post_id)
      |> limit(20)

    reaction_query =
      if max_id, do: where(reaction_query, [r], r.id < ^max_id), else: reaction_query

    post_ids = Repo.all(reaction_query)

    Post
    |> where([p], p.id in ^post_ids and is_nil(p.deleted_at))
    |> preload([:identity, :quote])
    |> Repo.all()
    |> Enum.sort_by(fn p -> Enum.find_index(post_ids, &(&1 == p.id)) end)
  end

  def pinned_count(identity_id) do
    Post
    |> where([p], p.identity_id == ^identity_id and p.is_pinned == true and is_nil(p.deleted_at))
    |> Repo.aggregate(:count)
  end

  def pin_post(post_id, identity_id) do
    with {:ok, post} <- get_owned_post(post_id, identity_id) do
      post
      |> Ecto.Changeset.change(is_pinned: true)
      |> Repo.update()
    end
  end

  def unpin_post(post_id, identity_id) do
    with {:ok, post} <- get_owned_post(post_id, identity_id) do
      post
      |> Ecto.Changeset.change(is_pinned: false)
      |> Repo.update()
    end
  end

  # --- Hashtags ---

  def extract_hashtags(content) when is_binary(content) do
    ~r/#([a-zA-Z0-9_]+)/
    |> Regex.scan(content)
    |> Enum.map(fn [_, tag] -> String.downcase(tag) end)
    |> Enum.uniq()
  end

  def extract_hashtags(_), do: []

  # --- Identity posts ---

  def posts_by_identity(identity_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)
    max_id = Keyword.get(opts, :max_id)
    exclude_replies = Keyword.get(opts, :exclude_replies, false)
    only_media = Keyword.get(opts, :only_media, false)
    only_direct = Keyword.get(opts, :only_direct, false)

    base =
      Post
      |> where([p], is_nil(p.deleted_at))
      |> order_by([p], desc: p.published_at)
      |> limit(^limit)

    # The "Direct" profile tab is a recipient-facing view: it shows
    # every direct-visibility post the identity is either the author
    # OR explicitly mentioned in. Other tabs (posts/replies/media)
    # stay author-scoped as before.
    query =
      if only_direct do
        mentioned_post_ids =
          from pm in Hybridsocial.Social.PostMention,
            where: pm.identity_id == ^identity_id,
            select: pm.post_id

        base
        |> where([p], p.visibility == "direct")
        |> where([p], p.identity_id == ^identity_id or p.id in subquery(mentioned_post_ids))
      else
        where(base, [p], p.identity_id == ^identity_id)
      end

    query = if max_id, do: where(query, [p], p.id < ^max_id), else: query
    query = if exclude_replies, do: where(query, [p], is_nil(p.parent_id)), else: query
    query = if only_media, do: where(query, [p], p.post_type == "media"), else: query

    Repo.all(query) |> Repo.preload([:identity, :quote])
  end

  # --- Admin operations ---

  @doc """
  Retrieves any post by ID, including private/deleted posts. For admin use only.
  """
  def admin_get_post(post_id) do
    Post
    |> Repo.get(post_id)
    |> case do
      nil -> {:error, :not_found}
      post -> {:ok, Repo.preload(post, [:identity, :parent, :quote, poll: :options])}
    end
  end

  @doc """
  Soft-deletes any post (sets deleted_at) with an audit log entry.
  Also publishes a Delete ActivityPub activity for federated posts.
  """
  def admin_delete_post(post_id, admin_id, reason \\ "") do
    with {:ok, post} <- admin_get_post(post_id),
         {:ok, post} <- do_admin_soft_delete(post) do
      Hybridsocial.Moderation.log(admin_id, "post.admin_deleted", "post", post_id, %{
        reason: reason,
        post_identity_id: post.identity_id
      })

      # Publish Delete activity for federated posts
      if post.ap_id do
        try do
          activity = Hybridsocial.Federation.ActivityBuilder.build_delete(post)
          Hybridsocial.Federation.Publisher.publish(activity, post.identity)
        rescue
          _ -> :ok
        end
      end

      {:ok, post}
    end
  end

  defp do_admin_soft_delete(%Post{deleted_at: nil} = post) do
    post
    |> Post.soft_delete_changeset()
    |> Repo.update()
  end

  defp do_admin_soft_delete(%Post{} = post), do: {:ok, post}

  @doc """
  Force-marks a post as sensitive with an audit log entry.
  """
  def admin_force_sensitive(post_id, admin_id) do
    with {:ok, post} <- admin_get_post(post_id) do
      case post
           |> Ecto.Changeset.change(sensitive: true)
           |> Repo.update() do
        {:ok, updated} ->
          Hybridsocial.Moderation.log(admin_id, "post.force_sensitive", "post", post_id, %{
            post_identity_id: post.identity_id
          })

          {:ok, updated}

        error ->
          error
      end
    end
  end

  @doc """
  Removes forced sensitive marking from a post with an audit log entry.
  """
  def admin_remove_sensitive(post_id, admin_id) do
    with {:ok, post} <- admin_get_post(post_id) do
      case post
           |> Ecto.Changeset.change(sensitive: false)
           |> Repo.update() do
        {:ok, updated} ->
          Hybridsocial.Moderation.log(admin_id, "post.remove_sensitive", "post", post_id, %{
            post_identity_id: post.identity_id
          })

          {:ok, updated}

        error ->
          error
      end
    end
  end

  # --- Private helpers ---

  defp get_owned_post(post_id, identity_id) do
    Post
    |> where([p], is_nil(p.deleted_at))
    |> Repo.get(post_id)
    |> case do
      nil -> {:error, :not_found}
      %Post{identity_id: ^identity_id} = post -> {:ok, post}
      _post -> {:error, :forbidden}
    end
  end

  defp get_existing_post(post_id) do
    case get_post(post_id) do
      nil -> {:error, :not_found}
      post -> {:ok, post}
    end
  end

  defp get_existing_reaction(post_id, identity_id) do
    Reaction
    |> where([r], r.post_id == ^post_id and r.identity_id == ^identity_id)
    |> Repo.one()
  end

  defp get_existing_boost(post_id, identity_id) do
    Boost
    |> where(
      [b],
      b.post_id == ^post_id and b.identity_id == ^identity_id and is_nil(b.deleted_at)
    )
    |> Repo.one()
  end

  defp update_reaction_count(post_id, delta) do
    Post
    |> where([p], p.id == ^post_id)
    |> Repo.update_all(inc: [reaction_count: delta])
  end

  defp update_boost_count(post_id, delta) do
    Post
    |> where([p], p.id == ^post_id)
    |> Repo.update_all(inc: [boost_count: delta])
  end

  defp get_next_revision_number(post_id) do
    PostRevision
    |> where([r], r.post_id == ^post_id)
    |> select([r], count(r.id))
    |> Repo.one()
    |> Kernel.+(1)
  end

  defp extract_and_link_hashtags(post) do
    tags = extract_hashtags(post.content)

    Enum.each(tags, fn tag_name ->
      {:ok, hashtag} = upsert_hashtag(tag_name)
      link_post_hashtag(post.id, hashtag.id)
    end)
  end

  defp upsert_hashtag(name) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Hashtag{}
    |> Hashtag.changeset(%{name: name})
    |> Repo.insert(
      on_conflict: [inc: [usage_count: 1]],
      conflict_target: [:name],
      returning: true,
      set: [usage_count: dynamic([h], h.usage_count + 1), updated_at: now]
    )
  end

  defp link_post_hashtag(post_id, hashtag_id) do
    {:ok, post_uuid} = Ecto.UUID.dump(post_id)
    {:ok, hashtag_uuid} = Ecto.UUID.dump(hashtag_id)

    Repo.insert_all(
      "post_hashtags",
      [%{post_id: post_uuid, hashtag_id: hashtag_uuid}],
      on_conflict: :nothing,
      conflict_target: [:post_id, :hashtag_id]
    )
  end
end
