defmodule Mix.Tasks.Hybridsocial.Backfill.RemoteEmojis do
  @moduledoc """
  One-off backfill: re-fetch every remote actor and repopulate its profile,
  including the `emojis` and `profile_url` columns added after those actors
  were first federated. Without this, already-known remote users keep showing
  raw `:shortcode:` in their display_name and have no "view on original" link
  until something else re-fetches them.

  Usage:

      mix hybridsocial.backfill.remote_emojis          # only rows missing data
      mix hybridsocial.backfill.remote_emojis --all     # every remote identity

  Sequential with a small delay between fetches to avoid hammering peers.
  """
  use Mix.Task
  import Ecto.Query
  require Logger

  alias Hybridsocial.Repo
  alias Hybridsocial.Accounts.Identity
  alias Hybridsocial.Federation.Inbox

  @shortdoc "Re-fetch remote actors to backfill emojis + profile URLs"
  @delay_ms 250

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    all? = "--all" in args

    query =
      from(i in Identity, where: i.is_local == false)
      |> maybe_only_missing(all?)

    ids = Repo.all(from(i in query, select: i.id))
    total = length(ids)

    Mix.shell().info(
      "Backfilling #{total} remote #{if all?, do: "(all)", else: "(missing data)"} identities..."
    )

    {ok, failed} =
      ids
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {id, idx}, {ok, failed} ->
        result =
          case Repo.get(Identity, id) do
            nil -> :error
            identity -> Inbox.reenrich_remote_identity(identity)
          end

        Process.sleep(@delay_ms)

        case result do
          {:ok, _} ->
            if rem(idx, 25) == 0, do: Mix.shell().info("  #{idx}/#{total}")
            {ok + 1, failed}

          other ->
            Logger.warning("Backfill failed for #{id}: #{inspect(other)}")
            {ok, failed + 1}
        end
      end)

    Mix.shell().info("Done. #{ok} refreshed, #{failed} failed.")
  end

  # Default run only touches rows that plausibly predate the columns: no
  # emojis stored AND no profile_url. --all forces a full refresh.
  defp maybe_only_missing(query, true), do: query

  defp maybe_only_missing(query, false) do
    from i in query,
      where: is_nil(i.profile_url) and (i.emojis == ^[] or is_nil(i.emojis))
  end
end
