defmodule Hybridsocial.Premium.TierLimitsAudioTest do
  use ExUnit.Case, async: true

  alias Hybridsocial.Premium.TierLimits

  describe "audio tier defaults" do
    test "free tier does NOT allow audio (boolean false)" do
      limits = TierLimits.limits_for_tier("free")
      assert limits[:audio_allowed] == false
    end

    test "paid tiers allow audio" do
      for tier <- ~w(verified_starter verified_creator verified_pro) do
        assert TierLimits.limits_for_tier(tier)[:audio_allowed] == true,
               "expected #{tier} to allow audio"
      end
    end

    test "audio size limits scale with tier" do
      free = TierLimits.limits_for_tier("free")[:audio_size_mb]
      starter = TierLimits.limits_for_tier("verified_starter")[:audio_size_mb]
      creator = TierLimits.limits_for_tier("verified_creator")[:audio_size_mb]
      pro = TierLimits.limits_for_tier("verified_pro")[:audio_size_mb]

      # Free has a number (2) even though audio isn't allowed, so the
      # setting exists for future "silver lining: allow audio preview
      # for free users" kind of changes. Paid tiers scale up.
      assert free == 2
      assert starter == 8
      assert creator == 15
      assert pro == 50
    end

    test "audio duration limits scale with tier" do
      assert TierLimits.limits_for_tier("free")[:audio_duration] == 120
      assert TierLimits.limits_for_tier("verified_starter")[:audio_duration] == 300
      assert TierLimits.limits_for_tier("verified_creator")[:audio_duration] == 900
      assert TierLimits.limits_for_tier("verified_pro")[:audio_duration] == 1800
    end
  end
end
