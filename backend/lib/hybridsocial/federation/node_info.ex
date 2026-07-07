defmodule Hybridsocial.Federation.NodeInfo do
  @moduledoc """
  Resolves the software name running on a remote instance via
  [NodeInfo](https://nodeinfo.diaspora.software/), caching the
  answer in `remote_instances` so outbound DM routing doesn't pay
  the discovery cost on every send.

  The only flag we actually act on today is `chat_capable?/1` —
  Pleroma / Akkoma expose a real one-on-one DM primitive
  (`Create{ChatMessage}`). Everywhere else, DMs from our compose UI
  silently fall back to direct-visibility posts (which is how
  Mastodon, Misskey and friends already model "DMs" under the
  hood).
  """

  require Logger

  alias Hybridsocial.Federation.RemoteInstance
  alias Hybridsocial.Repo

  # Re-fetch NodeInfo for an instance no more than once a week.
  # Software upgrades are infrequent and the consequence of a stale
  # answer is routing to the wrong activity type, which is survivable.
  @refetch_after_seconds 7 * 24 * 60 * 60

  # Feature strings that mean "this peer accepts Create{ChatMessage}".
  # NodeInfo 2.1's `metadata.features` is an open-ended array where
  # server implementations advertise capabilities. Pleroma + Akkoma
  # publish `pleroma_chat_messages`; any future software adopting
  # ChatMessage is expected to publish a similar `*_chat_messages`
  # flag, so we match on substring rather than exact equality.
  @chat_feature_substrings ~w(chat_messages chatmessage)

  # Last-resort allowlist: NodeInfo fetch failed, or the peer doesn't
  # advertise any useful features but is a well-known chat-capable
  # software. Kept small and conservative — the features check above
  # is the real load-bearing signal.
  @known_chat_software ~w(pleroma akkoma)

  @doc """
  Returns `true` when the remote server at `host_or_url` is known to
  handle Create{ChatMessage} activities. Safe to call with either a
  bare host (`"pleroma.example"`) or a full actor URL
  (`"https://pleroma.example/users/foo"`). Returns `false` on any
  resolution failure so "unknown = treat as Mastodon-class" stays the
  safe default.

  Decision order:
    1. Admin override (`chat_capable_override`) if set — wins absolutely.
    2. Any NodeInfo feature string matching `*chat_messages*`.
    3. Software name in the last-resort allowlist.
    4. Unknown → false.
  """
  def chat_capable?(host_or_url) do
    case load_instance(host_or_url) do
      {:ok, %RemoteInstance{chat_capable_override: override}} when is_boolean(override) ->
        override

      {:ok, %RemoteInstance{features: features}} when is_list(features) and features != [] ->
        Enum.any?(features, &chat_feature?/1)

      {:ok, %RemoteInstance{software: sw}} when is_binary(sw) ->
        sw in @known_chat_software

      _ ->
        false
    end
  end

  defp chat_feature?(feature) when is_binary(feature) do
    f = String.downcase(feature)
    Enum.any?(@chat_feature_substrings, &String.contains?(f, &1))
  end

  defp chat_feature?(_), do: false

  @doc """
  Returns `{:ok, software_name}` (lowercase, from NodeInfo's
  `software.name`) or `{:error, reason}`. Consults the cache first;
  on miss or stale entry, fetches NodeInfo and upserts.
  """
  def software_for(host_or_url) do
    case load_instance(host_or_url) do
      {:ok, %RemoteInstance{software: sw}} when is_binary(sw) -> {:ok, sw}
      {:ok, %RemoteInstance{last_error: err}} when is_binary(err) -> {:error, err}
      _ -> {:error, :unknown}
    end
  end

  defp load_instance(host_or_url) when is_binary(host_or_url) do
    case extract_host(host_or_url) do
      {:ok, host} ->
        case Repo.get_by(RemoteInstance, domain: host) do
          %RemoteInstance{fetched_at: fetched_at} = inst when not is_nil(fetched_at) ->
            if fresh?(fetched_at), do: {:ok, inst}, else: refresh(host)

          _ ->
            refresh(host)
        end

      :error ->
        {:error, :invalid_host}
    end
  end

  defp load_instance(_), do: {:error, :invalid_host}

  defp fresh?(fetched_at) do
    DateTime.diff(DateTime.utc_now(), fetched_at, :second) < @refetch_after_seconds
  end

  defp extract_host(str) do
    uri = URI.parse(str)

    cond do
      is_binary(uri.host) -> {:ok, uri.host}
      # `URI.parse("example.com")` returns host=nil because there's no scheme.
      is_binary(uri.path) and uri.path != "" -> {:ok, uri.path}
      true -> :error
    end
  end

  defp refresh(host) do
    case fetch_and_parse(host) do
      {:ok, software, version, features} ->
        upsert(host, software: software, version: version, features: features, error: nil)

      {:error, reason} ->
        upsert(host,
          software: nil,
          version: nil,
          features: [],
          error: inspect(reason)
        )
    end
    |> case do
      {:ok, instance} -> {:ok, instance}
      other -> other
    end
  end

  defp fetch_and_parse(host) do
    with {:ok, nodeinfo_url} <- discover_nodeinfo_url(host),
         {:ok, %{"software" => %{"name" => name} = software} = nodeinfo} <-
           fetch_json(nodeinfo_url) do
      version = Map.get(software, "version")
      features = extract_features(nodeinfo)
      {:ok, String.downcase(name), version, features}
    else
      {:ok, _other} -> {:error, :malformed_nodeinfo}
      err -> err
    end
  end

  # NodeInfo 2.1 stashes open-ended capability flags in `metadata.features`.
  # Older 2.0 documents may store them in `metadata.nodeFeatures` or leave
  # them empty; treat missing as an empty list rather than an error.
  defp extract_features(%{"metadata" => metadata}) when is_map(metadata) do
    candidates =
      Map.get(metadata, "features") ||
        Map.get(metadata, "nodeFeatures") ||
        []

    candidates
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp extract_features(_), do: []

  defp discover_nodeinfo_url(host) do
    case fetch_wellknown(host) do
      {:ok, href} ->
        {:ok, href}

      {:error, _} ->
        # Some (mostly older or reverse-proxied) Fediverse servers
        # don't publish `/.well-known/nodeinfo` even though they
        # serve the actual NodeInfo doc at its canonical path.
        # bassam.social / rebased behind nginx is one example:
        # the 2.1/2.0 JSON is fine, the discovery doc 404s. Try
        # the direct paths as a fallback so those instances are
        # still detected.
        direct_nodeinfo_fallback(host)
    end
  end

  defp fetch_wellknown(host) do
    case fetch_json("https://#{host}/.well-known/nodeinfo") do
      {:ok, %{"links" => links}} when is_list(links) ->
        # Prefer 2.1, fall back to 2.0 — the shape we care about
        # (`software.name`) is stable across both.
        rel_21 = "http://nodeinfo.diaspora.software/ns/schema/2.1"
        rel_20 = "http://nodeinfo.diaspora.software/ns/schema/2.0"

        link =
          Enum.find(links, &(is_map(&1) and &1["rel"] == rel_21)) ||
            Enum.find(links, &(is_map(&1) and &1["rel"] == rel_20)) ||
            List.first(links)

        case link do
          %{"href" => href} when is_binary(href) -> {:ok, href}
          _ -> {:error, :no_nodeinfo_link}
        end

      {:ok, _} ->
        {:error, :malformed_wellknown}

      err ->
        err
    end
  end

  @direct_nodeinfo_paths [
    "/nodeinfo/2.1.json",
    "/nodeinfo/2.0.json",
    "/nodeinfo/2.1",
    "/nodeinfo/2.0"
  ]

  defp direct_nodeinfo_fallback(host) do
    Enum.reduce_while(@direct_nodeinfo_paths, {:error, :no_nodeinfo_found}, fn path, acc ->
      url = "https://#{host}#{path}"

      case fetch_json(url) do
        {:ok, %{"software" => _}} -> {:halt, {:ok, url}}
        _ -> {:cont, acc}
      end
    end)
  end

  # Kept tight because a NodeInfo miss sits directly in the DM
  # compose flow — a slow or dead peer would otherwise hang the
  # send request for the full timeout. 2 seconds is plenty for a
  # healthy peer (NodeInfo is cheap) and short enough that a dead
  # peer fails fast and the compose falls back to a direct post.
  @fetch_timeout_ms 2_000

  defp fetch_json(url) do
    # NodeInfo is intentionally unsigned by spec — instances expose it
    # publicly so any client (statistics aggregators, the-federation.info,
    # admin dashboards) can pull instance metadata without keys. Do not
    # route through SignedFetch.
    headers = [{"Accept", "application/json"}]

    options = [
      recv_timeout: @fetch_timeout_ms,
      timeout: @fetch_timeout_ms,
      follow_redirect: true
    ]

    case Hybridsocial.HTTP.get(url, headers, options) do
      {:ok, %Hybridsocial.HTTP.Response{status_code: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:ok, _} -> {:error, :not_a_json_object}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %Hybridsocial.HTTP.Response{status_code: status}} ->
        {:error, {:http_status, status}}

      {:error, %Hybridsocial.HTTP.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defp upsert(host, opts) do
    now = DateTime.utc_now()
    existing = Repo.get_by(RemoteInstance, domain: host) || %RemoteInstance{}

    existing
    |> RemoteInstance.changeset(%{
      domain: host,
      software: Keyword.get(opts, :software),
      version: Keyword.get(opts, :version),
      features: Keyword.get(opts, :features, []),
      fetched_at: now,
      last_error: Keyword.get(opts, :error)
    })
    |> Repo.insert_or_update()
    |> case do
      {:ok, inst} ->
        {:ok, inst}

      {:error, changeset} ->
        Logger.warning("NodeInfo cache upsert failed for #{host}: #{inspect(changeset.errors)}")

        {:error, changeset}
    end
  end
end
