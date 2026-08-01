defmodule HybridsocialWeb.Plugs.RequireScope do
  @moduledoc """
  Enforces the OAuth scopes a third-party token was actually granted.

  Without this the consent screen would be a lie: a client that asked for
  `read` would receive a token that can post, follow and delete, because
  nothing downstream looks at `scopes`. That was tolerable while apps could
  only be created from your own settings page; it is not, now that
  `POST /api/v1/apps` is public.

  The check is deliberately coarse — read for safe methods, write for
  everything else, plus `admin:*` for the admin API — rather than a
  per-endpoint scope table. Coarse enforcement that is actually correct beats
  a granular table that drifts out of date, and it matches what clients
  request in practice (`read write follow push`).

  First-party session tokens (`application_id` nil) are unrestricted: they
  come from the login flow, not from a delegated grant.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  # Granular Mastodon scopes (`read:accounts`) satisfy their parent (`read`).
  # A token holding only a narrow scope is treated as holding the family,
  # which is looser than Mastodon but never looser than no check at all.
  @read_methods ~w(GET HEAD OPTIONS)

  def init(opts), do: opts

  def call(conn, _opts) do
    session = conn.assigns[:current_session]

    # Anonymous, or a first-party session: nothing was delegated, so there is
    # no grant to hold the request to. Both key styles are read because the
    # session cache round-trips through JSON.
    if is_map(session) and field(session, :application_id, "application_id") do
      enforce(conn, field(session, :scopes, "scopes") || [])
    else
      conn
    end
  end

  defp field(session, atom_key, string_key) do
    Map.get(session, atom_key) || Map.get(session, string_key)
  end

  defp enforce(conn, scopes) do
    required = required_scopes(conn)

    if Enum.any?(required, &holds_scope?(scopes, &1)) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{
        error: "oauth.insufficient_scope",
        message: "This access token lacks the required scope: #{Enum.join(required, " or ")}."
      })
      |> halt()
    end
  end

  # Any one of the returned scopes is enough. `write` covers the social
  # actions and push registration because that's how clients ask for them.
  defp required_scopes(conn) do
    admin? = String.starts_with?(conn.request_path, "/api/v1/admin")
    read? = conn.method in @read_methods

    cond do
      admin? and read? -> ["admin:read", "admin:write"]
      admin? -> ["admin:write"]
      read? -> ["read"]
      push_path?(conn) -> ["push", "write"]
      follow_path?(conn) -> ["follow", "write"]
      true -> ["write"]
    end
  end

  defp push_path?(conn), do: String.starts_with?(conn.request_path, "/api/v1/push")

  defp follow_path?(conn) do
    String.starts_with?(conn.request_path, "/api/v1/accounts/") and
      String.ends_with?(conn.request_path, ["/follow", "/unfollow"])
  end

  defp holds_scope?(scopes, required) do
    Enum.any?(scopes, fn scope ->
      scope == required or String.starts_with?(scope, required <> ":")
    end)
  end
end
