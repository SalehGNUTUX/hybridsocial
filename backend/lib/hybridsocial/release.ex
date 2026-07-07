defmodule Hybridsocial.Release do
  @moduledoc """
  Tasks that can be run via `bin/hybridsocial eval`.
  """

  @app :hybridsocial

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Re-fetch remote actors to backfill the `emojis` and `profile_url` columns
  added after those actors were first federated (so already-known remote
  users stop showing raw `:shortcode:` and gain a "view on original" link).

  Run on the LIVE node so the Repo + HTTP client are already started:

      bin/hybridsocial rpc "Hybridsocial.Release.backfill_remote_emojis()"
      bin/hybridsocial rpc "Hybridsocial.Release.backfill_remote_emojis(all: true)"

  Default touches only rows plausibly predating the columns (no
  profile_url); `all: true` refreshes every remote identity. Sequential
  with a small delay so we don't hammer peers. Returns `{:ok, refreshed, total}`.
  """
  def backfill_remote_emojis(opts \\ []) do
    import Ecto.Query
    alias Hybridsocial.Accounts.Identity
    alias Hybridsocial.Federation.Inbox
    alias Hybridsocial.Repo

    all? = Keyword.get(opts, :all, false)
    base = from(i in Identity, where: i.is_local == false)
    query = if all?, do: base, else: from(i in base, where: is_nil(i.profile_url))

    ids = Repo.all(from(i in query, select: i.id))
    total = length(ids)
    IO.puts("[backfill] #{total} remote #{if all?, do: "(all)", else: "(missing)"} identities")

    # Concurrent with a hard per-identity budget: most of these 5000+ peers
    # are dead/slow, and a single unresponsive host would otherwise block a
    # sequential run for its full connect timeout. async_stream kills any
    # task past `timeout` (on_timeout: :kill_task) and isolates crashes, so
    # one bad actor can't stall or abort the batch.
    refreshed =
      ids
      |> Task.async_stream(
        fn id ->
          case Repo.get(Identity, id) do
            nil -> :error
            identity -> Inbox.reenrich_remote_identity(identity)
          end
        end,
        max_concurrency: 20,
        timeout: 15_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce(0, fn
        {:ok, {:ok, _}}, acc -> acc + 1
        _other, acc -> acc
      end)

    IO.puts("[backfill] done: #{refreshed}/#{total} refreshed")
    {:ok, refreshed, total}
  end

  def setup do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _ -> :ok end)
    end

    migrate()
    seed()
  end

  # sobelow_skip ["RCE.CodeModule"]
  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          seed_file = Path.join([:code.priv_dir(@app), "repo", "seeds.exs"])

          if File.exists?(seed_file) do
            Code.eval_file(seed_file)
          end
        end)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
