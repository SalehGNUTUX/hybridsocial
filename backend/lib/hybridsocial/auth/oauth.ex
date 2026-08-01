defmodule Hybridsocial.Auth.OAuth do
  @moduledoc """
  OAuth2 provider context. Handles app registration, authorization codes (PKCE),
  and token exchange.

  Two client shapes have to work here. Our own frontend registers apps as
  authenticated JSON (`name`, arrays for `redirect_uris`/`scopes`). Every
  Mastodon-API client instead posts an unauthenticated, form-encoded
  `client_name` with whitespace-separated `redirect_uris`/`scopes` as its very
  first request, before any user exists in its state. `create_application/2`
  normalizes both.

  PKCE is supported but optional: a client that omits `code_challenge` is
  treated as a confidential client and must present its `client_secret` at the
  token endpoint instead. One of the two is always required, so an intercepted
  authorization code is never enough on its own.
  """
  import Ecto.Query

  alias Hybridsocial.Repo
  alias Hybridsocial.Auth.{OAuthApplication, OAuthToken, AuthorizationCode, Token}

  # 10 minutes in seconds
  @authorization_code_ttl 600

  @oob_redirect_uri "urn:ietf:wg:oauth:2.0:oob"
  @max_redirect_uris 10

  # Mastodon's scope vocabulary: the four top-level scopes, their granular
  # `read:accounts` / `write:statuses` forms, and the admin variants.
  @scope_pattern ~r/^(?:read|write)(?::[a-z_]+)?$|^(?:follow|push)$|^admin:(?:read|write)(?::[a-z_]+)?$/

  @doc "The out-of-band redirect URI, for clients with no callback of their own."
  def oob_redirect_uri, do: @oob_redirect_uri

  # --- Application management ---

  @doc """
  Register an OAuth application.

  `creator_identity_id` is nil for anonymous registrations (a third-party
  client bootstrapping itself); the row is still owned by nobody rather than
  by whoever happened to be logged in.
  """
  def create_application(attrs, creator_identity_id \\ nil) do
    do_create_application(attrs, creator_identity_id)
  end

  defp do_create_application(attrs, creator_identity_id) do
    client_id = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    client_secret = :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)
    secret_hash = :crypto.hash(:sha256, client_secret) |> Base.encode16(case: :lower)

    result =
      %OAuthApplication{}
      |> Ecto.Changeset.change(%{
        name: app_name(attrs),
        redirect_uris: parse_redirect_uris(attrs),
        scopes: parse_requested_scopes(attrs),
        website: fetch_attr(attrs, "website", :website),
        client_id: client_id,
        client_secret_hash: secret_hash,
        created_by: creator_identity_id
      })
      |> Ecto.Changeset.validate_required([:name, :client_id, :client_secret_hash])
      |> Ecto.Changeset.validate_length(:name, min: 1, max: 255)
      |> validate_redirect_uris()
      |> validate_scopes()
      |> validate_website()
      |> Repo.insert()

    case result do
      {:ok, app} ->
        {:ok, app, client_secret}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Params arrive either string-keyed (from the wire) or atom-keyed (from
  # internal callers and tests), so every lookup has to try both.
  defp fetch_attr(attrs, string_key, atom_key) do
    case attrs[string_key] || attrs[atom_key] do
      binary when is_binary(binary) -> String.trim(binary)
      other -> other
    end
  end

  # Mastodon clients send `client_name`; our own frontend sends `name`.
  defp app_name(attrs) do
    case fetch_attr(attrs, "client_name", :client_name) do
      blank when blank in [nil, ""] -> fetch_attr(attrs, "name", :name)
      name -> name
    end
  end

  @doc """
  Split a whitespace/newline-separated OAuth list into a list of strings.

  Mastodon sends `redirect_uris` and `scopes` as single space-separated
  strings; our own frontend sends arrays. Both are accepted.
  """
  def split_list(value) when is_list(value), do: Enum.map(value, &to_string/1)

  def split_list(value) when is_binary(value),
    do: String.split(value, ~r/[\s\n]+/, trim: true)

  def split_list(_), do: []

  # No callback given means out-of-band: the user is shown the code and pastes
  # it into the client. That's the default a first-party "personal app" wants,
  # and it's what Mastodon assumes too, so an omitted value isn't an error.
  defp parse_redirect_uris(attrs) do
    (attrs["redirect_uris"] || attrs[:redirect_uris] || attrs["redirect_uri"] ||
       attrs[:redirect_uri])
    |> split_list()
    |> Enum.uniq()
    |> Enum.take(@max_redirect_uris)
    |> case do
      [] -> [@oob_redirect_uri]
      uris -> uris
    end
  end

  defp parse_requested_scopes(attrs) do
    case split_list(attrs["scopes"] || attrs[:scopes] || attrs["scope"] || attrs[:scope]) do
      [] -> ["read"]
      scopes -> Enum.uniq(scopes)
    end
  end

  defp validate_scopes(changeset) do
    scopes = Ecto.Changeset.get_field(changeset, :scopes) || []

    case Enum.reject(scopes, &valid_scope?/1) do
      [] -> changeset
      [bad | _] -> Ecto.Changeset.add_error(changeset, :scopes, "unsupported scope: #{bad}")
    end
  end

  defp validate_redirect_uris(changeset) do
    uris = Ecto.Changeset.get_field(changeset, :redirect_uris) || []

    cond do
      uris == [] ->
        Ecto.Changeset.add_error(changeset, :redirect_uris, "must include at least one URI")

      Enum.all?(uris, &valid_redirect_uri?/1) ->
        changeset

      true ->
        Ecto.Changeset.add_error(changeset, :redirect_uris, "contains an unsupported URI")
    end
  end

  # `oob` for clients that display the code, otherwise an absolute URI. Custom
  # app schemes (husky://, tusky://) are how native clients receive callbacks,
  # so they're allowed — but only with a real authority, and never the
  # script-executing schemes that would turn a callback into XSS.
  defp valid_redirect_uri?(@oob_redirect_uri), do: true

  defp valid_redirect_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: nil} ->
        false

      %URI{scheme: scheme} when scheme in ~w(javascript data vbscript file) ->
        false

      %URI{scheme: scheme, host: host} when scheme in ~w(http https) ->
        is_binary(host) and host != ""

      %URI{} ->
        true
    end
  end

  defp valid_redirect_uri?(_), do: false

  defp validate_website(changeset) do
    case Ecto.Changeset.get_field(changeset, :website) do
      nil ->
        changeset

      "" ->
        Ecto.Changeset.put_change(changeset, :website, nil)

      website ->
        case URI.parse(website) do
          %URI{scheme: scheme, host: host} when scheme in ~w(http https) and is_binary(host) ->
            changeset

          _ ->
            Ecto.Changeset.add_error(changeset, :website, "must be an http(s) URL")
        end
    end
  end

  @doc """
  Narrow the scopes a client asked for at `/oauth/authorize` to those its
  registration was granted. A client cannot widen its access per-request.
  """
  def grantable_scopes(app, requested) do
    requested = split_list(requested) |> Enum.filter(&valid_scope?/1)
    registered = app.scopes || []

    case requested do
      [] -> if registered == [], do: ["read"], else: registered
      _ -> Enum.filter(requested, &(&1 in registered))
    end
  end

  @doc "Whether a scope string is part of the supported vocabulary."
  def valid_scope?(scope) when is_binary(scope), do: Regex.match?(@scope_pattern, scope)
  def valid_scope?(_), do: false

  def get_application(id) do
    Repo.get(OAuthApplication, id)
  end

  def get_application_by_client_id(client_id) do
    OAuthApplication
    |> where([a], a.client_id == ^client_id)
    |> Repo.one()
  end

  def list_applications(identity_id) do
    OAuthApplication
    |> where([a], a.created_by == ^identity_id)
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  def delete_application(id, identity_id) do
    case get_application(id) do
      nil ->
        {:error, :not_found}

      app ->
        if app.created_by == identity_id do
          Repo.delete(app)
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  The application an access token was issued to, or nil for a first-party
  session token (those carry no `application_id`).
  """
  def application_for_token(nil), do: nil

  def application_for_token(access_token) when is_binary(access_token) do
    token_hash = Token.hash_token(access_token)

    OAuthToken
    |> where([t], t.token_hash == ^token_hash and is_nil(t.revoked_at))
    |> join(:inner, [t], a in OAuthApplication, on: a.id == t.application_id)
    |> select([_t, a], a)
    |> Repo.one()
  end

  def verify_client_credentials(client_id, client_secret) do
    case get_application_by_client_id(client_id) do
      nil ->
        {:error, :invalid_client}

      app ->
        secret_hash = :crypto.hash(:sha256, client_secret) |> Base.encode16(case: :lower)

        if Plug.Crypto.secure_compare(secret_hash, app.client_secret_hash) do
          {:ok, app}
        else
          {:error, :invalid_client}
        end
    end
  end

  # --- Authorization codes (PKCE optional) ---

  def create_authorization_code(identity_id, application_id, scopes, redirect_uri, code_challenge) do
    code = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    code_hash = hash_code(code)
    expires_at = DateTime.add(DateTime.utc_now(), @authorization_code_ttl, :second)

    result =
      %AuthorizationCode{}
      |> AuthorizationCode.changeset(%{
        code_hash: code_hash,
        application_id: application_id,
        identity_id: identity_id,
        redirect_uri: redirect_uri,
        scopes: scopes || [],
        code_challenge: presence(code_challenge),
        code_challenge_method: if(presence(code_challenge), do: "S256"),
        expires_at: expires_at,
        inserted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    case result do
      {:ok, _auth_code} -> {:ok, code}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  @doc """
  Exchange an authorization code for tokens.

  The client proves itself with **either** the PKCE verifier (public clients)
  **or** its client secret (confidential clients). A code minted without a
  challenge can only be redeemed with the secret, so dropping the challenge is
  not a way to downgrade the flow.
  """
  def exchange_code(code, code_verifier, client_id, redirect_uri, client_secret \\ nil) do
    code_hash = hash_code(code)

    with {:ok, auth_code} <- get_valid_authorization_code(code_hash),
         {:ok, app} <- verify_client_id(auth_code, client_id),
         :ok <- verify_redirect_uri(auth_code, redirect_uri),
         :ok <- verify_client_proof(app, auth_code, code_verifier, client_secret),
         {:ok, _} <- delete_authorization_code(auth_code) do
      create_oauth_tokens(auth_code.identity_id, auth_code.application_id, auth_code.scopes)
    end
  end

  defp verify_client_proof(app, auth_code, code_verifier, client_secret) do
    cond do
      is_binary(auth_code.code_challenge) and auth_code.code_challenge != "" ->
        verify_code_challenge(auth_code, code_verifier)

      is_binary(client_secret) and client_secret != "" ->
        verify_client_secret(app, client_secret)

      true ->
        {:error, :invalid_client}
    end
  end

  defp verify_client_secret(app, client_secret) do
    secret_hash = :crypto.hash(:sha256, client_secret) |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(secret_hash, app.client_secret_hash) do
      :ok
    else
      {:error, :invalid_client}
    end
  end

  @doc """
  Rotate a third-party app's refresh token.

  Only tokens bound to an application go through here; first-party session
  refresh stays in `Hybridsocial.Auth`.
  """
  def refresh_token_grant(refresh_token, client_id, client_secret) do
    token_hash = Token.hash_token(refresh_token)

    with {:ok, app} <- authenticate_client(client_id, client_secret),
         {:ok, oauth_token} <- get_refreshable_token(token_hash, app.id),
         {:ok, _revoked} <- do_revoke_token(oauth_token) do
      create_oauth_tokens(oauth_token.identity_id, app.id, oauth_token.scopes)
    end
  end

  defp authenticate_client(client_id, client_secret) do
    case get_application_by_client_id(client_id || "") do
      nil ->
        {:error, :invalid_client}

      app ->
        if is_binary(client_secret) and client_secret != "" do
          with :ok <- verify_client_secret(app, client_secret), do: {:ok, app}
        else
          {:error, :invalid_client}
        end
    end
  end

  defp get_refreshable_token(token_hash, application_id) do
    OAuthToken
    |> where([t], t.refresh_token_hash == ^token_hash)
    |> where([t], t.application_id == ^application_id)
    |> where([t], is_nil(t.revoked_at))
    |> Repo.one()
    |> case do
      nil -> {:error, :invalid_grant}
      token -> {:ok, token}
    end
  end

  def revoke_token(token) do
    token_hash = Token.hash_token(token)

    case get_active_token_by_hash(token_hash) do
      nil ->
        # Also try by refresh token hash
        case get_active_token_by_refresh_hash(token_hash) do
          nil -> {:ok, :already_revoked}
          oauth_token -> do_revoke_token(oauth_token)
        end

      oauth_token ->
        do_revoke_token(oauth_token)
    end
  end

  # --- Private helpers ---

  defp hash_code(code) do
    :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)
  end

  defp get_valid_authorization_code(code_hash) do
    now = DateTime.utc_now()

    case Repo.get(AuthorizationCode, code_hash) do
      nil ->
        {:error, :invalid_code}

      auth_code ->
        if DateTime.compare(auth_code.expires_at, now) == :gt do
          {:ok, auth_code}
        else
          # Clean up expired code
          Repo.delete(auth_code)
          {:error, :code_expired}
        end
    end
  end

  defp verify_client_id(auth_code, client_id) do
    app = Repo.get(OAuthApplication, auth_code.application_id)

    if app && app.client_id == client_id do
      {:ok, app}
    else
      {:error, :invalid_client}
    end
  end

  defp verify_redirect_uri(auth_code, redirect_uri) do
    if auth_code.redirect_uri == redirect_uri do
      :ok
    else
      {:error, :redirect_uri_mismatch}
    end
  end

  defp verify_code_challenge(_auth_code, verifier) when not is_binary(verifier),
    do: {:error, :invalid_code_verifier}

  defp verify_code_challenge(auth_code, code_verifier) do
    expected_challenge = auth_code.code_challenge

    computed_challenge =
      :crypto.hash(:sha256, code_verifier)
      |> Base.url_encode64(padding: false)

    if Plug.Crypto.secure_compare(computed_challenge, expected_challenge) do
      :ok
    else
      {:error, :invalid_code_verifier}
    end
  end

  defp delete_authorization_code(auth_code) do
    Repo.delete(auth_code)
  end

  defp create_oauth_tokens(identity_id, application_id, scopes) do
    # Third-party clients treat an access token as permanent and never call
    # the refresh grant, so app tokens are long-lived. Revocation still works:
    # the Auth plug checks the oauth_tokens row on every request.
    ttl = Token.oauth_app_token_ttl()

    with {:ok, access_token, _claims} <- Token.generate_access_token(identity_id, ttl),
         {refresh_token, refresh_hash} <- Token.generate_refresh_token() do
      token_hash = Token.hash_token(access_token)
      expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

      result =
        %OAuthToken{}
        |> OAuthToken.changeset(%{
          identity_id: identity_id,
          application_id: application_id,
          token_hash: token_hash,
          refresh_token_hash: refresh_hash,
          scopes: scopes,
          expires_at: expires_at
        })
        |> Repo.insert()

      case result do
        {:ok, _oauth_token} ->
          {:ok,
           %{
             access_token: access_token,
             refresh_token: refresh_token,
             token_type: "Bearer",
             expires_in: ttl,
             scope: Enum.join(scopes, " "),
             # Mastodon clients read `created_at` (epoch seconds) off the
             # token response; absent, some of them store a null and choke.
             created_at: DateTime.utc_now() |> DateTime.to_unix()
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp get_active_token_by_hash(token_hash) do
    OAuthToken
    |> where([t], t.token_hash == ^token_hash and is_nil(t.revoked_at))
    |> Repo.one()
  end

  defp get_active_token_by_refresh_hash(token_hash) do
    OAuthToken
    |> where([t], t.refresh_token_hash == ^token_hash and is_nil(t.revoked_at))
    |> Repo.one()
  end

  defp do_revoke_token(oauth_token) do
    oauth_token
    |> OAuthToken.revoke_changeset()
    |> Repo.update()
  end
end
