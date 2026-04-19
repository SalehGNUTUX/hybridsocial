defmodule Hybridsocial.Media.AudioTest do
  use ExUnit.Case, async: true

  alias Hybridsocial.Media.Audio

  describe "enforce_duration/2" do
    test "0 disables the check (unlimited)" do
      assert :ok = Audio.enforce_duration(999_999, 0)
    end

    test "nil disables the check (unlimited)" do
      assert :ok = Audio.enforce_duration(999_999, nil)
    end

    test "accepts duration under the cap" do
      assert :ok = Audio.enforce_duration(100.0, 120)
      assert :ok = Audio.enforce_duration(119.9, 120)
    end

    test "accepts duration within 0.5s float-rounding tolerance" do
      # ffprobe reports duration as a float; a file declared 120s
      # commonly comes back as 120.024 or 119.981. Rejecting those
      # would feel arbitrary to a user staring at a "120s limit".
      assert :ok = Audio.enforce_duration(120.3, 120)
      assert :ok = Audio.enforce_duration(120.5, 120)
    end

    test "rejects duration past the tolerance" do
      assert {:error, {:audio_too_long, max_seconds: 120, actual_seconds: 125.0}} =
               Audio.enforce_duration(125.0, 120)
    end
  end
end
