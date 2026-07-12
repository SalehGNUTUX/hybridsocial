defmodule Hybridsocial.Auth.CaptchaTest do
  use Hybridsocial.DataCase, async: false

  alias Hybridsocial.Auth.Captcha
  alias Hybridsocial.Config

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Hybridsocial.Repo, {:shared, self()})
    start_supervised!(Hybridsocial.Config.Store)
    :ok
  end

  describe "provider/0" do
    test "is nil when no captcha is configured" do
      Config.set("captcha_provider", "none")
      assert Captcha.provider() == nil
      refute Captcha.enabled?()
    end

    test "returns the selected provider when its secret is set" do
      Config.set("captcha_provider", "hcaptcha")
      Config.set("hcaptcha_secret_key", "0xSECRET")
      assert Captcha.provider() == "hcaptcha"
      assert Captcha.enabled?()
    end

    test "is nil when a provider is selected but its secret is blank" do
      Config.set("captcha_provider", "recaptcha")
      Config.set("recaptcha_secret_key", "")
      assert Captcha.provider() == nil
    end

    test "back-compat: falls back to turnstile when only a turnstile secret is set" do
      Config.set("captcha_provider", "none")
      Config.set("turnstile_secret_key", "1x0000")
      assert Captcha.provider() == "turnstile"
    end
  end

  describe "site_key/0" do
    test "returns the active provider's public key" do
      Config.set("captcha_provider", "turnstile")
      Config.set("turnstile_secret_key", "secret")
      Config.set("turnstile_site_key", "0xPUBLIC")
      assert Captcha.site_key() == "0xPUBLIC"
    end

    test "is empty when captcha is off" do
      Config.set("captcha_provider", "none")
      Config.set("turnstile_secret_key", "")
      assert Captcha.site_key() == ""
    end
  end

  describe "verify/1" do
    test "is a no-op success when captcha is disabled" do
      Config.set("captcha_provider", "none")
      Config.set("turnstile_secret_key", "")
      assert Captcha.verify("anything") == {:ok, true}
      assert Captcha.verify(nil) == {:ok, true}
    end

    test "rejects a missing token when a provider is active" do
      Config.set("captcha_provider", "hcaptcha")
      Config.set("hcaptcha_secret_key", "secret")
      assert Captcha.verify(nil) == {:error, :missing_token}
      assert Captcha.verify("") == {:error, :missing_token}
    end
  end

  describe "check_score/2 (reCAPTCHA v3 threshold)" do
    test "passes when the score meets the threshold" do
      Config.set("recaptcha_min_score", "0.5")
      assert Captcha.check_score("recaptcha", %{"score" => 0.9}) == {:ok, true}
      assert Captcha.check_score("recaptcha", %{"score" => 0.5}) == {:ok, true}
    end

    test "fails a low score even though success was true" do
      Config.set("recaptcha_min_score", "0.5")
      assert Captcha.check_score("recaptcha", %{"score" => 0.1}) == {:error, :captcha_failed}
    end

    test "non-recaptcha providers are pass/fail only (no score gate)" do
      assert Captcha.check_score("turnstile", %{}) == {:ok, true}
      assert Captcha.check_score("hcaptcha", %{"score" => 0.0}) == {:ok, true}
    end
  end

  describe "min_score/0" do
    test "defaults to 0.5 and coerces string config" do
      Config.set("recaptcha_min_score", "0.7")
      assert Captcha.min_score() == 0.7
    end
  end
end
