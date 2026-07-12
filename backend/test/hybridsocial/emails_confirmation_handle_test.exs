defmodule Hybridsocial.Emails.ConfirmationHandleTest do
  @moduledoc """
  Regression: the confirmation email is built from the User struct at
  registration, but handle/display_name live on the Identity — so the welcome
  line used to render "@!" with a blank handle.
  """
  use Hybridsocial.DataCase, async: false

  import Hybridsocial.AccountsFixtures

  alias Hybridsocial.Accounts.User
  alias Hybridsocial.Emails
  alias Hybridsocial.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Hybridsocial.Repo, {:shared, self()})
    start_supervised!(Hybridsocial.Config.Store)
    :ok
  end

  test "confirmation email renders @handle even when built from a bare User" do
    identity = create_user("mlaarebi")
    # A bare User (identity NOT preloaded) — exactly what the registration and
    # password-reset paths hand to the mailer.
    user = Repo.get_by!(User, identity_id: identity.id)
    refute Map.get(user, :handle), "handle must not live on the User struct"

    email = Emails.confirmation_email(user)

    assert email.html_body =~ "@mlaarebi"
    refute email.html_body =~ "@!"
  end

  test "subject uses the 'name: subject' format with no em dash" do
    identity = create_user("mlaarebi")
    user = Repo.get_by!(User, identity_id: identity.id)

    email = Emails.confirmation_email(user)

    assert email.subject =~ ": confirm your email address"
    refute email.subject =~ "—"
    refute email.html_body =~ "—"
  end

  test "renders the brand header (text fallback when no email logo is set)" do
    Hybridsocial.Config.set("instance_name", "Test Instance")
    identity = create_user("mlaarebi")
    user = Repo.get_by!(User, identity_id: identity.id)

    email = Emails.confirmation_email(user)

    # No logo configured in test -> the header falls back to the name text.
    assert email.subject =~ "Test Instance: confirm"
    assert email.html_body =~ "Test Instance"
  end
end
