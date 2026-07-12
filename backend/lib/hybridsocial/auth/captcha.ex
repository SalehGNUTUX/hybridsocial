defmodule Hybridsocial.Auth.Captcha do
  @moduledoc """
  Bot-protection captcha with a single admin-selected provider: Cloudflare
  Turnstile, hCaptcha, or Google reCAPTCHA v3.

  All three share the same siteverify contract — `POST {secret, response}`
  form-encoded, returning `{"success": bool, ...}` — so one verifier covers
  them. reCAPTCHA v3 additionally returns a 0.0–1.0 `score`, which we compare
  against a configurable threshold (`recaptcha_min_score`, default 0.5).

  Config keys (all DB-backed, edited in the admin panel):
    * `captcha_provider`      — "none" | "turnstile" | "hcaptcha" | "recaptcha"
    * `<provider>_site_key`   — public key, sent to the browser widget
    * `<provider>_secret_key` — private key, used here to verify (hidden in admin)
    * `recaptcha_min_score`   — v3 pass threshold
  """
  alias Hybridsocial.Config

  @providers ~w(turnstile hcaptcha recaptcha)

  @verify_urls %{
    "turnstile" => "https://challenges.cloudflare.com/turnstile/v0/siteverify",
    "hcaptcha" => "https://api.hcaptcha.com/siteverify",
    "recaptcha" => "https://www.google.com/recaptcha/api/siteverify"
  }

  @default_min_score 0.5

  @doc """
  The active provider (a string in #{inspect(@providers)}), or `nil` when
  captcha is off or the selected provider has no secret configured.
  """
  def provider do
    selected = Config.get("captcha_provider", "none")

    cond do
      selected in @providers and secret_key(selected) != "" ->
        selected

      # Back-compat: instances that configured Turnstile before the provider
      # selector existed have a turnstile secret but no `captcha_provider`.
      selected in ["none", nil, ""] and Config.get("turnstile_secret_key", "") != "" ->
        "turnstile"

      true ->
        nil
    end
  end

  @doc "Whether a captcha challenge should be required."
  def enabled?, do: provider() != nil

  @doc "Public site key for the active provider (empty when captcha is off)."
  def site_key do
    case provider() do
      nil -> ""
      p -> Config.get("#{p}_site_key", "")
    end
  end

  @doc """
  Verify a captcha token against the active provider.

  Returns `{:ok, true}` on success (including when captcha is disabled — the
  caller gates on `enabled?/0`), or `{:error, reason}` where reason is one of
  `:missing_token`, `:captcha_failed`, `:captcha_service_unavailable`,
  `:captcha_parse_error`.
  """
  def verify(token) do
    case provider() do
      nil -> {:ok, true}
      provider -> verify_with(provider, token)
    end
  end

  defp verify_with(_provider, token) when token in [nil, ""], do: {:error, :missing_token}

  defp verify_with(provider, token) do
    body = URI.encode_query(%{secret: secret_key(provider), response: token})
    url = Map.fetch!(@verify_urls, provider)

    case Hybridsocial.HTTP.post(url, body, [
           {"Content-Type", "application/x-www-form-urlencoded"}
         ]) do
      {:ok, %{status_code: 200, body: resp_body}} -> parse_result(provider, resp_body)
      _ -> {:error, :captcha_service_unavailable}
    end
  end

  defp parse_result(provider, resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true} = resp} -> check_score(provider, resp)
      {:ok, %{"success" => false}} -> {:error, :captcha_failed}
      _ -> {:error, :captcha_parse_error}
    end
  end

  # reCAPTCHA v3 is score-based; a "success" with a low score is still a bot.
  # Turnstile/hCaptcha are pass/fail and carry no score.
  def check_score("recaptcha", %{"score" => score}) when is_number(score) do
    if score >= min_score(), do: {:ok, true}, else: {:error, :captcha_failed}
  end

  def check_score(_provider, _resp), do: {:ok, true}

  defp secret_key(provider), do: Config.get("#{provider}_secret_key", "")

  @doc "reCAPTCHA v3 pass threshold, coerced from the (possibly string) config."
  def min_score do
    case Config.get("recaptcha_min_score", @default_min_score) do
      n when is_number(n) ->
        n

      s when is_binary(s) ->
        case Float.parse(s) do
          {f, _} -> f
          :error -> @default_min_score
        end

      _ ->
        @default_min_score
    end
  end
end
