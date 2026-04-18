defmodule Hybridsocial.Admin.Backup do
  @moduledoc """
  Context module for managing database backups.
  Handles creation, encryption, listing, and restoration of backups.
  """

  import Ecto.Query

  alias Hybridsocial.Repo
  alias Hybridsocial.Admin.BackupJob

  require Logger

  @backup_dir "priv/backups"
  @iterations 100_000
  @key_length 32
  @iv_length 12
  @tag_length 16

  # --- Public API ---

  @doc """
  Creates a backup job record and spawns an async task to generate the backup.
  """
  def create_backup(admin_id, passphrase, type \\ "full") do
    key_hash = hash_passphrase(passphrase)

    attrs = %{
      type: type,
      status: "pending",
      encryption_key_hash: key_hash,
      initiated_by: admin_id
    }

    case %BackupJob{} |> BackupJob.changeset(attrs) |> Repo.insert() do
      {:ok, backup_job} ->
        if Application.get_env(:hybridsocial, :env) == :test do
          generate_backup(backup_job.id, passphrase)
        else
          Task.start(fn -> generate_backup(backup_job.id, passphrase) end)
        end

        {:ok, backup_job}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Generates the actual backup file: pg_dump -> compress -> encrypt -> store.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def generate_backup(backup_id, passphrase) do
    backup_job =
      case Repo.get(BackupJob, backup_id) do
        nil -> raise "Backup job #{backup_id} not found"
        job -> job
      end

    # Update status to running
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, backup_job} =
      backup_job
      |> BackupJob.changeset(%{status: "running", started_at: now})
      |> Repo.update(stale_error_field: :id)

    try do
      # Get DB connection info from Repo config
      config = Repo.config()
      db_name = Keyword.fetch!(config, :database)
      hostname = Keyword.get(config, :hostname, "localhost")
      port = Keyword.get(config, :port, 5432)
      username = Keyword.get(config, :username, "postgres")
      password = Keyword.get(config, :password, "")

      # Set PGPASSWORD environment variable
      env = [{"PGPASSWORD", to_string(password)}]

      args = [
        "-h",
        to_string(hostname),
        "-p",
        to_string(port),
        "-U",
        to_string(username),
        "-Fc",
        db_name
      ]

      # Run pg_dump (skip in test env — use dummy data)
      dump_result =
        if Application.get_env(:hybridsocial, :env) == :test do
          {"-- test backup data", 0}
        else
          System.cmd("pg_dump", args, env: env, stderr_to_stdout: true)
        end

      case dump_result do
        {dump_data, 0} ->
          # Compress with zlib
          compressed = :zlib.compress(dump_data)

          # Encrypt with AES-256-GCM
          key = derive_key(passphrase)
          iv = :crypto.strong_rand_bytes(@iv_length)

          {ciphertext, tag} =
            :crypto.crypto_one_time_aead(
              :aes_256_gcm,
              key,
              iv,
              compressed,
              <<>>,
              @tag_length,
              true
            )

          # Build encrypted payload: iv <> tag <> ciphertext
          encrypted = iv <> tag <> ciphertext

          # Write to file
          ensure_backup_dir()
          filename = "backup_#{backup_id}_#{DateTime.to_unix(DateTime.utc_now())}.enc"
          file_path = Path.join(backup_dir(), filename)
          File.write!(file_path, encrypted)

          file_size = byte_size(encrypted)

          # Update record
          backup_job
          |> BackupJob.changeset(%{
            status: "completed",
            file_path: file_path,
            file_size: file_size,
            completed_at: DateTime.utc_now()
          })
          |> Repo.update()

        {error_output, _exit_code} ->
          Logger.error("pg_dump failed: #{error_output}")

          backup_job
          |> BackupJob.changeset(%{status: "failed", completed_at: DateTime.utc_now()})
          |> Repo.update()
      end
    rescue
      e ->
        Logger.error("Backup generation failed: #{inspect(e)}")

        backup_job
        |> BackupJob.changeset(%{status: "failed", completed_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  @doc """
  Lists all backup jobs, ordered by most recent first.
  """
  def list_backups do
    BackupJob
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  @doc """
  Deletes a single backup: the encrypted file on disk (if it still
  exists) AND the backup_jobs row. Returns `{:ok, :deleted}` on
  success or `{:error, :not_found}` if the id doesn't exist.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def delete_backup(backup_id) do
    case get_backup(backup_id) do
      nil ->
        {:error, :not_found}

      %BackupJob{file_path: file_path} = job ->
        # Best-effort file removal — a missing file doesn't block
        # the DB row delete, since the whole point is to clean up.
        if is_binary(file_path), do: _ = File.rm(file_path)
        Repo.delete!(job)
        {:ok, :deleted}
    end
  end

  @doc """
  Deletes every backup older than `retention_days` days. Runs
  from the BackupExpiryWorker; also safe to call manually. Returns
  the number of backups removed.
  """
  def prune_expired(retention_days) when is_integer(retention_days) and retention_days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    BackupJob
    |> where([b], b.inserted_at < ^cutoff)
    |> Repo.all()
    |> Enum.reduce(0, fn job, acc ->
      case delete_backup(job.id) do
        {:ok, :deleted} -> acc + 1
        _ -> acc
      end
    end)
  end

  @doc """
  Gets a single backup job by ID.
  """
  def get_backup(id) do
    Repo.get(BackupJob, id)
  end

  @doc """
  Reads the raw encrypted bytes of a completed backup. Returns
  `{:ok, binary, filename}` or `{:error, reason}`. The binary is
  whatever was written to disk — iv + tag + ciphertext — and is
  only useful once the admin decrypts it with the matching
  passphrase on their own machine.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def read_backup_file(backup_id) do
    case get_backup(backup_id) do
      nil ->
        {:error, :not_found}

      %BackupJob{file_path: nil} ->
        {:error, :no_file}

      %BackupJob{file_path: file_path, id: id} ->
        case File.read(file_path) do
          {:ok, bin} -> {:ok, bin, "hybridsocial-backup-#{id}.enc"}
          {:error, reason} -> {:error, {:file_read_error, reason}}
        end
    end
  end

  @doc """
  Decrypts a backup and pipes it into `pg_restore --clean --if-exists`
  against the live Repo. DESTRUCTIVE. Drops all tables that the dump
  knows about and recreates them with the backup's data.

  Returns `{:ok, :restored}` on success, or an error tuple on any
  failure (bad passphrase, missing file, pg_restore failure, etc.).
  The caller is responsible for warning the admin and gating on a
  typed confirmation — this function does not second-guess the
  request.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def restore_backup(backup_id, passphrase) do
    case get_backup(backup_id) do
      nil ->
        {:error, :not_found}

      %BackupJob{file_path: nil} ->
        {:error, :no_file}

      %BackupJob{file_path: file_path, encryption_key_hash: stored_hash} = job ->
        with :ok <- verify_passphrase(stored_hash, passphrase),
             {:ok, encrypted} <- wrap_read(File.read(file_path)),
             {:ok, dump} <- decrypt_backup(encrypted, passphrase),
             :ok <- run_pg_restore(dump) do
          Logger.warning("Database restored from backup #{job.id}")
          {:ok, :restored}
        end
    end
  end

  defp verify_passphrase(stored_hash, passphrase) do
    if hash_passphrase(passphrase) == stored_hash, do: :ok, else: {:error, :invalid_passphrase}
  end

  defp wrap_read({:ok, bin}), do: {:ok, bin}
  defp wrap_read({:error, reason}), do: {:error, {:file_read_error, reason}}

  # Streams the decrypted pg_dump -Fc payload into pg_restore via a
  # tmp file (pg_restore insists on a seekable input). --clean drops
  # existing objects, --if-exists avoids errors on drops that would
  # fail for missing rows, --no-owner/--no-privileges sidestep owner
  # mismatches between the dump and the current Postgres user.
  defp run_pg_restore(dump) do
    config = Repo.config()
    hostname = Keyword.get(config, :hostname, "localhost")
    port = Keyword.get(config, :port, 5432)
    username = Keyword.get(config, :username, "postgres")
    password = Keyword.get(config, :password, "")
    db_name = Keyword.fetch!(config, :database)

    tmp = Path.join(System.tmp_dir!(), "restore_#{System.unique_integer([:positive])}.dump")
    File.write!(tmp, dump)

    args = [
      "-h",
      to_string(hostname),
      "-p",
      to_string(port),
      "-U",
      to_string(username),
      "-d",
      db_name,
      "--clean",
      "--if-exists",
      "--no-owner",
      "--no-privileges",
      tmp
    ]

    env = [{"PGPASSWORD", to_string(password)}]

    try do
      case System.cmd("pg_restore", args, env: env, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, exit_code} -> {:error, {:pg_restore_failed, exit_code, String.slice(output, 0, 1000)}}
      end
    after
      File.rm(tmp)
    end
  end

  # --- Key derivation and hashing ---

  @doc """
  Derives an AES-256 key from a passphrase using iterative SHA-256 hashing.
  PBKDF2-like key derivation using :crypto.hash iteratively.
  """
  def derive_key(passphrase) do
    salt = "hybridsocial_backup_salt"
    initial = :crypto.hash(:sha256, passphrase <> salt)

    Enum.reduce(1..@iterations, initial, fn _i, acc ->
      :crypto.hash(:sha256, acc <> passphrase)
    end)
    |> binary_part(0, @key_length)
  end

  @doc """
  Hashes a passphrase for storage/verification purposes (SHA256).
  """
  def hash_passphrase(passphrase) do
    :crypto.hash(:sha256, passphrase)
    |> Base.encode16(case: :lower)
  end

  # --- Private helpers ---

  defp decrypt_backup(encrypted, passphrase) do
    key = derive_key(passphrase)

    # Extract iv, tag, and ciphertext
    <<iv::binary-size(@iv_length), tag::binary-size(@tag_length), ciphertext::binary>> = encrypted

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           iv,
           ciphertext,
           <<>>,
           tag,
           false
         ) do
      :error ->
        {:error, :decryption_failed}

      decrypted ->
        # Decompress
        decompressed = :zlib.uncompress(decrypted)
        {:ok, decompressed}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_backup_dir do
    dir = backup_dir()
    File.mkdir_p!(dir)
  end

  defp backup_dir do
    Application.app_dir(:hybridsocial, @backup_dir)
  rescue
    _ -> Path.join(File.cwd!(), @backup_dir)
  end
end
