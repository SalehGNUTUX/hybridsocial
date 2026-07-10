defmodule Hybridsocial.Accounts.DeletedContentPurge do
  @moduledoc """
  Hard-deletes the posts (and their media) of already soft-deleted
  identities, then removes those posts and the identities from the search
  index. Used after purging spam/bot accounts so nothing lingers in the DB
  or OpenSearch.

  Post deletes cascade reactions/bookmarks/boosts/polls/mentions/
  stream_views at the DB level; reply/quote references are SET NULL.
  """

  import Ecto.Query
  require Logger

  alias Hybridsocial.Repo
  alias Hybridsocial.Social.Post
  alias Hybridsocial.Media.MediaFile
  alias Hybridsocial.Search.Indexer

  def purge(identity_ids) when is_list(identity_ids) do
    post_ids = Repo.all(from(p in Post, where: p.identity_id in ^identity_ids, select: p.id))
    total = length(post_ids)
    Logger.info("[content-purge] #{total} posts across #{length(identity_ids)} identities")

    post_ids
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      Repo.transaction(fn ->
        Repo.delete_all(from(m in MediaFile, where: m.post_id in ^chunk))
        Repo.delete_all(from(p in Post, where: p.id in ^chunk))
      end)

      Enum.each(chunk, fn id -> safe(fn -> Indexer.remove_post(id) end) end)
      Logger.info("[content-purge] purged #{length(chunk)} posts")
    end)

    # Drop the (soft-deleted) identities from the accounts index too.
    Enum.each(identity_ids, fn id -> safe(fn -> Indexer.remove_identity(id) end) end)

    result = %{identities: length(identity_ids), posts_deleted: total}
    Logger.info("[content-purge] DONE #{inspect(result)}")
    result
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  end
end
