defmodule Hybridsocial.Media.EmailLogoTest do
  use ExUnit.Case, async: true

  alias Hybridsocial.Media.EmailLogo

  test "rejects a non-upload input without raising" do
    assert {:error, :invalid_upload} = EmailLogo.derive(nil)
    assert {:error, :invalid_upload} = EmailLogo.derive(%{not: :an_upload})
  end

  test "rejects a blank/invalid url without raising" do
    assert {:error, :invalid_url} = EmailLogo.derive_from_url("")
    assert {:error, :invalid_url} = EmailLogo.derive_from_url(nil)
  end
end
