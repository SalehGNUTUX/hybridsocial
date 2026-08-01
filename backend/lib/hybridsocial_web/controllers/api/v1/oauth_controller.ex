defmodule HybridsocialWeb.Api.V1.OAuthController do
  @moduledoc """
  OAuth2 endpoints, shaped so third-party Mastodon-API clients can complete
  the handshake:

      POST /api/v1/apps      (public)  -> client_id / client_secret
      GET  /oauth/authorize  (public)  -> redirects to the web consent screen
      POST /oauth/authorize  (session) -> mints the authorization code
      POST /oauth/token      (public)  -> code or refresh_token -> access token

  App registration is deliberately unauthenticated: a client has no user at
  the point it registers. What it gets is a set of credentials that are inert
  until a real user completes the consent screen.
  """
  use HybridsocialWeb, :controller

  alias Hybridsocial.Auth.OAuth

  # Failures where we have no verified callback to report the error to, so
  # redirecting would itself be the open-redirect the checks exist to prevent.
  @untrusted_redirect_errors [
    "oauth.client_id_required",
    "oauth.invalid_client_id",
    "oauth.invalid_redirect_uri"
  ]

  # --- App registration (public) ---

  def create_app(conn, params) do
    # nil when nobody is signed in: the app row is owned by no one rather
    # than by whichever session happened to be attached.
    creator_id = conn.assigns[:current_identity] && conn.assigns.current_identity.id

    case OAuth.create_application(params, creator_id) do
      {:ok, app, client_secret} ->
        conn
        |> put_status(:ok)
        |> json(app_credentials(app, client_secret))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  @doc """
  Public metadata for one client_id, so the consent screen can name the app
  asking for access instead of trusting whatever the query string claims.
  """
  def app_info(conn, %{"client_id" => client_id}) do
    case OAuth.get_application_by_client_id(client_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "oauth.invalid_client_id"})

      app ->
        json(conn, %{
          name: app.name,
          website: app.website,
          scopes: app.scopes,
          redirect_uris: app.redirect_uris
        })
    end
  end

  def app_info(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "oauth.client_id_required"})
  end

  @doc "Mastodon's `GET /api/v1/apps/verify_credentials`: the app behind this token."
  def verify_app_credentials(conn, _params) do
    case OAuth.application_for_token(conn.assigns[:current_token]) do
      nil ->
        # A first-party session token isn't bound to an app. Answer with the
        # instance itself rather than 404ing a client that only calls this to
        # confirm its token works.
        json(conn, %{name: Hybridsocial.Config.get("instance_name", "HybridSocial"), website: nil})

      app ->
        json(conn, %{name: app.name, website: app.website})
    end
  end

  @doc "Create app + issue token in one step for developer convenience."
  def create_app_with_token(conn, params) do
    identity = conn.assigns.current_identity
    ip = to_string(:inet_parse.ntoa(conn.remote_ip))
    ua = Plug.Conn.get_req_header(conn, "user-agent") |> List.first() || ""

    case OAuth.create_application(params, identity.id) do
      {:ok, app, client_secret} ->
        # Also issue an access token immediately
        user = Hybridsocial.Repo.get_by(Hybridsocial.Accounts.User, identity_id: identity.id)
        user_with_identity = Hybridsocial.Repo.preload(user, :identity)

        case Hybridsocial.Auth.issue_tokens(user_with_identity, %{
               ip_address: ip,
               user_agent: ua,
               device_name: app.name
             }) do
          {:ok, tokens} ->
            conn
            |> put_status(:created)
            |> json(%{
              app: %{
                id: app.id,
                name: app.name,
                client_id: app.client_id,
                client_secret: client_secret,
                scopes: app.scopes
              },
              access_token: tokens.access_token,
              token_type: "Bearer",
              note: "Save these credentials — the client secret cannot be shown again."
            })

          {:error, _} ->
            # App was created but token failed — return app anyway
            conn
            |> put_status(:created)
            |> json(%{
              app: %{
                id: app.id,
                name: app.name,
                client_id: app.client_id,
                client_secret: client_secret,
                scopes: app.scopes
              },
              access_token: nil,
              error:
                "Token generation failed — use the client credentials to request a token manually."
            })
        end

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  def list_apps(conn, _params) do
    identity = conn.assigns.current_identity
    apps = OAuth.list_applications(identity.id)

    conn
    |> put_status(:ok)
    |> json(Enum.map(apps, &serialize_app/1))
  end

  def delete_app(conn, %{"id" => id}) do
    identity = conn.assigns.current_identity

    case OAuth.delete_application(id, identity.id) do
      {:ok, _app} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "oauth.app_deleted"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "oauth.app_not_found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "oauth.not_app_owner"})
    end
  end

  # --- Authorization: browser entry point (public) ---

  @doc """
  Mastodon's `GET /oauth/authorize`. A client opens this in a browser or
  custom tab, so it has to answer with navigation, not JSON.

  We validate what can be validated without a user, then hand off to the web
  app's consent screen, which reuses the real login flow (2FA, passkeys,
  email-confirmation gate) instead of reimplementing it here. Bad parameters
  are reported per RFC 6749: back to the client if we trust the redirect URI,
  as a plain error page if we don't.
  """
  def authorize_redirect(conn, params) do
    with {:ok, _} <- validate_response_type(params["response_type"]),
         {:ok, app} <- validate_client(params["client_id"]),
         :ok <- validate_redirect_uri(app, params["redirect_uri"]) do
      redirect(conn, external: consent_url(params))
    else
      # The client is unknown or the callback isn't one it registered, so we
      # have nowhere trustworthy to send the error. Bouncing to an unverified
      # redirect_uri here is exactly the open-redirect the check exists to stop.
      {:error, error_key} when error_key in @untrusted_redirect_errors ->
        conn
        |> put_status(:bad_request)
        |> text(error_message(error_key))

      {:error, error_key} ->
        redirect(conn, external: error_redirect(params, error_key))
    end
  end

  # The consent screen is a web-app route, not an API one; /oauth/* is
  # proxied to the backend, so it lives at /authorize.
  defp consent_url(params) do
    query =
      params
      |> Map.take(~w(client_id redirect_uri scope scopes state code_challenge
                     code_challenge_method response_type force_login))
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> URI.encode_query()

    "#{base_url()}/authorize?#{query}"
  end

  defp error_redirect(params, error_key) do
    query =
      %{"error" => oauth_error_code(error_key), "error_description" => error_message(error_key)}
      |> maybe_put_state(params["state"])
      |> URI.encode_query()

    separator = if String.contains?(params["redirect_uri"], "?"), do: "&", else: "?"
    "#{params["redirect_uri"]}#{separator}#{query}"
  end

  defp maybe_put_state(query, nil), do: query
  defp maybe_put_state(query, ""), do: query
  defp maybe_put_state(query, state), do: Map.put(query, "state", state)

  defp oauth_error_code("oauth.unsupported_response_type"), do: "unsupported_response_type"
  defp oauth_error_code(_), do: "invalid_request"

  defp error_message("oauth.unsupported_response_type"),
    do: "Only response_type=code is supported."

  defp error_message("oauth.client_id_required"), do: "Missing client_id."
  defp error_message("oauth.invalid_client_id"), do: "Unknown client_id."

  defp error_message("oauth.invalid_redirect_uri"),
    do: "redirect_uri does not match one registered for this application."

  defp error_message(other), do: other

  defp base_url do
    HybridsocialWeb.Endpoint.url()
  end

  # --- Authorization: code issuance (authenticated) ---

  def authorize(conn, params) do
    identity = conn.assigns.current_identity

    with {:ok, _} <- validate_response_type(params["response_type"] || "code"),
         {:ok, app} <- validate_client(params["client_id"]),
         :ok <- validate_redirect_uri(app, params["redirect_uri"]) do
      # A client can never be granted more than its registration asked for,
      # whatever the authorize request says.
      scopes = OAuth.grantable_scopes(app, params["scope"] || params["scopes"])

      case OAuth.create_authorization_code(
             identity.id,
             app.id,
             scopes,
             params["redirect_uri"],
             params["code_challenge"]
           ) do
        {:ok, code} ->
          conn
          |> put_status(:ok)
          |> json(%{
            code: code,
            redirect_uri: params["redirect_uri"],
            state: params["state"],
            scope: Enum.join(scopes, " ")
          })

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "oauth.authorization_failed", details: format_errors(changeset)})
      end
    else
      {:error, error_key} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: error_key})
    end
  end

  # --- Token exchange (public) ---

  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    {client_id, client_secret} = client_credentials(conn, params)

    OAuth.exchange_code(
      params["code"],
      params["code_verifier"],
      client_id,
      params["redirect_uri"],
      client_secret
    )
    |> respond_with_token(conn)
  end

  def token(conn, %{"grant_type" => "refresh_token"} = params) do
    {client_id, client_secret} = client_credentials(conn, params)

    OAuth.refresh_token_grant(params["refresh_token"], client_id, client_secret)
    |> respond_with_token(conn)
  end

  def token(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "unsupported_grant_type"})
  end

  defp respond_with_token({:ok, tokens}, conn) do
    conn
    |> put_status(:ok)
    |> json(tokens)
  end

  defp respond_with_token({:error, reason}, conn) when is_atom(reason) do
    status = if reason == :invalid_client, do: :unauthorized, else: :bad_request

    conn
    |> put_status(status)
    |> json(%{error: to_string(reason)})
  end

  defp respond_with_token({:error, _changeset}, conn) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "oauth.token_creation_failed"})
  end

  # Client credentials may arrive in the form body or as HTTP Basic, which is
  # what RFC 6749 prefers and what several clients actually send.
  defp client_credentials(conn, params) do
    case basic_auth_credentials(conn) do
      {:ok, id, secret} -> {id, secret}
      :error -> {params["client_id"], params["client_secret"]}
    end
  end

  defp basic_auth_credentials(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(String.trim(encoded)),
         [id, secret] <- String.split(decoded, ":", parts: 2) do
      {:ok, URI.decode_www_form(id), URI.decode_www_form(secret)}
    else
      _ -> :error
    end
  end

  # --- Token revocation (public) ---

  def revoke(conn, %{"token" => token_value}) do
    OAuth.revoke_token(token_value)

    # Per RFC 7009, always return 200 regardless of whether token existed
    conn
    |> put_status(:ok)
    |> json(%{})
  end

  def revoke(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "oauth.token_required"})
  end

  # --- Private helpers ---

  defp validate_response_type("code"), do: {:ok, :code}
  defp validate_response_type(_), do: {:error, "oauth.unsupported_response_type"}

  defp validate_client(nil), do: {:error, "oauth.client_id_required"}

  defp validate_client(client_id) do
    case OAuth.get_application_by_client_id(client_id) do
      nil -> {:error, "oauth.invalid_client_id"}
      app -> {:ok, app}
    end
  end

  defp validate_redirect_uri(app, redirect_uri) do
    if redirect_uri in app.redirect_uris do
      :ok
    else
      {:error, "oauth.invalid_redirect_uri"}
    end
  end

  # Mastodon's app shape. `redirect_uri` (singular, space-joined) is what
  # older clients read; `redirect_uris` is the 4.3+ array. `vapid_key` is
  # required by clients that set up Web Push at registration time.
  defp app_credentials(app, client_secret) do
    %{
      id: app.id,
      name: app.name,
      website: app.website,
      scopes: app.scopes,
      redirect_uri: Enum.join(app.redirect_uris, "\n"),
      redirect_uris: app.redirect_uris,
      client_id: app.client_id,
      client_secret: client_secret,
      # nil when Web Push isn't configured; Vapid.public_key/0 answers that
      # rather than raising, so registration never fails over it.
      vapid_key: Hybridsocial.Push.Vapid.public_key()
    }
  end

  defp serialize_app(app) do
    %{
      id: app.id,
      name: app.name,
      client_id: app.client_id,
      redirect_uris: app.redirect_uris,
      scopes: app.scopes,
      website: app.website,
      created_at: app.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
