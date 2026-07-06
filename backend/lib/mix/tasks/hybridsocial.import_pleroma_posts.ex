defmodule Mix.Tasks.Hybridsocial.ImportPleromaPosts do
  @shortdoc "Import local Notes (statuses) from a retired Pleroma instance"
  @moduledoc """
  Import local posts from a retired Pleroma/Rebased instance. Run AFTER
  `mix hybridsocial.import_pleroma_users` (authors must exist).

      mix hybridsocial.import_pleroma_posts notes.jsonl

  Each line is a Pleroma `objects.data` (an AP Note). Reuses the same
  AP-Note → post mapping the inbox uses for federated content; attachments
  become remote MediaFile rows (files migrated separately). After inserting,
  it links reply threads (parent/root) and recomputes reply counts.
  Idempotent (dedup on ap_id).

  Source export (statuses are Notes referenced by local Create activities):

      SELECT o.data FROM activities a
        JOIN objects o ON o.data->>'id' = a.data->>'object'
        WHERE a.local=true AND a.data->>'type'='Create' AND o.data->>'type'='Note';
  """
  use Mix.Task

  alias Hybridsocial.Migration.PleromaImport

  @requirements ["app.start"]

  @impl Mix.Task
  def run([path]) do
    notes =
      path
      |> File.stream!()
      |> Stream.filter(&String.starts_with?(String.trim(&1), "{"))
      |> Stream.map(&Jason.decode!/1)
      |> Enum.to_list()

    Mix.shell().info("Notes: #{length(notes)}")
    author_map = PleromaImport.local_author_map()

    summary = PleromaImport.import_posts(notes, author_map)

    Mix.shell().info(
      "  imported=#{summary.ok}  skipped=#{summary.skipped}  failed=#{length(summary.failed)}"
    )

    summary.failed
    |> Enum.take(20)
    |> Enum.each(fn {id, reason} -> Mix.shell().error("  FAIL #{id}: #{reason}") end)

    Mix.shell().info("Linking reply threads…")
    %{parents_linked: n} = PleromaImport.link_post_threads()
    Mix.shell().info("  parents linked: #{n}")
  end

  def run(_), do: Mix.raise("Usage: mix hybridsocial.import_pleroma_posts <notes.jsonl>")
end
