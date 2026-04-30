defmodule Hybridsocial.Portability do
  @moduledoc """
  The Portability context. Manages data exports, imports, and account deletion.
  """
  import Ecto.Query
  alias Hybridsocial.Repo
  alias Hybridsocial.Portability.{DataExport, AccountDeletion}
  alias Hybridsocial.Accounts

  @deletion_delay_days 30

  # --- Data Export ---

  def request_export(identity_id) do
    %DataExport{}
    |> DataExport.changeset(%{
      identity_id: identity_id,
      status: "pending",
      requested_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  def get_exports(identity_id) do
    DataExport
    |> where([e], e.identity_id == ^identity_id)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  def get_export(id, identity_id) do
    DataExport
    |> where([e], e.id == ^id and e.identity_id == ^identity_id)
    |> Repo.one()
  end

  # sobelow_skip ["Traversal.FileModule"]
  def generate_export(export_id) do
    case Repo.get(DataExport, export_id) do
      nil ->
        {:error, :not_found}

      export ->
        export
        |> Ecto.Changeset.change(status: "processing")
        |> Repo.update!()

        try do
          identity_id = export.identity_id
          identity = Accounts.get_identity(identity_id)

          data = %{
            profile: serialize_profile(identity),
            posts: collect_posts(identity_id),
            follows: collect_follows(identity_id),
            followers: collect_followers(identity_id),
            blocks: collect_blocks(identity_id),
            mutes: collect_mutes(identity_id),
            bookmarks: collect_bookmarks(identity_id),
            lists: collect_lists(identity_id)
          }

          export_dir = export_directory()
          File.mkdir_p!(export_dir)

          json_path = Path.join(export_dir, "#{export.id}.json")
          File.write!(json_path, Jason.encode!(data, pretty: true))

          tar_path = Path.join(export_dir, "#{export.id}.tar.gz")

          :erl_tar.create(
            String.to_charlist(tar_path),
            [{String.to_charlist("export.json"), File.read!(json_path)}],
            [:compressed]
          )

          file_size = File.stat!(tar_path).size
          File.rm!(json_path)

          export
          |> DataExport.complete_changeset(tar_path, file_size)
          |> Repo.update()
        rescue
          e ->
            export
            |> DataExport.fail_changeset()
            |> Repo.update()

            {:error, Exception.message(e)}
        end
    end
  end

  @doc "Delete export files older than 1 hour."
  # sobelow_skip ["Traversal.FileModule"]
  def cleanup_expired_exports do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    exports =
      DataExport
      |> where([e], not is_nil(e.file_path) and e.inserted_at < ^cutoff)
      |> Repo.all()

    Enum.each(exports, fn export ->
      if export.file_path && File.exists?(export.file_path) do
        File.rm(export.file_path)
      end

      export
      |> Ecto.Changeset.change(file_path: nil)
      |> Repo.update()
    end)

    {:ok, length(exports)}
  end

  # --- Data Import ---

  def import_follows(identity_id, data),
    do: import_handles_async(data, identity_id, :follow)

  def import_blocks(identity_id, data),
    do: import_handles_async(data, identity_id, :block)

  def import_mutes(identity_id, data),
    do: import_handles_async(data, identity_id, :mute)

  # Resolves a Mastodon-style `username@domain` (or bare local handle)
  # to a local Identity row, fetching and creating the row from the
  # remote actor when we've never seen them before. Returns `nil` if
  # the handle is unresolvable (DNS failure, defederated host,
  # malformed entry).
  defp resolve_handle_for_import(raw) do
    handle = raw |> String.trim() |> String.trim_leading("@")

    case String.split(handle, "@", parts: 2) do
      [user, domain] when domain != "" ->
        if local_domain?(domain) do
          Accounts.get_identity_by_handle(user)
        else
          resolve_remote(user, domain)
        end

      [user] ->
        Accounts.get_identity_by_handle(user)

      _ ->
        nil
    end
  end

  defp local_domain?(domain) do
    case URI.parse(Hybridsocial.Federation.LocalUrl.base_url()) do
      %URI{host: host} when is_binary(host) ->
        String.downcase(domain) == String.downcase(host)

      _ ->
        false
    end
  end

  defp resolve_remote(user, domain) do
    acct = "#{user}@#{domain}"

    with {:ok, %{ap_id: ap_id}} when is_binary(ap_id) <-
           Hybridsocial.Federation.WebFinger.finger(acct),
         {:ok, identity} <-
           Hybridsocial.Federation.Inbox.resolve_or_create_remote_identity(ap_id) do
      identity
    else
      _ -> nil
    end
  end

  # The follow/block/mute path can take several seconds per entry
  # because remote actors trigger a Webfinger call and an actor JSON
  # fetch the first time we see them. A 269-row import would blow
  # the HTTP request timeout, so the controller calls into here and
  # we kick the work off in a supervised Task. The response counts
  # parsed handles; actual completion is observable via the user's
  # following/blocks/mutes lists growing as the worker progresses.
  defp import_handles_async(data, identity_id, action) do
    handles =
      data
      |> normalize_to_lines()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> drop_csv_header()
      |> Enum.map(&first_csv_cell/1)
      |> Enum.reject(&(&1 == ""))

    Task.Supervisor.start_child(Hybridsocial.TaskSupervisor, fn ->
      run_import(identity_id, action, handles)
    end)

    {:ok, %{queued: length(handles), started: true}}
  end

  defp run_import(identity_id, action, handles) do
    handles
    |> Task.async_stream(
      fn handle -> apply_action(identity_id, action, handle) end,
      max_concurrency: 5,
      timeout: 30_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()
  end

  defp apply_action(identity_id, :follow, handle) do
    with %{} = target <- resolve_handle_for_import(handle),
         {:ok, _} <- Hybridsocial.Social.follow(identity_id, target.id) do
      :ok
    else
      _ -> :error
    end
  end

  defp apply_action(identity_id, :block, handle) do
    with %{} = target <- resolve_handle_for_import(handle),
         {:ok, _} <- Hybridsocial.Social.block(identity_id, target.id) do
      :ok
    else
      _ -> :error
    end
  end

  defp apply_action(identity_id, :mute, handle) do
    with %{} = target <- resolve_handle_for_import(handle),
         {:ok, _} <- Hybridsocial.Social.mute(identity_id, target.id) do
      :ok
    else
      _ -> :error
    end
  end

  # Shared CSV parser used by import_handles_async/3. Accepts either
  # a single string blob or a pre-split list of lines (the frontend
  # used to do its own split, which crashed String.split here).
  # Strips Mastodon's "Account address,Show boosts" header when
  # present and takes the first CSV cell of each remaining row.
  defp normalize_to_lines(s) when is_binary(s), do: String.split(s, ~r/\r?\n/, trim: true)
  defp normalize_to_lines(list) when is_list(list), do: list
  defp normalize_to_lines(_), do: []

  defp drop_csv_header([first | rest] = lines) do
    if csv_header?(first), do: rest, else: lines
  end

  defp drop_csv_header([]), do: []

  defp csv_header?(line) do
    cell = line |> first_csv_cell() |> String.downcase()
    cell == "account address" or cell == "account" or cell == "handle"
  end

  defp first_csv_cell(line) do
    line
    |> String.split(",", parts: 2)
    |> List.first()
    |> Kernel.||("")
    |> String.trim()
    |> String.trim_leading("@")
  end

  # --- Account Deletion ---

  def request_deletion(identity_id, reason \\ nil) do
    scheduled_for = DateTime.add(DateTime.utc_now(), @deletion_delay_days * 24 * 3600, :second)

    %AccountDeletion{}
    |> AccountDeletion.changeset(%{
      identity_id: identity_id,
      reason: reason,
      scheduled_for: scheduled_for
    })
    |> Repo.insert()
  end

  def cancel_deletion(identity_id) do
    case get_active_deletion(identity_id) do
      nil ->
        {:error, :not_found}

      deletion ->
        deletion
        |> AccountDeletion.cancel_changeset()
        |> Repo.update()
    end
  end

  def get_deletion(identity_id) do
    get_active_deletion(identity_id)
  end

  def execute_deletion(deletion_id) do
    case Repo.get(AccountDeletion, deletion_id) do
      nil ->
        {:error, :not_found}

      deletion ->
        identity = Accounts.get_identity(deletion.identity_id)

        if identity do
          # Soft delete identity
          Accounts.soft_delete_identity(identity)

          # Future: Send AP Delete activity
          # Hybridsocial.Federation.publish_delete(identity)

          # Anonymize data
          anonymize_identity(identity)
        end

        # Mark deletion as executed
        deletion
        |> AccountDeletion.execute_changeset()
        |> Repo.update()
    end
  end

  # --- Private helpers ---

  defp get_active_deletion(identity_id) do
    AccountDeletion
    |> where(
      [d],
      d.identity_id == ^identity_id and is_nil(d.cancelled_at) and is_nil(d.executed_at)
    )
    |> order_by([d], desc: d.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp anonymize_identity(identity) do
    identity
    |> Ecto.Changeset.change(%{
      display_name: nil,
      bio: nil,
      avatar_url: nil,
      header_url: nil,
      metadata: %{}
    })
    |> Repo.update()
  end

  @doc "Returns the absolute path to the exports directory."
  def exports_dir do
    Path.expand(export_directory())
  end

  @doc """
  Returns true if `path` is a real file under `exports_dir/0`. Used by the
  download controller to defend against directory traversal even though
  the stored path comes from our own export record.
  """
  def safe_export_path?(path) when is_binary(path) do
    base = exports_dir()
    expanded = Path.expand(path)

    String.starts_with?(expanded, base <> "/") and File.regular?(expanded)
  end

  def safe_export_path?(_), do: false

  defp export_directory do
    Path.join([Application.get_env(:hybridsocial, :upload_dir, "priv/uploads"), "exports"])
  end

  defp serialize_profile(nil), do: %{}

  defp serialize_profile(identity) do
    %{
      id: identity.id,
      handle: identity.handle,
      display_name: identity.display_name,
      bio: identity.bio,
      avatar_url: identity.avatar_url,
      header_url: identity.header_url
    }
  end

  defp collect_posts(identity_id) do
    Hybridsocial.Social.Post
    |> where([p], p.identity_id == ^identity_id and is_nil(p.deleted_at))
    |> select([p], %{id: p.id, content: p.content, inserted_at: p.inserted_at})
    |> Repo.all()
  end

  defp collect_follows(identity_id) do
    Hybridsocial.Social.Follow
    |> join(:inner, [f], i in Hybridsocial.Accounts.Identity, on: i.id == f.followee_id)
    |> where([f], f.follower_id == ^identity_id)
    |> select([f, i], %{handle: i.handle})
    |> Repo.all()
  end

  defp collect_followers(identity_id) do
    Hybridsocial.Social.Follow
    |> join(:inner, [f], i in Hybridsocial.Accounts.Identity, on: i.id == f.follower_id)
    |> where([f], f.followee_id == ^identity_id)
    |> select([f, i], %{handle: i.handle})
    |> Repo.all()
  end

  defp collect_blocks(identity_id) do
    Hybridsocial.Social.Block
    |> join(:inner, [b], i in Hybridsocial.Accounts.Identity, on: i.id == b.blocked_id)
    |> where([b], b.blocker_id == ^identity_id)
    |> select([b, i], %{handle: i.handle})
    |> Repo.all()
  end

  defp collect_mutes(identity_id) do
    Hybridsocial.Social.Mute
    |> join(:inner, [m], i in Hybridsocial.Accounts.Identity, on: i.id == m.muted_id)
    |> where([m], m.muter_id == ^identity_id)
    |> select([m, i], %{handle: i.handle})
    |> Repo.all()
  end

  defp collect_bookmarks(identity_id) do
    Hybridsocial.Social.Bookmark
    |> where([b], b.identity_id == ^identity_id)
    |> select([b], %{post_id: b.post_id, inserted_at: b.inserted_at})
    |> Repo.all()
  end

  defp collect_lists(identity_id) do
    Hybridsocial.Social.List
    |> where([l], l.identity_id == ^identity_id)
    |> select([l], %{id: l.id, name: l.name})
    |> Repo.all()
  end
end
