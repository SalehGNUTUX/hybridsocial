defmodule Hybridsocial.Federation.CircuitBreaker do
  @moduledoc """
  Per-domain delivery circuit breaker.

  A persistently-dead remote instance (DNS gone, dead TLS cert, connection
  refused) used to get a fresh delivery attempt for *every* activity we
  fanned out to it — hundreds of pointless DNS/TLS/connect attempts per dead
  host. This trips a breaker after `@threshold` consecutive **connection-level**
  failures and then skips delivery until `circuit_reopen_at`, at which point a
  single probe is allowed to recover.

  Only connection-level failures (`:hard`) trip the breaker — those mean the
  instance is *down*. An HTTP status error (`:soft`, e.g. a 500 on one Delete
  or a 404 for a deactivated user) means the server is *up* and answering, so
  it must NOT open the circuit for the whole domain.

  State lives on `remote_instances` (`consecutive_failures`,
  `unreachable_since`, `circuit_reopen_at`).
  """
  require Logger

  alias Hybridsocial.Federation.{ActivityMapper, RemoteInstance}
  alias Hybridsocial.Repo

  # Consecutive hard failures before the circuit opens.
  @threshold 5
  # Escalating re-probe backoff once open, indexed by (failures - threshold).
  @reopen_backoff_seconds [3_600, 21_600, 86_400, 259_200]

  @typedoc "Outcome category for a single delivery attempt."
  @type category :: :ok | :soft | :hard

  @doc """
  Whether we should attempt delivery to this inbox right now.

  Returns `true` when the circuit is closed, or open-but-due-for-a-probe
  (`circuit_reopen_at` has passed). Returns `false` only while the circuit is
  open and the next probe time is still in the future. Unknown/malformed
  inboxes always return `true` (fail open — never block a real delivery on a
  breaker bug).
  """
  @spec allow?(String.t()) :: boolean()
  def allow?(inbox_url) do
    case domain(inbox_url) do
      nil ->
        true

      domain ->
        case Repo.get_by(RemoteInstance, domain: domain) do
          %RemoteInstance{circuit_reopen_at: %DateTime{} = reopen} ->
            # Allow once now >= reopen (half-open probe).
            DateTime.compare(now(), reopen) != :lt

          _ ->
            true
        end
    end
  end

  @doc """
  Record the outcome of a delivery attempt and update the breaker.

    * `:ok`   — success: reset failures, close the circuit.
    * `:soft` — HTTP status error: server is up, leave the circuit alone.
    * `:hard` — connection error: count it; open the circuit at the threshold.
  """
  @spec record_result(String.t(), category()) :: :ok
  def record_result(inbox_url, category) do
    case domain(inbox_url) do
      nil -> :ok
      domain -> update(domain, category)
    end
  end

  # --- internal ---

  defp update(_domain, :soft), do: :ok

  defp update(domain, :ok) do
    case Repo.get_by(RemoteInstance, domain: domain) do
      %RemoteInstance{} = inst
      when inst.consecutive_failures > 0 or inst.circuit_reopen_at != nil ->
        if inst.circuit_reopen_at do
          Logger.info("[circuit] #{domain} recovered — closing circuit")
        end

        upsert(domain, %{consecutive_failures: 0, unreachable_since: nil, circuit_reopen_at: nil})

      _ ->
        :ok
    end
  end

  defp update(domain, :hard) do
    inst = Repo.get_by(RemoteInstance, domain: domain)
    fails = ((inst && inst.consecutive_failures) || 0) + 1

    attrs =
      if fails >= @threshold do
        reopen = DateTime.add(now(), backoff(fails), :second)
        since = (inst && inst.unreachable_since) || now()

        # Log only on the transition into "open" so we don't spam every probe.
        if is_nil(inst) or is_nil(inst.circuit_reopen_at) do
          Logger.warning(
            "[circuit] #{domain} opened after #{fails} consecutive connection failures; " <>
              "next probe at #{DateTime.to_iso8601(reopen)}"
          )
        end

        %{consecutive_failures: fails, unreachable_since: since, circuit_reopen_at: reopen}
      else
        %{consecutive_failures: fails}
      end

    upsert(domain, attrs)
  end

  # Backoff grows with how long the instance has been failing: 1h, 6h, 24h,
  # then 72h for anything further out.
  defp backoff(fails) do
    idx = min(fails - @threshold, length(@reopen_backoff_seconds) - 1)
    Enum.at(@reopen_backoff_seconds, max(idx, 0))
  end

  defp upsert(domain, attrs) do
    case Repo.get_by(RemoteInstance, domain: domain) do
      nil ->
        %RemoteInstance{}
        |> RemoteInstance.changeset(Map.put(attrs, :domain, domain))
        |> Repo.insert(on_conflict: {:replace, Map.keys(attrs)}, conflict_target: :domain)

      inst ->
        inst |> RemoteInstance.changeset(attrs) |> Repo.update()
    end

    :ok
  end

  defp domain(inbox_url), do: ActivityMapper.extract_domain(inbox_url)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
