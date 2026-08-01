defmodule Hybridsocial.Federation.DeadActors do
  @moduledoc """
  Retires remote identities whose own server says they no longer exist.

  When a remote account is deleted, its server starts answering `410
  Gone` (or a webfinger-confirmed `404`) for that actor — but we kept
  the follow row forever and kept fanning every activity out to a
  mailbox nobody will ever read. One dead follower produces one dead
  letter per post, indefinitely; a handful of them is most of the
  dead-letter queue on a small instance.

  Detection is deliberately conservative, because the cost of a false
  positive (silently dropping a live follower) is much higher than the
  cost of leaving a dead one in place for another day:

    * `410 Gone` — unambiguous, the server is telling us it's deleted.
    * `404` **plus** a webfinger 404 — how Friendica and several others
      spell the same thing.

  Anything else is left alone. A `500`, a timeout, a TLS error or a
  bare `404` on an actor whose webfinger still resolves all mean "we
  don't know", and "we don't know" must never delete anything. Threads
  is the worked example: its actor endpoint answers `500` to signed
  fetches even for live accounts, so it never becomes a candidate.

  Removing the follow rows is what actually stops the delivery. Purging
  the identity's content is a separate, opt-in step
  (`federation_dead_actor_purge_content`, default off) since that
  destroys cached posts that are still perfectly readable in a thread.
  """

  import Ecto.Query
  require Logger

  alias Hybridsocial.Accounts.Identity
  alias Hybridsocial.Federation.{Delivery, SignedFetch, WebFinger}
  alias Hybridsocial.Repo
  alias Hybridsocial.Social.Follow

  @default_failure_threshold 5
  @default_candidate_limit 50

  @doc """
  Remote identities whose inbox has piled up at least
  `failure_threshold` failed deliveries that came back `404`/`410`.

  Connection-level failures are excluded on purpose: `:nxdomain` means
  the *instance* is gone, which is what the per-domain delivery switch
  is for. This is about a live server telling us one account is gone.
  """
  def candidates(opts \\ []) do
    threshold = Keyword.get(opts, :failure_threshold, failure_threshold())
    limit = Keyword.get(opts, :limit, @default_candidate_limit)

    inbox_counts =
      from(d in Delivery,
        where: d.status == "failed",
        where: like(d.error, "HTTP 404:%") or like(d.error, "HTTP 410:%"),
        group_by: d.target_inbox,
        having: count(d.id) >= ^threshold,
        order_by: [desc: count(d.id)],
        limit: ^limit,
        select: {d.target_inbox, count(d.id)}
      )
      |> Repo.all()

    inboxes = Enum.map(inbox_counts, &elem(&1, 0))
    counts = Map.new(inbox_counts)

    from(i in Identity,
      where: i.inbox_url in ^inboxes,
      where: i.is_local == false,
      where: is_nil(i.deleted_at)
    )
    |> Repo.all()
    |> Enum.map(fn identity ->
      %{identity: identity, failures: Map.get(counts, identity.inbox_url, 0)}
    end)
    |> Enum.sort_by(& &1.failures, :desc)
  end

  @doc """
  Asks the remote server whether this actor still exists.

  Returns `{:gone, reason}` only on proof, `:alive` when the actor
  still resolves, and `:unknown` for everything else — including every
  network-level error, so an outage can never be mistaken for a
  deletion.
  """
  def verify(%Identity{ap_actor_url: url} = identity) when is_binary(url) do
    case SignedFetch.get(url) do
      {:ok, %{status_code: 410}} ->
        {:gone, "actor returned 410 Gone"}

      {:ok, %{status_code: 404}} ->
        # A bare 404 is ambiguous: some servers 404 actor fetches they
        # don't want to answer. Webfinger is the second opinion — if
        # the handle doesn't resolve either, the account is really gone.
        confirm_via_webfinger(identity)

      {:ok, %{status_code: status}} when status in 200..299 ->
        :alive

      {:ok, %{status_code: _}} ->
        :unknown

      {:error, _} ->
        :unknown
    end
  end

  def verify(_), do: :unknown

  defp confirm_via_webfinger(%Identity{ap_actor_url: url}) do
    case acct_from_actor_url(url) do
      {:ok, acct} ->
        case WebFinger.finger(acct) do
          {:error, :not_found} -> {:gone, "actor 404 and webfinger 404"}
          _ -> :unknown
        end

      :error ->
        :unknown
    end
  end

  # The stored `handle` is suffixed for remote actors
  # (`abidin24_libranet_de_003f4a81`, `a_plsee_threads_net_9fbee321`),
  # so it can't be split back into a username — the username itself may
  # contain underscores. The actor URL's last path segment is the
  # authoritative name, same derivation the account serializer uses.
  defp acct_from_actor_url(url) when is_binary(url) do
    uri = URI.parse(url)

    username =
      (uri.path || "")
      |> String.split("/", trim: true)
      |> List.last()

    case {uri.host, username} do
      {host, name} when is_binary(host) and is_binary(name) and name != "" ->
        {:ok, "#{name}@#{host}"}

      _ ->
        :error
    end
  end

  defp acct_from_actor_url(_), do: :error

  @doc """
  Retires a confirmed-gone actor: drops every follow edge it is part
  of (which is what stops delivery), then clears the failed delivery
  rows aimed at its inbox so the queue reflects reality.

  Content is only purged when `federation_dead_actor_purge_content` is
  on. Returns a stats map.
  """
  def retire(%Identity{} = identity, reason) do
    {follows, _} =
      from(f in Follow,
        where: f.follower_id == ^identity.id or f.followee_id == ^identity.id
      )
      |> Repo.delete_all()

    {dead_letters, _} =
      from(d in Delivery,
        where: d.status == "failed" and d.target_inbox == ^identity.inbox_url
      )
      |> Repo.delete_all()

    purged = maybe_purge_content(identity)

    Logger.info(
      "[dead-actor] retired #{identity.ap_actor_url} (#{reason}): " <>
        "#{follows} follow(s), #{dead_letters} dead letter(s), #{purged} post(s)"
    )

    %{
      actor: identity.ap_actor_url,
      reason: reason,
      follows_removed: follows,
      dead_letters_dropped: dead_letters,
      posts_purged: purged
    }
  end

  defp maybe_purge_content(%Identity{} = identity) do
    if purge_content?() do
      now = DateTime.utc_now()

      {count, _} =
        from(p in Hybridsocial.Social.Post,
          where: p.identity_id == ^identity.id and is_nil(p.deleted_at)
        )
        |> Repo.update_all(set: [deleted_at: now])

      identity |> Identity.soft_delete_changeset() |> Repo.update()
      count
    else
      0
    end
  end

  @doc """
  Finds candidates, verifies each against its home server, and retires
  the ones proven gone.

  Options:
    * `:dry_run` — verify and report, change nothing (default `false`)
    * `:limit` / `:failure_threshold` — override the configured values

  Returns `%{checked:, retired:, alive:, unknown:, details: [...]}`.
  """
  def sweep(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    results =
      opts
      |> candidates()
      |> Enum.map(fn %{identity: identity, failures: failures} ->
        verdict = verify(identity)

        detail = %{
          actor: identity.ap_actor_url,
          handle: identity.handle,
          failures: failures,
          verdict: verdict_name(verdict)
        }

        case verdict do
          {:gone, reason} when not dry_run ->
            Map.merge(detail, retire(identity, reason))

          {:gone, reason} ->
            Map.merge(detail, %{reason: reason, dry_run: true})

          _ ->
            detail
        end
      end)

    %{
      checked: length(results),
      retired: Enum.count(results, &(&1.verdict == "gone")),
      alive: Enum.count(results, &(&1.verdict == "alive")),
      unknown: Enum.count(results, &(&1.verdict == "unknown")),
      dry_run: dry_run,
      details: results
    }
  end

  defp verdict_name({:gone, _}), do: "gone"
  defp verdict_name(:alive), do: "alive"
  defp verdict_name(_), do: "unknown"

  @doc """
  Handles an inbound `Delete` whose object is the actor itself — a
  remote account announcing its own deletion. Without this the
  activity fell through the post-delete branch as "already deleted"
  and the follower stayed on our books forever, which is the other
  half of how dead followers accumulate.
  """
  def handle_self_delete(actor_ap_id) when is_binary(actor_ap_id) do
    case Repo.get_by(Identity, ap_actor_url: actor_ap_id, is_local: false) do
      nil ->
        {:ok, :unknown_actor}

      %Identity{} = identity ->
        {:ok, retire(identity, "actor announced its own deletion")}
    end
  end

  # --- config ---

  def failure_threshold do
    positive_int("federation_dead_actor_failure_threshold", @default_failure_threshold)
  end

  def purge_content? do
    Hybridsocial.Config.get("federation_dead_actor_purge_content", false) == true
  end

  defp positive_int(key, default) do
    case Hybridsocial.Config.get(key, default) do
      n when is_integer(n) and n > 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {i, _} when i > 0 -> i
          _ -> default
        end

      _ ->
        default
    end
  end
end
