defmodule Hybridsocial.Accounts.AccountDeletion do
  @moduledoc """
  Admin-initiated account deletion with content cleanup.

  Hard-deletes the account's own content:

    * posts and replies (their attached media rows too)
    * media the account owns, removing the underlying storage blob
      (main file, thumbnail, and every resolution variant)

  Direct messages are deliberately kept, because each conversation also
  belongs to the other participant. Instead we:

    * drop a conversation entirely when every *other* participant is also
      deleted (nobody is left to read it), and
    * otherwise leave the thread in place. The sender/participant renders
      as "Deleted User" for the survivor, because the identity row is
      soft-deleted (see `HybridsocialWeb.Helpers.Account.serialize_summary/1`).

  The identity row itself is soft-deleted (not dropped) so message
  references stay intact and federation IDs remain stable. Sub-identities
  (bots/groups/orgs) are included in the purge and cascade-soft-deleted.
  """

  import Ecto.Query
  require Logger

  alias Hybridsocial.Repo
  alias Hybridsocial.Accounts
  alias Hybridsocial.Accounts.Identity
  alias Hybridsocial.Social.Post
  alias Hybridsocial.Media.{MediaFile, MediaVariant, Storage}
  alias Hybridsocial.Messaging.{Conversation, Participant, Message}
  alias Hybridsocial.Search.Indexer

  @doc """
  Purges `identity` (and its sub-identities) and soft-deletes the account.

  Returns `{:ok, summary}` where summary counts what was removed, or
  `{:error, reason}` if the final soft-delete fails.
  """
  def delete_account(%Identity{} = identity) do
    child_ids =
      Repo.all(from(i in Identity, where: i.parent_identity_id == ^identity.id, select: i.id))

    ids = Enum.uniq([identity.id | child_ids])

    post_ids = Repo.all(from(p in Post, where: p.identity_id in ^ids, select: p.id))

    media_deleted = purge_media(ids, post_ids)
    posts_deleted = purge_posts(post_ids)
    conversations_dropped = purge_dead_conversations(ids)

    Enum.each(ids, fn id -> Accounts.admin_revoke_all_tokens(id) end)

    case Accounts.soft_delete_identity(identity) do
      {:ok, _} ->
        Enum.each(ids, fn id -> safe(fn -> Indexer.remove_identity(id) end) end)

        summary = %{
          identities: length(ids),
          posts_deleted: posts_deleted,
          media_deleted: media_deleted,
          conversations_dropped: conversations_dropped
        }

        Logger.info("[account-deletion] #{inspect(summary)} for #{identity.handle}")
        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Delete blobs + rows for every media the account owns OR that hangs off
  # one of its posts. Only locally-stored bytes are removed; `remote_url`
  # media points at bytes on a peer instance, so we just drop the row.
  defp purge_media(ids, post_ids) do
    media =
      from(m in MediaFile,
        where: m.identity_id in ^ids or m.post_id in ^post_ids
      )
      |> Repo.all()

    Enum.each(media, fn m ->
      variants = Repo.all(from(v in MediaVariant, where: v.media_id == ^m.id))
      Enum.each(variants, fn v -> if v.storage_path, do: delete_blob(v.storage_path) end)
      Repo.delete_all(from(v in MediaVariant, where: v.media_id == ^m.id))

      if m.storage_path, do: delete_blob(m.storage_path)
      if m.thumbnail_path, do: delete_blob(m.thumbnail_path)

      Repo.delete(m)
    end)

    length(media)
  end

  # Media rows are already gone; post FKs (reactions/boosts/polls/mentions)
  # cascade at the DB level and reply/quote references are SET NULL, so
  # replies BY OTHER users survive with a detached parent.
  defp purge_posts(post_ids) do
    post_ids
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      Repo.delete_all(from(p in Post, where: p.id in ^chunk))
      Enum.each(chunk, fn id -> safe(fn -> Indexer.remove_post(id) end) end)
    end)

    length(post_ids)
  end

  # Drop conversations where every remaining participant (other than the
  # accounts being deleted) is already soft-deleted. Otherwise leave the
  # thread — the survivor keeps their copy and sees "Deleted User".
  defp purge_dead_conversations(ids) do
    idset = MapSet.new(ids)

    conv_ids =
      Repo.all(
        from(p in Participant,
          where: p.identity_id in ^ids,
          distinct: true,
          select: p.conversation_id
        )
      )

    Enum.reduce(conv_ids, 0, fn conv_id, acc ->
      others =
        Repo.all(
          from(p in Participant,
            join: i in Identity,
            on: i.id == p.identity_id,
            where: p.conversation_id == ^conv_id and p.identity_id not in ^ids,
            select: {p.identity_id, i.deleted_at}
          )
        )

      all_gone? =
        Enum.all?(others, fn {oid, deleted_at} ->
          not is_nil(deleted_at) or MapSet.member?(idset, oid)
        end)

      if all_gone? do
        Repo.delete_all(from(m in Message, where: m.conversation_id == ^conv_id))
        Repo.delete_all(from(p in Participant, where: p.conversation_id == ^conv_id))
        Repo.delete_all(from(c in Conversation, where: c.id == ^conv_id))
        acc + 1
      else
        acc
      end
    end)
  end

  defp delete_blob(path), do: safe(fn -> Storage.delete(path) end)

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  end
end
