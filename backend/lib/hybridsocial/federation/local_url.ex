defmodule Hybridsocial.Federation.LocalUrl do
  @moduledoc """
  Single source of truth for "is this AP URL hosted on us?". Three
  different call sites (Posts, Messaging, Inbox) used to answer this
  with subtly different implementations — an `ap_actor_url == base`
  check here, a `String.starts_with?(base <> "/actors/")` check there,
  and a `URI.parse` host comparison somewhere else. That's a class
  of bug where a fix in one spot leaves the others wrong; this module
  exists so there's exactly one answer.
  """

  alias Hybridsocial.Accounts.Identity

  @doc """
  True when the URL points at an actor hosted on our instance.
  Accepts `nil` (treated as local — a local identity row may have
  its `ap_actor_url` populated lazily after creation).
  """
  def local_actor_url?(nil), do: true

  def local_actor_url?(url) when is_binary(url) do
    String.starts_with?(url, actor_prefix())
  end

  def local_actor_url?(_), do: false

  @doc """
  True when the identity row belongs to a local actor.

  Prefers the explicit `is_local` flag (set on every insert path); falls
  back to the `/actors/` URL-prefix heuristic only for rows predating the
  flag where it's still `nil`. Imported legacy actors have a foreign-shaped
  `ap_actor_url` but `is_local = true`, so the flag is authoritative.
  """
  def local_identity?(%Identity{is_local: true}), do: true
  def local_identity?(%Identity{is_local: false}), do: false
  def local_identity?(%Identity{is_local: nil, ap_actor_url: url}), do: local_actor_url?(url)
  def local_identity?(_), do: false

  @doc """
  True for any URL (actor, post, DM, activity) hosted on our
  instance. Used by the federation publisher to avoid self-delivery.
  """
  def local_url?(nil), do: false

  def local_url?(url) when is_binary(url) do
    base = base_url()
    String.starts_with?(url, base <> "/") or url == base
  end

  def local_url?(_), do: false

  @doc "The `{base}/actors/` prefix — lets callers build local actor URLs consistently."
  def actor_prefix, do: base_url() <> "/actors/"

  @doc "The instance base URL (scheme + host, no trailing slash)."
  def base_url, do: HybridsocialWeb.Endpoint.url()

  @mention_regex ~r/@([a-zA-Z0-9_]+)(?:@([a-zA-Z0-9.\-]+))?/

  @doc """
  Parses `@handle` and `@handle@domain` tokens from content, returning
  a list of `{handle, domain_or_nil}` tuples. One place so fixes
  (new TLDs, IDN handling, etc.) apply everywhere.
  """
  def parse_mentions(nil), do: []

  def parse_mentions(content) when is_binary(content) do
    @mention_regex
    |> Regex.scan(content)
    |> Enum.map(fn
      [_, handle, ""] -> {handle, nil}
      [_, handle] -> {handle, nil}
      [_, handle, domain] -> {handle, domain}
    end)
  end

  @doc """
  Resolves a parsed `@handle` / `@handle@domain` pair to a stored
  Identity, matching local rows by handle and remote rows by
  `ap_actor_url` host + trailing path segment. Returns `nil` if the
  actor isn't cached locally (we don't auto-resolve to keep mention
  parsing synchronous).
  """
  def resolve_mention(handle, nil), do: resolve_local_handle(handle)

  def resolve_mention(handle, domain) when is_binary(domain) do
    if domain == URI.parse(base_url()).host do
      resolve_local_handle(handle)
    else
      resolve_remote_mention(handle, domain)
    end
  end

  defp resolve_local_handle(handle) do
    case Hybridsocial.Repo.get_by(Identity, handle: handle) do
      %Identity{} = id ->
        if local_identity?(id), do: id, else: nil

      _ ->
        nil
    end
  end

  defp resolve_remote_mention(handle, domain) do
    import Ecto.Query
    pattern = "%://" <> domain <> "/%"

    Hybridsocial.Repo.one(
      from i in Identity,
        where: like(i.ap_actor_url, ^pattern),
        where: fragment("split_part(?, '/', -1) = ?", i.ap_actor_url, ^handle),
        limit: 1
    )
  end
end
