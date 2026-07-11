defmodule Hybridsocial.Federation.CircuitBreakerTest do
  use Hybridsocial.DataCase, async: true

  alias Hybridsocial.Federation.{CircuitBreaker, RemoteInstance}
  alias Hybridsocial.Repo

  @inbox "https://dead.example/users/x/inbox"

  defp inst, do: Repo.get_by(RemoteInstance, domain: "dead.example")

  test "healthy/unknown instance always allows delivery" do
    assert CircuitBreaker.allow?(@inbox)
    # Unparseable inbox -> nil domain -> fail open, never block a real delivery.
    assert CircuitBreaker.allow?("not a url")
  end

  test "hard failures below threshold count but keep the circuit closed" do
    for _ <- 1..4, do: CircuitBreaker.record_result(@inbox, :hard)
    assert CircuitBreaker.allow?(@inbox)
    assert inst().consecutive_failures == 4
    assert is_nil(inst().circuit_reopen_at)
  end

  test "threshold consecutive hard failures opens the circuit" do
    for _ <- 1..5, do: CircuitBreaker.record_result(@inbox, :hard)
    refute CircuitBreaker.allow?(@inbox)
    i = inst()
    assert i.consecutive_failures == 5
    assert i.unreachable_since
    assert DateTime.compare(i.circuit_reopen_at, DateTime.utc_now()) == :gt
  end

  test "soft (HTTP status) failures never open the circuit" do
    for _ <- 1..10, do: CircuitBreaker.record_result(@inbox, :soft)
    assert CircuitBreaker.allow?(@inbox)
    # A pure soft failure doesn't even create a row — the server is up.
    assert is_nil(inst())
  end

  test "a success resets failures and closes an open circuit" do
    for _ <- 1..5, do: CircuitBreaker.record_result(@inbox, :hard)
    refute CircuitBreaker.allow?(@inbox)

    CircuitBreaker.record_result(@inbox, :ok)

    assert CircuitBreaker.allow?(@inbox)
    i = inst()
    assert i.consecutive_failures == 0
    assert is_nil(i.circuit_reopen_at)
    assert is_nil(i.unreachable_since)
  end

  test "half-open: once the reopen time passes, one probe is allowed and a fresh failure re-opens further out" do
    for _ <- 1..5, do: CircuitBreaker.record_result(@inbox, :hard)
    refute CircuitBreaker.allow?(@inbox)

    # Simulate the probe window arriving.
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)
    inst() |> RemoteInstance.changeset(%{circuit_reopen_at: past}) |> Repo.update!()

    assert CircuitBreaker.allow?(@inbox)

    # Probe fails again -> failures escalate, reopen pushed back into the future.
    CircuitBreaker.record_result(@inbox, :hard)
    i = inst()
    assert i.consecutive_failures == 6
    assert DateTime.compare(i.circuit_reopen_at, DateTime.utc_now()) == :gt
  end
end
