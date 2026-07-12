defmodule Hybridsocial.Media.EmailLogoTest do
  use ExUnit.Case, async: true

  alias Hybridsocial.Media.EmailLogo

  test "rejects a non-upload input without raising" do
    assert {:error, :invalid_upload} = EmailLogo.derive("id", nil)
    assert {:error, :invalid_upload} = EmailLogo.derive("id", %{not: :an_upload})
  end
end
