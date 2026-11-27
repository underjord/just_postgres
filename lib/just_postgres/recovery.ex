defmodule JustPostgres.Recovery do
  @moduledoc false

  # Restoring base backups and the files JustPostgres keeps in the data
  # directory to go with them.
  #
  # `just_postgres_cluster.json` holds a random cluster id. The storage's
  # owner marker names the cluster that may write base backups and apply
  # retention there. A restored copy of a cluster gets a new id, so two
  # devices restored from the same backups can't both think they own the
  # storage. `claim` is true until the cluster has written its id to the
  # marker, which it may do even when someone else's id is there.
  #
  # `just_postgres_recovery.json` holds the recovery target of a
  # point-in-time restore. PostgreSQL only reads it while `recovery.signal`
  # exists, so it's applied again if the device reboots during recovery.

  alias JustPostgres.Server
  alias JustPostgres.WalG

  @cluster_file "just_postgres_cluster.json"
  @targets_file "just_postgres_recovery.json"

  @type cluster() :: %{required(String.t()) => term()}

  ## Cluster identity

  @spec read_cluster(Path.t()) :: {:ok, cluster()} | :error
  def read_cluster(data_dir) do
    with {:ok, contents} <- File.read(Path.join(data_dir, @cluster_file)),
         {:ok, %{"cluster_id" => _} = cluster} <- JSON.decode(contents) do
      {:ok, cluster}
    else
      _ -> :error
    end
  end

  @doc """
  Give the cluster in `dir` a new id
  """
  @spec new_cluster!(Path.t(), JustPostgres.OSUser.t() | nil, boolean()) :: cluster()
  def new_cluster!(dir, user, claim) do
    cluster = %{
      "cluster_id" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      "claim" => claim
    }

    write_cluster!(dir, user, cluster)
  end

  @doc """
  Give an existing cluster an id if it doesn't have one yet

  This happens when backups are turned on for a cluster that ran without
  them. It doesn't claim the storage, so it can't take over a prefix that
  another cluster uses.
  """
  @spec ensure_cluster!(Path.t(), JustPostgres.OSUser.t() | nil) :: cluster()
  def ensure_cluster!(data_dir, user) do
    case read_cluster(data_dir) do
      {:ok, cluster} -> cluster
      :error -> new_cluster!(data_dir, user, false)
    end
  end

  @spec write_cluster!(Path.t(), JustPostgres.OSUser.t() | nil, cluster()) :: cluster()
  def write_cluster!(dir, user, cluster) do
    Server.write_private_file!(Path.join(dir, @cluster_file), JSON.encode!(cluster), user)
    cluster
  end

  ## Restoring

  @spec restoring_dir(Path.t()) :: Path.t()
  def restoring_dir(data_dir), do: data_dir <> ".restoring"

  @doc """
  Download a base backup into a new directory and set it up for recovery

  The directory is next to the data directory, so it can be renamed into
  place. Until it is, a power cut leaves the old data directory untouched.
  """
  @spec fetch(WalG.ctx(), WalG.backup(), map()) :: {:ok, Path.t()} | {:error, term()}
  def fetch(ctx, backup, targets) do
    dir = restoring_dir(ctx.data_dir)

    with :ok <- check_version(backup),
         :ok <- check_space(Path.dirname(ctx.data_dir), backup),
         :ok <- make_restoring_dir(dir, ctx.user),
         {:fetch, :ok} <- {:fetch, WalG.fetch(ctx, dir, backup.name)},
         :ok <- check_settings(ctx, dir, targets) do
      prepare_recovery!(dir, ctx.user, targets)
      {:ok, dir}
    else
      {:fetch, {:error, reason}} ->
        File.rm_rf!(dir)
        {:error, {:fetch_failed, backup.name, reason}}

      {:error, reason} ->
        File.rm_rf!(dir)
        {:error, reason}
    end
  end

  # Running out of space halfway through is much worse than not starting:
  # the server that's running can't even write its shutdown checkpoint, and
  # the restored one can't fetch WAL. Besides the backup itself, leave room
  # for a few WAL segments during replay and for the current server.
  @space_headroom 64 * 1024 * 1024

  @doc false
  @spec check_space(Path.t(), WalG.backup()) :: :ok | {:error, term()}
  def check_space(dir, backup) do
    needed = backup.uncompressed_size + @space_headroom

    case available_space(dir) do
      {:ok, available} when available < needed ->
        {:error, {:not_enough_space, dir, needed, available}}

      _ ->
        :ok
    end
  end

  # There's no statvfs in Erlang. df is everywhere, including busybox on
  # Nerves. If it isn't, skip the check rather than refuse to restore.
  defp available_space(dir) do
    with {output, 0} <- System.cmd("df", ["-Pk", dir], stderr_to_stdout: true),
         [_header, line | _] <- String.split(output, "\n", trim: true),
         [_fs, _blocks, _used, available | _] <- String.split(line),
         {kb, ""} <- Integer.parse(available) do
      {:ok, kb * 1024}
    else
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  defp make_restoring_dir(dir, user) do
    File.rm_rf!(dir)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    if user, do: Server.chown!(dir, user)
    :ok
  end

  defp prepare_recovery!(dir, user, targets) do
    _ = new_cluster!(dir, user, true)

    # The backup may have one from an earlier restore
    targets_file = Path.join(dir, @targets_file)
    _ = File.rm(targets_file)

    if targets != %{} do
      Server.write_private_file!(targets_file, JSON.encode!(targets), user)
    end

    Server.write_private_file!(Path.join(dir, "recovery.signal"), "", user)
  end

  # A recovery target that PostgreSQL doesn't accept would stop it from
  # starting at all, so try it on the restored copy before it goes live.
  # `postgres -C` checks the settings and exits without starting a server.
  defp check_settings(_ctx, _dir, targets) when targets == %{}, do: :ok

  defp check_settings(ctx, dir, targets) do
    postgres = Path.join([ctx.install_dir, "bin", "postgres"])

    {setting, _} =
      Enum.find(targets, fn {k, _} ->
        k not in ["recovery_target_inclusive", "recovery_target_action"]
      end)

    args = [
      "-D",
      dir,
      "-C",
      setting | Enum.flat_map(targets, fn {k, v} -> ["-c", "#{k}=#{v}"] end)
    ]

    case MuonTrap.cmd(postgres, args, Server.run_opts(ctx.user, ctx.env)) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:invalid_target, String.trim(output)}}
    end
  end

  @spec check_version(WalG.backup()) :: :ok | {:error, term()}
  def check_version(backup) do
    found = Integer.to_string(div(backup.pg_version, 10_000))
    expected = JustPostgres.postgres_major_version()

    if found == expected,
      do: :ok,
      else: {:error, {:major_version_mismatch, found, expected}}
  end

  @doc """
  Settings to pass to PostgreSQL while it recovers from a restored backup
  """
  @spec recovery_settings(Path.t()) :: map()
  def recovery_settings(data_dir) do
    if File.exists?(Path.join(data_dir, "recovery.signal")) do
      with {:ok, contents} <- File.read(Path.join(data_dir, @targets_file)),
           {:ok, targets} when is_map(targets) <- JSON.decode(contents) do
        targets
      else
        _ -> %{}
      end
    else
      %{}
    end
  end

  @doc """
  Remove the recovery target after recovery has finished

  Otherwise it would be in the next base backup.
  """
  @spec cleanup(Path.t()) :: :ok
  def cleanup(data_dir) do
    if not File.exists?(Path.join(data_dir, "recovery.signal")) do
      _ = File.rm(Path.join(data_dir, @targets_file))
    end

    :ok
  end

  ## Picking a backup and a target

  @doc """
  PostgreSQL recovery settings for `JustPostgres.restore/1` options
  """
  @spec target_settings(keyword()) :: map()
  def target_settings(opts) do
    target =
      Enum.find_value(
        [
          target_time: "recovery_target_time",
          target_lsn: "recovery_target_lsn",
          target_name: "recovery_target_name",
          target_xid: "recovery_target_xid"
        ],
        fn {key, setting} ->
          case opts[key] do
            nil -> nil
            %DateTime{} = time -> {setting, format_time(time)}
            value -> {setting, to_string(value)}
          end
        end
      )

    case target do
      nil ->
        %{}

      {setting, value} ->
        %{
          setting => value,
          "recovery_target_inclusive" =>
            if(Keyword.get(opts, :inclusive, true), do: "on", else: "off"),
          # The default is to pause, which leaves a read-only server waiting
          # for someone to call pg_wal_replay_resume().
          "recovery_target_action" => "promote"
        }
    end
  end

  # PostgreSQL's own format. recovery_target_time doesn't take ISO 8601 with
  # a "T".
  defp format_time(time) do
    utc = DateTime.shift_zone!(time, "Etc/UTC")
    NaiveDateTime.to_string(DateTime.to_naive(utc)) <> "+00"
  end

  @doc """
  Pick the base backup to restore from

  For a time or LSN target, that's the newest backup that finished before
  it. Otherwise it's the newest backup, unless `:backup` names one.
  """
  @spec select_backup([WalG.backup()], keyword()) :: {:ok, WalG.backup()} | {:error, term()}
  def select_backup([], _opts), do: {:error, :no_backups}

  def select_backup(backups, opts) do
    cond do
      name = opts[:backup] ->
        case Enum.find(backups, &(&1.name == name)) do
          nil -> {:error, {:unknown_backup, name}}
          backup -> {:ok, backup}
        end

      time = opts[:target_time] ->
        backups
        |> Enum.filter(&(DateTime.compare(&1.finish_time, time) != :gt))
        |> newest({:no_backup_before, time})

      lsn = opts[:target_lsn] ->
        lsn_value = parse_lsn(lsn)

        backups
        |> Enum.filter(&(&1.finish_lsn <= lsn_value))
        |> newest({:no_backup_before, lsn})

      true ->
        newest(backups, :no_backups)
    end
  end

  defp newest([], reason), do: {:error, reason}
  defp newest(backups, _reason), do: {:ok, Enum.max_by(backups, & &1.finish_time, DateTime)}

  @doc """
  Parse an LSN like `"0/3002EC0"`
  """
  @spec parse_lsn(String.t()) :: non_neg_integer()
  def parse_lsn(lsn) do
    [hi, lo] = String.split(lsn, "/")
    Bitwise.bsl(String.to_integer(hi, 16), 32) + String.to_integer(lo, 16)
  end
end
