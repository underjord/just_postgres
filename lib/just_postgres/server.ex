defmodule JustPostgres.Server do
  @moduledoc false

  # Owns one PostgreSQL cluster: prepares directories, runs initdb (or
  # restores a backup) the first time, runs `postgres` under MuonTrap and
  # stops it with a fast shutdown. With backups configured, it also runs the
  # backup scheduler while PostgreSQL runs.

  use GenServer

  alias JustPostgres.Backup
  alias JustPostgres.OSUser
  alias JustPostgres.Recovery
  alias JustPostgres.WalG

  require Logger

  @max_retry_interval :timer.hours(1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      opts: opts,
      user: nil,
      env: [],
      daemon: nil,
      backup: nil,
      retries: 0
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    opts = state.opts

    with {:ok, user} <- resolve_user(opts),
         state = %{state | user: user, env: env(opts)},
         :ok <- check_install(opts, user),
         :ok <- prepare_dirs(opts, user),
         :ok <- init_or_restore(state),
         :ok <- write_hba(opts, user),
         :ok <- clear_stale_pid_file(opts),
         {:ok, daemon} <- start_postgres(opts, user, state.env) do
      state = %{state | daemon: daemon, retries: 0}
      {:noreply, start_backup(state)}
    else
      {:retry, reason} ->
        delay = retry_delay(opts, state.retries)

        Logger.warning(
          "#{log_tag(opts[:name])} #{format_error(reason)}. Retrying in #{div(delay, 1000)} s."
        )

        Process.send_after(self(), :retry_start, delay)
        {:noreply, %{state | retries: state.retries + 1}}

      {:error, reason} ->
        Logger.error("#{log_tag(opts[:name])} #{format_error(reason)}")
        {:stop, reason, state}
    end
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    {:reply, context(state), state}
  end

  def handle_call({:swap_data_dir, restored}, _from, state) do
    # Called by JustPostgres.restore/1 once a backup has been downloaded
    # next to the data directory. Keep the old cluster rather than deleting
    # it, in case the restore wasn't what was wanted.
    opts = state.opts
    data_dir = opts[:data_dir]
    state = stop_postgres(state)

    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    previous = "#{data_dir}.before-restore-#{stamp}"

    previous =
      if File.exists?(previous),
        do: "#{previous}-#{System.unique_integer([:positive])}",
        else: previous

    # Make sure the restored files are on disk before they replace the
    # current cluster, and that the renames are, before starting it
    fsync_tree!(restored)
    File.rename!(data_dir, previous)
    File.rename!(restored, data_dir)
    fsync!(Path.dirname(data_dir))

    Logger.info(
      "#{log_tag(opts[:name])} Restored cluster moved into place. The old one is in #{previous}"
    )

    with :ok <- write_hba(opts, state.user),
         :ok <- clear_stale_pid_file(opts),
         {:ok, daemon} <- start_postgres(opts, state.user, state.env) do
      {:reply, {:ok, previous}, start_backup(%{state | daemon: daemon})}
    else
      {:error, reason} ->
        Logger.error("#{log_tag(opts[:name])} #{format_error(reason)}")
        {:stop, reason, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:retry_start, state) do
    {:noreply, state, {:continue, :start}}
  end

  def handle_info({:EXIT, daemon, reason}, %{daemon: daemon} = state) do
    Logger.error("#{log_tag(state.opts[:name])} postgres exited unexpectedly: #{inspect(reason)}")
    {:stop, {:postgres_exited, reason}, %{state | daemon: nil}}
  end

  def handle_info({:EXIT, backup, reason}, %{backup: backup} = state) do
    # The scheduler doesn't hold anything that's lost by restarting it
    Logger.error(
      "#{log_tag(state.opts[:name])} Backup scheduler exited: #{inspect(reason)}. Restarting it."
    )

    Process.send_after(self(), :restart_backup, state.opts[:backup][:retry_interval])
    {:noreply, %{state | backup: nil}}
  end

  def handle_info(:restart_backup, state) do
    {:noreply, start_backup(state)}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = stop_postgres(state)
    :ok
  end

  ## Setup

  defp resolve_user(opts) do
    if OSUser.root?() do
      case OSUser.lookup(opts[:user]) do
        {:ok, user} -> {:ok, user}
        {:error, :not_found} -> {:error, {:unknown_user, opts[:user]}}
      end
    else
      {:ok, nil}
    end
  end

  # What JustPostgres.info/1 returns, and what WAL-G commands need
  defp context(state) do
    opts = state.opts

    %{
      name: opts[:name],
      data_dir: opts[:data_dir],
      socket_dir: opts[:socket_dir],
      port: opts[:port],
      superuser: opts[:superuser],
      install_dir: opts[:install_dir],
      backup: opts[:backup],
      user: state.user,
      env: state.env,
      os_pid: state.daemon && MuonTrap.Daemon.os_pid(state.daemon)
    }
  end

  @doc false
  @spec env(keyword()) :: [{String.t(), String.t()}]
  def env(opts) do
    lib_dir = Path.join(opts[:install_dir], "lib")

    # Nerves sets LANG=en_US.UTF-8 but ships no locale data
    ([
       {"LD_LIBRARY_PATH", lib_dir},
       {"DYLD_LIBRARY_PATH", lib_dir},
       {"LANG", "C"},
       {"LC_ALL", "C"},
       {"TZ", "UTC"},
       {"HOME", opts[:data_dir]},
       {"PGDATA", opts[:data_dir]},
       {"PGHOST", opts[:socket_dir]},
       {"PGPORT", Integer.to_string(opts[:port])},
       {"PGUSER", opts[:superuser]},
       {"PGDATABASE", "postgres"}
     ] ++ backup_env(opts[:backup]) ++ Enum.to_list(opts[:env]))
    |> last_wins()
  end

  # PostgreSQL passes its environment to archive_command and
  # restore_command, so WAL-G's settings go to the server itself.
  defp backup_env(nil), do: []

  defp backup_env(backup) do
    [
      {"WALG_COMPRESSION_METHOD", "zstd"},
      # Never replace archived WAL with different contents. Two clusters
      # writing to the same prefix fail instead of corrupting each other.
      {"WALG_PREVENT_WAL_OVERWRITE", "true"},
      # wal-push runs for every WAL segment. Only log problems.
      {"WALG_LOG_LEVEL", "ERROR"}
    ] ++ backup[:env]
  end

  defp last_wins(env) do
    env |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reverse()
  end

  defp check_install(opts, user) do
    postgres = bin(opts, "postgres")

    cond do
      not File.exists?(postgres) ->
        {:error, {:missing_install, opts[:install_dir]}}

      opts[:backup] && not File.exists?(bin(opts, "wal-g")) ->
        {:error, {:missing_wal_g, opts[:install_dir]}}

      user != nil and OSUser.blocking_ancestor(postgres, user) != nil ->
        {:error, {:not_searchable, OSUser.blocking_ancestor(postgres, user), user.name}}

      true ->
        :ok
    end
  end

  defp prepare_dirs(opts, user) do
    data_dir = opts[:data_dir]
    socket_dir = opts[:socket_dir]

    mkdir_p_searchable!(data_dir)
    mkdir_p_searchable!(socket_dir)

    # Don't touch the ownership of an existing cluster. A fresh, empty data
    # directory gets handed over to the server's user.
    if user != nil and File.ls!(data_dir) == [] do
      chown!(data_dir, user)
    end

    if user != nil, do: chown!(socket_dir, user)

    File.chmod!(data_dir, 0o700)
    File.chmod!(socket_dir, 0o700)

    blocked =
      if user,
        do: OSUser.blocking_ancestor(data_dir, user) || OSUser.blocking_ancestor(socket_dir, user)

    if blocked, do: {:error, {:not_searchable, blocked, user.name}}, else: :ok
  end

  # Like File.mkdir_p!/1, but directories that get created are 0755 instead of
  # following the umask. On Nerves the umask leaves new directories closed
  # to other users, which would lock the server's user out of its own data.
  defp mkdir_p_searchable!(path) do
    if not File.dir?(path) do
      mkdir_p_searchable!(Path.dirname(path))

      case File.mkdir(path) do
        :ok -> File.chmod!(path, 0o755)
        {:error, :eexist} -> :ok
        {:error, reason} -> raise File.Error, reason: reason, action: "make directory", path: path
      end
    end

    :ok
  end

  @doc false
  @spec chown!(Path.t(), OSUser.t()) :: :ok
  def chown!(path, user) do
    File.chown!(path, user.uid)
    File.chgrp!(path, user.gid)
  end

  @doc false
  # Write a file readable only by the server's user. After a crash or a
  # power cut, it has either its old contents or the new ones. A plain write
  # can leave an empty or truncated file, and a truncated cluster id would
  # stop backups.
  @spec write_private_file!(Path.t(), iodata(), OSUser.t() | nil) :: :ok
  def write_private_file!(path, contents, user) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    try do
      File.open!(tmp, [:write, :raw, :binary], fn fd ->
        File.chmod!(tmp, 0o600)
        :ok = :file.write(fd, contents)
        :ok = :file.sync(fd)
      end)

      if user, do: chown!(tmp, user)
      File.rename!(tmp, path)
      fsync!(Path.dirname(path))
    after
      _ = File.rm(tmp)
    end
  end

  @doc false
  # Flush a file or directory to disk. A new name, from creating or renaming
  # a file, is only on disk once its directory has been synced.
  @spec fsync!(Path.t()) :: :ok
  def fsync!(path) do
    modes = if File.dir?(path), do: [:read, :raw, :directory], else: [:read, :raw]

    case :file.open(path, modes) do
      {:ok, fd} ->
        try do
          case :file.sync(fd) do
            :ok -> :ok
            {:error, reason} -> raise File.Error, reason: reason, action: "sync", path: path
          end
        after
          :file.close(fd)
        end

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open for syncing", path: path
    end
  end

  @doc false
  # Flush everything in a directory tree, each directory after its contents
  @spec fsync_tree!(Path.t()) :: :ok
  def fsync_tree!(dir) do
    for entry <- File.ls!(dir) do
      path = Path.join(dir, entry)

      case File.lstat!(path) do
        %File.Stat{type: :directory} -> fsync_tree!(path)
        %File.Stat{type: :regular} -> fsync!(path)
        _ -> :ok
      end
    end

    fsync!(dir)
  end

  defp init_or_restore(state) do
    opts = state.opts
    data_dir = opts[:data_dir]

    # Left over from a restore that was interrupted. The data directory
    # itself is still intact.
    File.rm_rf!(Recovery.restoring_dir(data_dir))

    case File.read(Path.join(data_dir, "PG_VERSION")) do
      {:ok, version} ->
        with :ok <- check_major_version(String.trim(version)),
             do: ensure_cluster_id(state)

      {:error, :enoent} ->
        if opts[:backup],
          do: init_or_restore_from_storage(state),
          else: initdb(opts, state.user, state.env)

      {:error, reason} ->
        {:error, {:data_dir, data_dir, reason}}
    end
  end

  defp ensure_cluster_id(%{opts: opts} = state) do
    if opts[:backup], do: Recovery.ensure_cluster!(opts[:data_dir], state.user)
    :ok
  end

  # There's no cluster yet. If the storage has backups, they're from this
  # cluster's previous life (a dead device or SD card), so restore them
  # rather than starting over next to them.
  defp init_or_restore_from_storage(state) do
    opts = state.opts
    ctx = context(state)

    case WalG.list(ctx) do
      {:error, reason} ->
        {:retry, {:storage_unavailable, reason}}

      {:ok, []} ->
        with :ok <- initdb(opts, state.user, state.env) do
          _ = Recovery.new_cluster!(opts[:data_dir], state.user, true)
          :ok
        end

      {:ok, backups} ->
        if opts[:backup][:restore],
          do: restore_latest(ctx, backups),
          else: {:error, {:backups_exist, List.last(backups).name}}
    end
  end

  defp restore_latest(ctx, backups) do
    {:ok, backup} = Recovery.select_backup(backups, [])
    data_dir = ctx.data_dir

    Logger.info(
      "#{log_tag(ctx.name)} No cluster in #{data_dir}. Restoring backup #{backup.name}."
    )

    if File.ls!(data_dir) == [] do
      case Recovery.fetch(ctx, backup, %{}) do
        {:ok, restored} ->
          fsync_tree!(restored)
          File.rmdir!(data_dir)
          File.rename!(restored, data_dir)
          fsync!(Path.dirname(data_dir))
          :ok

        {:error, {:fetch_failed, _, _} = reason} ->
          {:retry, reason}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:data_dir_not_empty, data_dir}}
    end
  end

  defp retry_delay(opts, retries) do
    base = if opts[:backup], do: opts[:backup][:retry_interval], else: :timer.minutes(1)
    min(base * Integer.pow(2, retries), @max_retry_interval)
  end

  defp check_major_version(found) do
    expected = JustPostgres.postgres_major_version()

    if found == expected,
      do: :ok,
      else: {:error, {:major_version_mismatch, found, expected}}
  end

  defp initdb(opts, user, env) do
    Logger.info("#{log_tag(opts[:name])} Initializing a new cluster in #{opts[:data_dir]}")

    # initdb needs a password whenever a password auth method is in use. When
    # none is given, use a random one. Set a real one later via the socket.
    password = opts[:password] || Base.encode64(:crypto.strong_rand_bytes(32))
    pwfile = Path.join(opts[:socket_dir], ".initdb-pwfile-#{System.unique_integer([:positive])}")
    write_private_file!(pwfile, password, user)

    args =
      [
        "-D",
        opts[:data_dir],
        "-U",
        opts[:superuser],
        "--pwfile=#{pwfile}",
        "-E",
        "UTF8",
        "--locale=C",
        "--locale-provider=builtin",
        "--builtin-locale=C.UTF-8",
        "--auth-local=#{opts[:auth_local]}",
        "--auth-host=#{opts[:auth_host]}"
      ] ++ initdb_platform_args() ++ opts[:initdb_args]

    try do
      case MuonTrap.cmd(bin(opts, "initdb"), args, run_opts(user, env)) do
        {output, 0} ->
          Logger.debug("#{log_tag(opts[:name])} initdb: #{output}")
          :ok

        {output, status} ->
          {:error, {:initdb_failed, status, output}}
      end
    after
      File.rm(pwfile)
    end
  end

  defp write_hba(opts, user) do
    case opts[:hba] do
      nil ->
        :ok

      lines ->
        path = Path.join(opts[:data_dir], "pg_hba.conf")

        write_private_file!(
          path,
          [
            "# Managed by JustPostgres. Changes are overwritten.\n",
            Enum.intersperse(lines, "\n"),
            "\n"
          ],
          user
        )
    end
  end

  # PostgreSQL refuses to start when postmaster.pid names a live process. On
  # Nerves, PIDs repeat from boot to boot, so the pid of a server that died
  # in a power cut can belong to something else after a reboot.
  defp clear_stale_pid_file(opts) do
    pid_file = Path.join(opts[:data_dir], "postmaster.pid")

    with {:ok, contents} <- File.read(pid_file),
         {pid, _} <- Integer.parse(contents),
         {:ok, comm} <- File.read("/proc/#{pid}/comm"),
         false <- String.trim(comm) == "postgres" do
      Logger.warning(
        "#{log_tag(opts[:name])} Removing stale postmaster.pid (pid #{pid} is #{String.trim(comm)})"
      )

      _ = File.rm(pid_file)
    end

    :ok
  end

  defp start_postgres(opts, user, env) do
    data_dir = opts[:data_dir]
    :ok = Recovery.cleanup(data_dir)
    recovery = Recovery.recovery_settings(data_dir)

    if File.exists?(Path.join(data_dir, "recovery.signal")) do
      Logger.info(
        "#{log_tag(opts[:name])} Recovering from a restored backup #{inspect(recovery)}"
      )
    end

    args = ["-D", data_dir | settings_args(opts, recovery)]

    daemon_opts =
      [
        env: env,
        stderr_to_stdout: true,
        log_output: opts[:log_level],
        log_prefix: postgres_log_prefix(opts[:name]),
        delay_to_sigkill: 5_000
      ] ++ uid_opts(user)

    MuonTrap.Daemon.start_link(bin(opts, "postgres"), args, daemon_opts)
  end

  defp stop_postgres(state) do
    state = stop_backup(state)

    case state.daemon do
      nil ->
        state

      daemon ->
        opts = state.opts
        timeout_s = max(div(opts[:shutdown_timeout], 1000), 1)
        started = System.monotonic_time(:millisecond)

        {output, status} =
          MuonTrap.cmd(
            bin(opts, "pg_ctl"),
            ["stop", "-D", opts[:data_dir], "-m", "fast", "-w", "-t", "#{timeout_s}"],
            run_opts(state.user, state.env)
          )

        # On Nerves, a reboot only waits so long for the VM to exit (see the
        # README), so it's worth knowing how long this takes
        elapsed = System.monotonic_time(:millisecond) - started

        if status == 0 do
          Logger.info("#{log_tag(opts[:name])} PostgreSQL stopped in #{elapsed} ms")
        else
          Logger.warning("#{log_tag(opts[:name])} pg_ctl stop failed (#{status}): #{output}")
        end

        if Process.alive?(daemon), do: GenServer.stop(daemon, :shutdown)
        %{state | daemon: nil}
    end
  end

  defp start_backup(%{opts: opts, backup: nil} = state) do
    if opts[:backup] && state.daemon do
      {:ok, pid} = Backup.start_link(server: opts[:name], backup: opts[:backup])
      %{state | backup: pid}
    else
      state
    end
  end

  defp start_backup(state), do: state

  defp stop_backup(%{backup: nil} = state), do: state

  defp stop_backup(%{backup: pid} = state) do
    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    %{state | backup: nil}
  catch
    :exit, _ -> %{state | backup: nil}
  end

  @doc false
  @spec settings_args(keyword(), map()) :: [String.t()]
  def settings_args(opts, recovery \\ %{}) do
    defaults =
      %{
        "listen_addresses" => opts[:listen_addresses],
        "port" => opts[:port],
        "unix_socket_directories" => opts[:socket_dir]
      }
      |> Map.merge(platform_defaults())
      |> Map.merge(backup_settings(opts))

    user_settings = Map.new(opts[:settings], fn {k, v} -> {to_string(k), v} end)

    defaults
    |> Map.merge(user_settings)
    |> Map.merge(recovery)
    |> Enum.sort()
    |> Enum.flat_map(fn {k, v} -> ["-c", "#{k}=#{format_value(v)}"] end)
  end

  defp backup_settings(opts) do
    case opts[:backup] do
      nil ->
        %{}

      backup ->
        wal_g = bin(opts, "wal-g")

        %{
          "archive_mode" => "on",
          "archive_timeout" => backup[:archive_timeout],
          "archive_command" => ~s("#{wal_g}" wal-push "%p"),
          # Only used while recovering from a restored backup
          "restore_command" => ~s("#{wal_g}" wal-fetch "%f" "%p")
        }
    end
  end

  # erlinit mounts devtmpfs on /dev with a 1 MiB limit, so POSIX shared
  # memory in /dev/shm runs out quickly. System V works everywhere on Linux.
  defp platform_defaults() do
    case :os.type() do
      {:unix, :linux} -> %{"dynamic_shared_memory_type" => "sysv"}
      _ -> %{}
    end
  end

  # Same reason as above, but written to postgresql.conf
  defp initdb_platform_args() do
    Enum.flat_map(platform_defaults(), fn {k, v} -> ["-c", "#{k}=#{v}"] end)
  end

  defp format_value(true), do: "on"
  defp format_value(false), do: "off"
  defp format_value(v), do: to_string(v)

  defp bin(opts, program), do: Path.join([opts[:install_dir], "bin", program])

  @doc false
  @spec run_opts(OSUser.t() | nil, [{String.t(), String.t()}]) :: keyword()
  def run_opts(user, env), do: [env: env, stderr_to_stdout: true] ++ uid_opts(user)

  # Pass the name so that MuonTrap calls initgroups() and drops root's
  # supplementary groups, and the gid since it isn't derived from the name.
  defp uid_opts(nil), do: []
  defp uid_opts(user), do: [uid: user.name, gid: user.gid]

  ## Errors

  @doc false
  @spec log_tag(atom()) :: String.t()
  def log_tag(JustPostgres), do: "[JustPostgres]"
  def log_tag(name), do: "[JustPostgres #{inspect(name)}]"

  # Tell instances apart when there's more than one
  defp postgres_log_prefix(JustPostgres), do: "postgres: "
  defp postgres_log_prefix(name), do: "postgres #{inspect(name)}: "

  @doc false
  @spec format_error(term()) :: String.t()
  def format_error({:unknown_user, name}) do
    """
    PostgreSQL refuses to run as root, so it runs as the #{inspect(name)} user, \
    but there's no such user in /etc/passwd.

    On Nerves, add one with a rootfs overlay: copy the system's /etc/passwd and \
    /etc/group to rootfs_overlay/etc/ in your project and append

        passwd: postgres:x:70:70:PostgreSQL:/data/postgres:/bin/false
        group:  postgres:x:70:

    or pass `user:` with an account that exists.\
    """
  end

  def format_error({:not_searchable, dir, name}) do
    "#{dir} isn't searchable by the #{inspect(name)} user. PostgreSQL can't reach its files."
  end

  def format_error({:missing_install, dir}) do
    "No PostgreSQL installation found in #{dir}. Did just_postgres compile?"
  end

  def format_error({:missing_wal_g, dir}) do
    """
    Backups are configured, but there's no WAL-G in #{dir}/bin. just_postgres \
    was built without it, probably because Go wasn't installed. Install Go and \
    rebuild with JUST_POSTGRES_WALG=yes, or use a precompiled archive.\
    """
  end

  def format_error({:major_version_mismatch, found, expected}) do
    """
    The data directory is for PostgreSQL #{found}, but this firmware has \
    PostgreSQL #{expected}. Major versions need a dump and restore or \
    pg_upgrade. Refusing to start.\
    """
  end

  def format_error({:initdb_failed, status, output}) do
    "initdb failed with status #{status}:\n#{output}"
  end

  def format_error({:data_dir, dir, reason}) do
    "Can't read #{dir}: #{:file.format_error(reason)}"
  end

  def format_error({:data_dir_not_empty, dir}) do
    "#{dir} has files in it but no cluster. Refusing to restore a backup over them."
  end

  def format_error({:storage_unavailable, reason}) do
    "Can't list backups, so can't tell whether to restore or create a cluster: " <>
      format_error(reason)
  end

  def format_error({:backups_exist, name}) do
    """
    There's no cluster in the data directory, but the backup storage has \
    backups (the latest is #{name}). Refusing to create a new cluster next to \
    them. Set `restore: true` to restore them, or use an empty storage prefix.\
    """
  end

  def format_error({:fetch_failed, name, reason}) do
    "Downloading backup #{name} failed: #{format_error(reason)}"
  end

  def format_error({:wal_g, status, output}) do
    "WAL-G exited with status #{status}: #{String.trim(output)}"
  end

  def format_error(:timeout), do: "WAL-G timed out"

  def format_error({:not_owner, owner}) do
    """
    The backup storage belongs to another cluster (#{owner["hostname"]}, since \
    #{owner["claimed_at"]}), probably a device that was restored from this \
    one's backups. Not taking backups or deleting old ones. If this device \
    should take over again, restore it from the storage with \
    JustPostgres.restore/1. Otherwise give it its own storage prefix.\
    """
  end

  def format_error({:foreign_backups, name, system_identifier}) do
    """
    The backup storage has backups of a different cluster (#{name}, system \
    identifier #{system_identifier}). Use a separate storage prefix for each \
    cluster.\
    """
  end

  def format_error(:no_backups), do: "There are no backups in storage"

  def format_error({:no_backup_before, target}) do
    "There's no backup from before #{inspect(target)}. The oldest one has to come first."
  end

  def format_error({:unknown_backup, name}), do: "There's no backup named #{inspect(name)}"

  def format_error({:crashed, reason}), do: "crashed: #{inspect(reason)}"

  def format_error({:not_enough_space, dir, needed, available}) do
    mb = fn bytes -> "#{div(bytes, 1024 * 1024)} MB" end

    """
    Not enough space in #{dir} to restore: the backup needs about \
    #{mb.(needed)} with room for WAL, and #{mb.(available)} is free.\
    """
  end

  def format_error({:invalid_target, output}),
    do: "PostgreSQL rejected the recovery target: #{output}"

  def format_error(other), do: inspect(other)
end
