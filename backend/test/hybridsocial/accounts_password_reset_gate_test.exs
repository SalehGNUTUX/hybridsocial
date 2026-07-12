defmodule Hybridsocial.Accounts.PasswordResetGateTest do
  @moduledoc """
  Regression coverage for the PoW/captcha gate on the public
  `request_password_reset/1` (map form) — reset-email requests must be as
  abuse-resistant as signup and recovery.
  """
  use Hybridsocial.DataCase, async: false

  alias Hybridsocial.Accounts
  alias Hybridsocial.Config

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Hybridsocial.Repo, {:shared, self()})
    start_supervised!(Hybridsocial.Config.Store)
    # Baseline: gates off.
    Config.set("pow_enabled", false)
    Config.set("captcha_provider", "none")
    Config.set("turnstile_secret_key", "")
    :ok
  end

  test "rejects the request when PoW is on and no solution is supplied" do
    Config.set("pow_enabled", true)

    assert {:error, :pow_required} =
             Accounts.request_password_reset(%{"email" => "x@example.com"})
  end

  test "rejects the request when a captcha provider is on and no token is supplied" do
    Config.set("captcha_provider", "turnstile")
    Config.set("turnstile_secret_key", "secret")

    assert {:error, :missing_token} =
             Accounts.request_password_reset(%{"email" => "x@example.com"})
  end

  test "returns non-committal :sent when gates are off, even for an unknown email" do
    assert {:ok, :sent} = Accounts.request_password_reset(%{"email" => "nobody@example.com"})
  end

  test "a blank email still can't be used to probe accounts" do
    assert {:ok, :sent} = Accounts.request_password_reset(%{})
  end

  test "the binary-arg form is for trusted internal callers and stays ungated" do
    Config.set("pow_enabled", true)
    assert {:ok, :sent} = Accounts.request_password_reset("nobody@example.com")
  end

  describe "check_bot_gates/1 (shared login/signup/reset gate)" do
    test "passes when both gates are disabled" do
      assert :ok = Accounts.check_bot_gates(%{})
    end

    test "fails on PoW first when PoW is enabled without a solution" do
      Config.set("pow_enabled", true)
      assert {:error, :pow_required} = Accounts.check_bot_gates(%{})
    end

    test "fails on captcha when a provider is enabled without a token" do
      Config.set("captcha_provider", "hcaptcha")
      Config.set("hcaptcha_secret_key", "secret")
      assert {:error, :missing_token} = Accounts.check_bot_gates(%{})
    end
  end
end
