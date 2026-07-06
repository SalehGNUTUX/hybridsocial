defmodule HybridsocialWeb.Plugs.RequireConfirmedEmail do
  @moduledoc """
  Halts authenticated requests from users whose `users.confirmed_at`
  is nil while the instance config has `require_email_confirmation`
  enabled. Plug runs after `Plugs.Auth` + `Plugs.RequireAuth`, so it
  always sees a `current_identity`.

  A small allowlist lets unconfirmed users still:
    * read their own profile (`/api/v1/auth/me`) — needed so the
      frontend can render a "please confirm your email" gate;
    * log out;
    * resend the confirmation email.

  Everything else returns 403 with `auth.email_not_confirmed` and the
  identity id, so the client can offer a "resend confirmation" button
  inline.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  import Ecto.Query, only: [from: 2]
  alias Hybridsocial.Accounts.User
  alias Hybridsocial.Repo

  # Paths that an unconfirmed user must still be able to reach so the
  # confirmation flow itself is usable. Match on full request_path
  # because pipelines don't carry the controller action here.
  @allowed_paths ~w(
    /api/v1/auth/me
    /api/v1/auth/logout
    /api/v1/auth/resend_confirmation
  )

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      conn.request_path in @allowed_paths ->
        conn

      not Hybridsocial.Config.require_email_confirmation?() ->
        conn

      confirmed?(conn.assigns[:current_identity]) ->
        conn

      true ->
        identity_id = conn.assigns[:current_identity] && conn.assigns.current_identity.id

        conn
        |> put_status(:forbidden)
        |> json(%{error: "auth.email_not_confirmed", identity_id: identity_id})
        |> halt()
    end
  end

  defp confirmed?(nil), do: false

  defp confirmed?(%{id: identity_id}) do
    # Single column lookup; cheap and runs once per authenticated
    # request. Cache layer can be added if it shows up in profiles.
    case Repo.one(from u in User, where: u.identity_id == ^identity_id, select: u.confirmed_at) do
      nil -> false
      %DateTime{} -> true
    end
  end
end
