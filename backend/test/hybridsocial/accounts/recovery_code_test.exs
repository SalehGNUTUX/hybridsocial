defmodule Hybridsocial.Accounts.RecoveryCodeTest do
  use Hybridsocial.DataCase, async: true

  alias Hybridsocial.Accounts
  alias Hybridsocial.Accounts.{Identity, RecoveryCode, User}

  defp register(handle) do
    uniq = :erlang.unique_integer([:positive])

    {:ok, identity} =
      Accounts.register_user(%{
        "handle" => "#{handle}_#{uniq}",
        "email" => "#{handle}_#{uniq}@test.com",
        "display_name" => handle,
        "password" => "password1234567890",
        "password_confirmation" => "password1234567890"
      })

    identity
  end

  describe "RecoveryCode.generate/0" do
    test "returns 20 chars + 3 dashes in 4 groups of 5" do
      code = RecoveryCode.generate()
      assert String.length(code) == 23
      assert String.contains?(code, "-")

      groups = String.split(code, "-")
      assert length(groups) == 4
      assert Enum.all?(groups, &(String.length(&1) == 5))
    end

    test "draws from an unambiguous alphabet (no 0/1/I/L/O/U)" do
      # Generate many codes and verify the alphabet doesn't contain the
      # common look-alike characters.
      banned = MapSet.new(["0", "1", "I", "L", "O", "U"])

      for _ <- 1..50 do
        code = RecoveryCode.generate()
        chars = code |> String.replace("-", "") |> String.graphemes() |> MapSet.new()
        assert MapSet.disjoint?(chars, banned)
      end
    end
  end

  describe "RecoveryCode.normalize/1 and verify/2" do
    test "verify ignores case, spaces, and extra dashes" do
      code = RecoveryCode.generate()
      hash = RecoveryCode.hash(code)

      assert RecoveryCode.verify(code, hash)
      assert RecoveryCode.verify(String.downcase(code), hash)
      assert RecoveryCode.verify(String.replace(code, "-", ""), hash)
      assert RecoveryCode.verify(String.replace(code, "-", " - "), hash)
    end

    test "wrong code fails" do
      hash = RecoveryCode.hash(RecoveryCode.generate())
      refute RecoveryCode.verify(RecoveryCode.generate(), hash)
    end

    test "nil hash always fails (no enumeration)" do
      refute RecoveryCode.verify("anything", nil)
    end
  end

  describe "Accounts.generate_recovery_code/2" do
    test "stores a hash and returns plaintext once" do
      identity = register("gen_user")

      assert {:ok, code, updated} =
               Accounts.generate_recovery_code(identity.id, "password1234567890")

      assert is_binary(code)
      assert String.length(code) == 23
      assert updated.recovery_code_hash != nil
      refute updated.recovery_code_hash == code

      # And the returned hash verifies against the plaintext.
      assert RecoveryCode.verify(code, updated.recovery_code_hash)
    end

    test "rotates: old code stops working after a regeneration" do
      identity = register("rotate_user")

      {:ok, old_code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      {:ok, new_code, updated} =
        Accounts.generate_recovery_code(identity.id, "password1234567890")

      refute old_code == new_code
      refute RecoveryCode.verify(old_code, updated.recovery_code_hash)
      assert RecoveryCode.verify(new_code, updated.recovery_code_hash)
    end

    test "rejects a wrong password" do
      identity = register("wrongpw")
      assert {:error, :invalid_password} = Accounts.generate_recovery_code(identity.id, "not-it")
    end
  end

  describe "Accounts.clear_recovery_code/2" do
    test "nulls out the hash" do
      identity = register("clr_user")
      {:ok, _, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      assert {:ok, updated} = Accounts.clear_recovery_code(identity.id, "password1234567890")
      assert updated.recovery_code_hash == nil
    end

    test "rejects without password" do
      identity = register("clr_wrongpw")
      {:ok, _, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      assert {:error, :invalid_password} = Accounts.clear_recovery_code(identity.id, "nope")
    end
  end

  describe "Accounts.recover_account/4" do
    test "resets password and auto-rotates the code on success" do
      identity = register("recover_ok")
      {:ok, code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      assert {:ok, new_code, recovered} =
               Accounts.recover_account(
                 identity.handle,
                 code,
                 "newpassword1234567890",
                 "newpassword1234567890"
               )

      # A new code is issued, different from the one just used.
      refute new_code == code
      assert recovered.recovered_at != nil
      assert recovered.recovery_code_last_used_at != nil

      # Old code no longer works.
      assert {:error, :invalid_credentials} =
               Accounts.recover_account(
                 identity.handle,
                 code,
                 "anotherpass1234567890",
                 "anotherpass1234567890"
               )

      # New password logs in; old one doesn't.
      user = Repo.get_by!(User, identity_id: identity.id)
      assert Bcrypt.verify_pass("newpassword1234567890", user.password_hash)
      refute Bcrypt.verify_pass("password1234567890", user.password_hash)
    end

    test "rejects wrong code" do
      identity = register("recover_wrong")
      {:ok, _code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      assert {:error, :invalid_credentials} =
               Accounts.recover_account(
                 identity.handle,
                 RecoveryCode.generate(),
                 "newpassword1234567890",
                 "newpassword1234567890"
               )
    end

    test "rejects when identity has no code set" do
      identity = register("no_code")

      assert {:error, :invalid_credentials} =
               Accounts.recover_account(
                 identity.handle,
                 RecoveryCode.generate(),
                 "newpassword1234567890",
                 "newpassword1234567890"
               )
    end

    test "rejects unknown handle" do
      assert {:error, :invalid_credentials} =
               Accounts.recover_account(
                 "definitelynotarealhandle",
                 RecoveryCode.generate(),
                 "newpassword1234567890",
                 "newpassword1234567890"
               )
    end

    test "rejects weak new password" do
      identity = register("weak_pw")
      {:ok, code, _} = Accounts.generate_recovery_code(identity.id, "password1234567890")

      assert {:error, :invalid_password, _cs} =
               Accounts.recover_account(identity.handle, code, "short", "short")
    end
  end

  describe "Accounts.in_recovery_cooldown?/1" do
    test "true within 24h of recovered_at, false otherwise" do
      assert false == Accounts.in_recovery_cooldown?(%Identity{recovered_at: nil})

      just_recovered = DateTime.utc_now() |> DateTime.add(-60, :second)
      assert true == Accounts.in_recovery_cooldown?(%Identity{recovered_at: just_recovered})

      long_ago = DateTime.utc_now() |> DateTime.add(-48 * 3600, :second)
      assert false == Accounts.in_recovery_cooldown?(%Identity{recovered_at: long_ago})
    end
  end
end
