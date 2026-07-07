defmodule Hybridsocial.Federation.SignedFetch do
  @moduledoc """
  Authorized-fetch helper for outbound GETs against remote ActivityPub
  servers.

  Mastodon's "secure mode" / authorized-fetch returns 401 to unsigned
  GETs against actor and object URLs. Pleroma/Akkoma support it too.
  Any GET we make against a remote `application/activity+json` resource
  should go through this helper so secure-mode peers are reachable.

  Signs with the instance actor's key. The instance actor exists for
  exactly this purpose — using a random user identity (as a previous
  inline implementation did) leaks one user's identity into every
  cross-instance lookup and breaks if that user is later deleted.

  Fall-back behavior when instance keys aren't configured: emit one
  warning log and send the request unsigned. Some peers will still
  serve the response; secure-mode ones will 401 and the caller's
  existing error path handles that. Run `mix hybridsocial.gen.instance_keys`
  to fix the warning.

  ## Excluded paths

  - HTTP-Signature key fetch in `HTTPSignature.fetch_public_key/1` is
    NOT routed through this helper — verifying a remote's signature
    requires fetching their public key, and if THAT fetch were also
    signed, the remote would need our key to verify, requiring them
    to fetch us, requiring our verifier to verify them, etc. The
    convention is: key-discovery GETs are unsigned.
  - `Webfinger` and `NodeInfo` are unsigned by their own specs and
    must remain so.
  """
  alias Hybridsocial.Federation.{HTTPSignature, InstanceActor}
  require Logger

  @ap_accept "application/activity+json, application/ld+json"
  @user_agent "HybridSocial/1.0 (+https://hybridsocial)"

  @doc """
  Issues a signed GET. `opts` are passed through to Req.get/3
  with two added defaults (Accept, User-Agent) that callers can
  override by passing `headers: [...]`.
  """
  def get(url, opts \\ []) do
    extra_headers = Keyword.get(opts, :headers, [])
    httpoison_opts = Keyword.drop(opts, [:headers])

    base_headers = [
      {"Accept", @ap_accept},
      {"User-Agent", @user_agent}
    ]

    headers = base_headers ++ signature_headers(url) ++ extra_headers

    Hybridsocial.HTTP.get(url, headers, httpoison_opts)
  end

  defp signature_headers(url) do
    if InstanceActor.keys_configured?() do
      key_id = "#{InstanceActor.ap_id()}#main-key"

      url
      |> HTTPSignature.sign_get(InstanceActor.private_key(), key_id)
      |> Enum.map(fn {k, v} -> {k, v} end)
    else
      Logger.warning(
        "Federation signed-fetch falling back to unsigned for #{url}: " <>
          "instance actor keys not configured. Mastodon secure-mode peers " <>
          "will reject. Run mix hybridsocial.gen.instance_keys."
      )

      []
    end
  end
end
