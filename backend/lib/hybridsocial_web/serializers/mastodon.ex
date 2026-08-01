defmodule HybridsocialWeb.Serializers.Mastodon do
  @moduledoc """
  Projects our API payloads into Mastodon's REST shapes.

  The internal model is the source of truth and its serializers keep their own
  field names (`reply_count`, `handle`, `bio`, `is_boosted`); this module is a
  pure remap of their output, in the same spirit as the ActivityPub layer —
  a projection, never the thing itself. Nothing here queries.

  Two rules make the difference between "looks right" and "the client renders":

    * Mastodon's models declare most fields non-null. A missing `username` or
      a null `avatar` is a deserialization crash in Tusky/Husky, not a blank
      field, so every required key is filled with a typed empty value.
    * Payloads that came back out of the feed cache have string keys, because
      they round-tripped through JSON. Every read goes through `get/2`, which
      accepts either.
  """

  alias HybridsocialWeb.Endpoint

  @default_avatar "/images/default-avatar.svg"

  # Ours -> Mastodon. `group` and `list` have no equivalent; they map to the
  # nearest scope that does not over-share them.
  @visibility %{
    "public" => "public",
    "unlisted" => "unlisted",
    "followers" => "private",
    "direct" => "direct",
    "group" => "unlisted",
    "list" => "private"
  }

  # Mastodon -> ours, for inbound status params.
  @inbound_visibility %{
    "public" => "public",
    "unlisted" => "unlisted",
    "private" => "followers",
    "direct" => "direct"
  }

  @notification_types %{
    "reaction" => "favourite",
    "favourite" => "favourite",
    "boost" => "reblog",
    "reblog" => "reblog",
    "reply" => "mention",
    "mention" => "mention",
    "quote" => "mention",
    "follow" => "follow",
    "follow_request" => "follow_request",
    "poll" => "poll",
    "poll_ended" => "poll",
    "status" => "status",
    "update" => "update"
  }

  # --- Status ---

  @doc """
  A serialized post, or a home-timeline boost entry (which becomes Mastodon's
  reblog wrapper: an empty status by the booster carrying the original).
  """
  def status(nil), do: nil

  def status(%{} = entry) do
    case get(entry, :type) do
      "boost" ->
        reblog_wrapper(entry)

      # A gap in a thread where a post was deleted. We render a placeholder;
      # Mastodon has no such concept and its Status.account is non-null, so
      # the entry is dropped rather than sent as a status with no author.
      "tombstone" ->
        nil

      _ ->
        plain_status(entry)
    end
  end

  def statuses(list) when is_list(list) do
    list
    |> Enum.map(&status/1)
    |> Enum.reject(&is_nil/1)
  end

  def statuses(other), do: other

  defp plain_status(post) do
    %{
      id: get(post, :id),
      uri: get(post, :uri),
      url: get(post, :url),
      created_at: timestamp(get(post, :created_at)),
      edited_at: timestamp(get(post, :edited_at)),
      account: account(get(post, :account)),
      # Mastodon renders `content` as HTML; the raw source goes in `text`,
      # which is what an edit-capable client reads back.
      content: get(post, :content_html) || "",
      text: get(post, :content),
      in_reply_to_id: get(post, :parent_id),
      in_reply_to_account_id: get(post, :in_reply_to_account_id),
      reblog: nil,
      visibility: Map.get(@visibility, to_string(get(post, :visibility) || "public"), "public"),
      sensitive: bool(get(post, :sensitive)),
      spoiler_text: get(post, :spoiler_text) || "",
      language: get(post, :language),
      # Reactions are our superset of favourites; the count a Mastodon client
      # shows is the total across every emoji.
      favourites_count: int(get(post, :reaction_count)),
      favourited: get(post, :current_user_reaction) != nil,
      reblogs_count: int(get(post, :boost_count)),
      reblogged: bool(get(post, :is_boosted)),
      replies_count: int(get(post, :reply_count)),
      bookmarked: bool(get(post, :is_bookmarked)),
      pinned: bool(get(post, :is_pinned)),
      muted: bool(get(post, :is_muted)),
      media_attachments: Enum.map(list_of(get(post, :media_attachments)), &media_attachment/1),
      mentions: Enum.map(list_of(get(post, :mentions)), &mention/1),
      tags: Enum.map(list_of(get(post, :tags)), &tag/1),
      emojis: Enum.map(list_of(get(post, :emojis)), &emoji/1),
      card: card(get(post, :card)),
      poll: poll(get(post, :poll)),
      application: nil,
      # Filtering is applied server-side; clients expect the key to exist.
      filtered: []
    }
  end

  # A boost entry carries the booster in `account` and the original in `post`.
  defp reblog_wrapper(entry) do
    inner = plain_status(get(entry, :post) || %{})

    %{
      inner
      | id: get(entry, :id),
        uri: nil,
        url: nil,
        created_at: timestamp(get(entry, :created_at)),
        edited_at: nil,
        account: account(get(entry, :account)),
        content: "",
        text: nil,
        reblog: inner,
        favourites_count: 0,
        favourited: false,
        reblogs_count: 0,
        reblogged: true,
        replies_count: 0,
        bookmarked: false,
        pinned: false,
        muted: false,
        media_attachments: [],
        mentions: [],
        tags: [],
        emojis: [],
        card: nil,
        poll: nil
    }
  end

  # --- Account ---

  def account(nil), do: nil

  def account(%{} = acct) do
    handle = get(acct, :handle) || ""
    avatar = absolute(get(acct, :avatar_url)) || absolute(@default_avatar)
    header = absolute(get(acct, :header_url)) || ""

    %{
      id: get(acct, :id),
      username: handle,
      acct: get(acct, :acct) || handle,
      display_name: get(acct, :display_name) || handle,
      # `bio_html` is absent from the compact account embedded in a status;
      # falling back to the raw bio beats emitting null on a non-null field.
      note: get(acct, :bio_html) || get(acct, :bio) || "",
      url: get(acct, :url) || "#{Endpoint.url()}/@#{handle}",
      avatar: avatar,
      avatar_static: avatar,
      header: header,
      header_static: header,
      locked: bool(get(acct, :is_locked)),
      bot: bool(get(acct, :is_bot)),
      group: get(acct, :type) == "group",
      discoverable: get(acct, :discoverable),
      created_at: timestamp(get(acct, :created_at)),
      followers_count: int(get(acct, :followers_count)),
      following_count: int(get(acct, :following_count)),
      statuses_count: int(get(acct, :statuses_count)),
      last_status_at: nil,
      fields: Enum.map(list_of(get(acct, :profile_fields)), &profile_field/1),
      emojis: Enum.map(list_of(get(acct, :emojis)), &emoji/1)
    }
  end

  def accounts(list) when is_list(list), do: Enum.map(list, &account/1)
  def accounts(other), do: other

  @doc "Adds the fields only `verify_credentials` carries."
  def credential_account(acct, source_extras \\ %{}) do
    base = account(acct)

    Map.merge(base, %{
      source: %{
        note: get(acct, :bio) || "",
        fields: base.fields,
        privacy:
          Map.get(@visibility, to_string(Map.get(source_extras, :privacy, "public")), "public"),
        sensitive: bool(Map.get(source_extras, :sensitive)),
        language: Map.get(source_extras, :language),
        follow_requests_count: int(Map.get(source_extras, :follow_requests_count))
      },
      role: nil
    })
  end

  defp profile_field(%{} = field) do
    %{
      name: get(field, :name) || "",
      value: get(field, :value) || "",
      verified_at: timestamp(get(field, :verified_at))
    }
  end

  defp profile_field(_), do: %{name: "", value: "", verified_at: nil}

  # --- Relationship ---

  def relationship(%{} = rel) do
    %{
      id: get(rel, :id),
      following: bool(get(rel, :following)),
      followed_by: bool(get(rel, :followed_by)),
      requested: bool(get(rel, :requested)),
      requested_by: false,
      blocking: bool(get(rel, :blocking)),
      blocked_by: bool(get(rel, :blocked_by)),
      muting: bool(get(rel, :muting)),
      muting_notifications: bool(get(rel, :muting)),
      # We model boost muting per-account elsewhere; absent here means the
      # default (boosts shown).
      showing_reblogs: not bool(get(rel, :muting_boosts)),
      notifying: false,
      domain_blocking: bool(get(rel, :domain_blocking)),
      endorsed: false,
      note: get(rel, :note) || ""
    }
  end

  def relationships(list) when is_list(list), do: Enum.map(list, &relationship/1)
  def relationships(other), do: other

  # --- Notification ---

  def notification(%{} = notif) do
    %{
      id: get(notif, :id),
      type: Map.get(@notification_types, to_string(get(notif, :type) || ""), "mention"),
      created_at: timestamp(get(notif, :created_at)),
      account: account(get(notif, :account)),
      status: status(get(notif, :post))
    }
  end

  def notifications(list) when is_list(list), do: Enum.map(list, &notification/1)
  def notifications(other), do: other

  # --- Context, search ---

  def context(%{} = ctx) do
    %{
      ancestors: statuses(list_of(get(ctx, :ancestors))),
      descendants: statuses(list_of(get(ctx, :descendants)))
    }
  end

  def search(%{} = results) do
    %{
      accounts: accounts(list_of(get(results, :accounts))),
      statuses: statuses(list_of(get(results, :statuses) || get(results, :posts))),
      hashtags: Enum.map(list_of(get(results, :hashtags)), &tag/1)
    }
  end

  # --- Leaf objects ---

  def media_attachment(%{} = media) do
    %{
      id: get(media, :id),
      type: get(media, :type) || "unknown",
      url: absolute(get(media, :url)),
      preview_url: absolute(get(media, :preview_url) || get(media, :url)),
      remote_url: get(media, :remote_url),
      description: get(media, :description),
      blurhash: get(media, :blurhash),
      meta: get(media, :meta) || %{},
      # Mastodon kept this for pre-2.0 clients; some still read it.
      text_url: nil
    }
  end

  def media_attachment(other), do: other

  # Our mention extraction only recovers the acct; a client needs the key to
  # exist even when we can't resolve an id for it.
  defp mention(%{} = m) do
    acct = get(m, :acct) || ""

    %{
      id: get(m, :id),
      username: acct |> to_string() |> String.split("@") |> List.first(),
      acct: acct,
      url: get(m, :url) || "#{Endpoint.url()}/@#{acct}"
    }
  end

  defp mention(other), do: other

  defp tag(%{} = t) do
    name = get(t, :slug) || get(t, :name) || ""

    %{
      name: name,
      url: get(t, :url) || "#{Endpoint.url()}/tags/#{name}",
      history: list_of(get(t, :history))
    }
  end

  defp tag(other), do: other

  defp emoji(%{} = e) do
    url = absolute(get(e, :url) || get(e, :image_url))

    %{
      shortcode: get(e, :shortcode),
      url: url,
      static_url: absolute(get(e, :static_url)) || url,
      visible_in_picker: true,
      category: get(e, :category)
    }
  end

  defp emoji(other), do: other

  def emojis(list) when is_list(list), do: Enum.map(list, &emoji/1)
  def emojis(other), do: other

  defp card(nil), do: nil

  defp card(%{} = c) do
    %{
      url: get(c, :url),
      title: get(c, :title) || "",
      description: get(c, :description) || "",
      type: "link",
      author_name: "",
      author_url: "",
      provider_name: get(c, :provider_name) || "",
      provider_url: "",
      html: "",
      width: int(get(c, :width)),
      height: int(get(c, :height)),
      image: absolute(get(c, :image)),
      embed_url: "",
      blurhash: get(c, :blurhash)
    }
  end

  defp card(_), do: nil

  defp poll(nil), do: nil

  defp poll(%{} = p) do
    %{
      id: get(p, :id),
      expires_at: timestamp(get(p, :expires_at)),
      expired: bool(get(p, :expired)),
      multiple: bool(get(p, :multiple)),
      votes_count: int(get(p, :votes_count)),
      voters_count: get(p, :voters_count),
      voted: bool(get(p, :voted)),
      own_votes: list_of(get(p, :own_votes)),
      options:
        Enum.map(list_of(get(p, :options)), fn o ->
          %{title: get(o, :title) || "", votes_count: int(get(o, :votes_count))}
        end),
      emojis: []
    }
  end

  defp poll(_), do: nil

  # --- Instance ---

  @doc "Mastodon's `GET /api/v1/instance` (the 1.x shape)."
  def instance_v1(info) do
    config = get(info, :configuration) || %{}
    statuses = get(config, :statuses) || %{}
    media = get(config, :media_attachments) || %{}
    stats = get(info, :stats) || %{}

    %{
      uri: get(info, :uri),
      title: get(info, :title),
      short_description: get(info, :short_description) || "",
      description: get(info, :description) || "",
      email: get(info, :email) || "",
      version: get(info, :version),
      urls: get(info, :urls) || %{},
      stats: %{
        user_count: int(get(stats, :user_count) || get(stats, :users)),
        status_count: int(get(stats, :status_count) || get(stats, :posts)),
        domain_count: int(get(stats, :domain_count) || get(stats, :domains))
      },
      thumbnail: get(info, :thumbnail),
      languages: list_of(get(info, :languages)),
      registrations: bool(get(info, :registrations)),
      approval_required: bool(get(info, :approval_required)),
      invites_enabled: bool(get(info, :invites_enabled)),
      configuration: %{
        statuses: %{
          max_characters: int(get(statuses, :max_characters)),
          max_media_attachments: int(get(statuses, :max_media_attachments)),
          characters_reserved_per_url: int(get(statuses, :characters_reserved_per_url))
        },
        media_attachments: media,
        polls: get(config, :polls) || %{}
      },
      # Already emitted in Mastodon's shape by Instance.info/0.
      contact_account: get(info, :contact_account),
      rules: list_of(get(info, :rules))
    }
  end

  @doc "Mastodon's `GET /api/v2/instance`, which 4.x clients prefer."
  def instance_v2(info) do
    v1 = instance_v1(info)

    %{
      domain: v1.uri,
      title: v1.title,
      version: v1.version,
      source_url: get(info, :source_url),
      description: v1.description,
      usage: %{users: %{active_month: v1.stats.user_count}},
      thumbnail: %{url: v1.thumbnail},
      languages: v1.languages,
      configuration:
        Map.merge(v1.configuration, %{
          urls: %{streaming: get(v1.urls, :streaming_api) || get(v1.urls, "streaming_api")},
          accounts: %{max_featured_tags: 10},
          translation: %{enabled: false}
        }),
      registrations: %{
        enabled: v1.registrations,
        approval_required: v1.approval_required,
        message: nil
      },
      contact: %{email: v1.email, account: v1.contact_account},
      rules: v1.rules
    }
  end

  # --- Inbound params ---

  @doc """
  Normalizes Mastodon's status-creation params to ours.

  Applied unconditionally: these are aliases, so accepting them costs a
  first-party client nothing and is what lets a third-party client post at all.
  """
  def normalize_status_params(params) when is_map(params) do
    params
    |> alias_param("status", "content")
    |> alias_param("in_reply_to_id", "parent_id")
    |> normalize_visibility()
    |> normalize_poll()
  end

  def normalize_status_params(params), do: params

  defp alias_param(params, from, to) do
    case {Map.get(params, from), Map.get(params, to)} do
      {nil, _} -> params
      {_, existing} when existing not in [nil, ""] -> params
      {value, _} -> Map.put(params, to, value)
    end
  end

  defp normalize_visibility(params) do
    case Map.get(params, "visibility") do
      nil ->
        params

      value ->
        Map.put(params, "visibility", Map.get(@inbound_visibility, to_string(value), value))
    end
  end

  # `poll[options][]` / `poll[expires_in]` become our flat options +
  # expires_at, and the post becomes a poll.
  defp normalize_poll(%{"poll" => %{} = poll} = params) do
    options = list_of(Map.get(poll, "options"))

    if options == [] do
      params
    else
      params
      |> Map.put("post_type", "poll")
      |> Map.put("options", options)
      |> Map.put("multiple_choice", bool(Map.get(poll, "multiple")))
      |> put_poll_expiry(Map.get(poll, "expires_in"))
    end
  end

  defp normalize_poll(params), do: params

  defp put_poll_expiry(params, nil), do: params

  defp put_poll_expiry(params, expires_in) do
    case to_int(expires_in) do
      nil ->
        params

      seconds ->
        Map.put(params, "expires_at", DateTime.add(DateTime.utc_now(), seconds, :second))
    end
  end

  # --- Shared helpers ---

  # Payloads out of the feed cache have string keys; fresh ones have atoms.
  defp get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_, _), do: nil

  defp list_of(list) when is_list(list), do: list
  defp list_of(_), do: []

  defp bool(true), do: true
  defp bool("true"), do: true
  defp bool(_), do: false

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp to_int(_), do: nil

  # Mastodon expects ISO8601 with a `Z`; our datetimes serialize that way
  # already, and cached payloads arrive as strings that are already correct.
  defp timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp timestamp(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp timestamp(value) when is_binary(value), do: value
  defp timestamp(_), do: nil

  # Clients resolve nothing: every URL has to be absolute.
  defp absolute(nil), do: nil
  defp absolute(""), do: nil

  defp absolute("/" <> _ = path), do: Endpoint.url() <> path

  defp absolute(url) when is_binary(url), do: url
  defp absolute(_), do: nil
end
