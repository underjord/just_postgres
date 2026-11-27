defmodule JustPostgres do
  @moduledoc """
  Run a PostgreSQL server from your supervision tree.

  `just_postgres` bundles a relocatable PostgreSQL build in its `priv`
  directory, so a Nerves firmware image can run a database without a custom
  Nerves system. Add the server to a supervisor:

  ```elixir
  children = [
    {JustPostgres, data_dir: "/data/postgres/data", listen_addresses: "*"}
  ]
  ```

  The first start runs `initdb`. Later starts reuse the cluster. Stopping the
  child does a fast shutdown (`pg_ctl stop -m fast`), so clients are
  disconnected and the next start doesn't need crash recovery.

  ## Backups

  With the `:backup` option, WAL is archived to object storage with WAL-G
  and base backups are taken on a schedule:

  ```elixir
  {JustPostgres,
   data_dir: "/data/postgres/data",
   backup: [
     env: %{
       "WALG_S3_PREFIX" => "s3://my-bucket/postgres/device-1",
       "AWS_ACCESS_KEY_ID" => "...",
       "AWS_SECRET_ACCESS_KEY" => "...",
       "AWS_REGION" => "eu-north-1"
     }
   ]}
  ```

  If the data directory is empty when the server starts and the storage has
  backups, the latest one is restored. `restore/1` goes back to an earlier
  point in time. `backup_status/1` shows how backups and WAL archiving are
  doing.

  ## Options

  #{JustPostgres.Options.docs()}
  """

  alias JustPostgres.Backup
  alias JustPostgres.Options
  alias JustPostgres.Recovery
  alias JustPostgres.Server
  alias JustPostgres.WalG

  require Logger

  @makefile Path.expand("../Makefile", __DIR__)
  @external_resource @makefile
  @postgres_version (case Regex.run(~r/^PG_VERSION = (\S+)$/m, File.read!(@makefile)) do
                       [_, version] -> version
                     end)
  @wal_g_version (case Regex.run(~r/^WALG_VERSION = (\S+)$/m, File.read!(@makefile)) do
                    [_, version] -> version
                  end)

  @restore_schema [
    server: [type: :atom, default: JustPostgres, doc: "The server to restore."],
    target_time: [
      type: {:struct, DateTime},
      doc: "Recover up to this time. Commits after it are lost."
    ],
    target_lsn: [
      type: {:custom, __MODULE__, :validate_lsn, []},
      doc: ~s(Recover up to this WAL location, like `"0/3002EC0"`.)
    ],
    target_name: [
      type: :string,
      doc: """
      Recover up to a restore point made with `pg_create_restore_point()`.
      The backup has to be from before it, so pass `:backup` unless it's
      after the latest one.
      """
    ],
    target_xid: [
      type: :pos_integer,
      doc: "Recover up to this transaction id. Like `:target_name`, pass `:backup` too."
    ],
    inclusive: [
      type: :boolean,
      default: true,
      doc: "Whether to stop just after the target (the default) or just before it."
    ],
    backup: [
      type: :string,
      doc: """
      Name of the base backup to start from, from `list_backups/1`. By
      default, it's the newest one from before the target.
      """
    ]
  ]

  @typedoc "A server name or pid"
  @type server() :: GenServer.server()

  @doc """
  Return a child specification for the server

  See the module docs for options.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = Options.validate!(opts)

    %{
      id: opts[:name],
      start: {Server, :start_link, [opts]},
      # Leave time for pg_ctl to finish a fast shutdown
      shutdown: opts[:shutdown_timeout] + 5_000,
      type: :worker
    }
  end

  @doc """
  Start the server outside of a supervision tree

  Prefer `child_spec/1`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts |> Options.validate!() |> Server.start_link()
  end

  @doc """
  Return the bundled PostgreSQL version
  """
  @spec postgres_version() :: String.t()
  def postgres_version(), do: @postgres_version

  @doc """
  Return the bundled PostgreSQL major version

  The data directory's `PG_VERSION` file has to match this.
  """
  @spec postgres_major_version() :: String.t()
  def postgres_major_version() do
    @postgres_version |> String.split(".") |> hd()
  end

  @doc """
  Return the bundled WAL-G version

  WAL-G is only included when just_postgres was built with Go available.
  The precompiled archives always include it.
  """
  @spec wal_g_version() :: String.t()
  def wal_g_version(), do: @wal_g_version

  @doc """
  Return the path to the bundled PostgreSQL installation
  """
  @spec install_dir() :: Path.t()
  def install_dir(), do: Application.app_dir(:just_postgres, ["priv", "pg"])

  @doc """
  Return details about a running server

  The map includes `:data_dir`, `:socket_dir`, `:port`, `:superuser`,
  `:install_dir`, `:backup` (the backup options), `:user` (the OS user, or
  `nil` when not running as root), `:env` (the environment for PostgreSQL
  programs, including WAL-G settings) and `:os_pid`.
  """
  @spec info(server()) :: map()
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc """
  Return true if the server accepts connections

  Returns false while the server is starting, including while `initdb`
  runs on first boot, and when it isn't running.
  """
  @spec ready?(server()) :: boolean()
  def ready?(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> false
      _pid -> isready?(info(server))
    end
  catch
    # Still in initdb or setup, or stopped in the meantime
    :exit, _reason -> false
  end

  defp isready?(%{os_pid: nil}), do: false

  defp isready?(info) do
    pg_isready = Path.join([info.install_dir, "bin", "pg_isready"])

    {_, status} =
      System.cmd(pg_isready, ["-q", "-h", info.socket_dir, "-p", "#{info.port}"],
        env: info.env,
        stderr_to_stdout: true
      )

    status == 0
  end

  @doc """
  Wait until the server accepts connections

  Returns `:ok`, or `{:error, :timeout}` after `timeout` milliseconds. It's
  fine to call this before the server has started. The first start runs
  `initdb`, which can take a while on slow devices, so the default timeout is
  generous.
  """
  @spec wait_until_ready(server(), timeout()) :: :ok | {:error, :timeout}
  def wait_until_ready(server \\ __MODULE__, timeout \\ 120_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_ready(server, deadline)
  end

  defp do_wait_until_ready(server, deadline) do
    cond do
      ready?(server) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(100)
        do_wait_until_ready(server, deadline)
    end
  end

  @doc """
  Run a bundled PostgreSQL program, like `psql` or `pg_dump`

  The program runs with `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` and
  `PGDATA` pointing at the server, and as the server's OS user when the BEAM
  runs as root. Returns `{output, exit_status}` with stderr included in the
  output.

  Options:

  * `:server` - the server to run against. Defaults to `JustPostgres`.
  * `:env` - extra environment variables, added to the defaults

  Other options are passed to `MuonTrap.cmd/3`.

  ```elixir
  JustPostgres.cmd("psql", ["-c", "SELECT version()"])
  JustPostgres.cmd("wal-g", ["backup-list"])
  ```
  """
  @spec cmd(String.t(), [String.t()], keyword()) ::
          {Collectable.t(), non_neg_integer() | :timeout}
  def cmd(program, args, opts \\ []) do
    {server, opts} = Keyword.pop(opts, :server, __MODULE__)
    info = info(server)
    path = Path.join([info.install_dir, "bin", program])
    {extra_env, opts} = Keyword.pop(opts, :env, [])
    run_opts = Server.run_opts(info.user, info.env ++ Enum.to_list(extra_env))
    MuonTrap.cmd(path, args, Keyword.merge(run_opts, opts))
  end

  @doc """
  Return Postgrex connection options for the superuser over the Unix socket

  ```elixir
  {:ok, conn} = Postgrex.start_link(JustPostgres.connect_options())
  ```
  """
  @spec connect_options(server()) :: keyword()
  def connect_options(server \\ __MODULE__) do
    info = info(server)

    [
      socket_dir: info.socket_dir,
      port: info.port,
      username: info.superuser,
      database: "postgres"
    ]
  end

  @doc """
  Take a base backup now and wait for it to finish

  Returns the new backup, as described in `list_backups/1`. If the server is
  still starting or recovering, the backup starts once it's ready.
  """
  @spec backup_now(server(), timeout()) :: {:ok, map()} | {:error, term()}
  def backup_now(server \\ __MODULE__, timeout \\ :infinity) do
    Backup.backup_now(server, timeout)
  end

  @doc """
  Return the state of backups and WAL archiving

  * `:phase` - `:starting`, `:waiting` (for the server to be ready, or to
    finish recovering), `:checking`, `:backing_up`, `:idle`, `:failed` or
    `:paused`
  * `:last_backup` - the newest base backup in storage, as of the last check
  * `:last_error` - why the last check or backup failed, or `nil`
  * `:next_check_at` - when the next check runs. Checks take a backup when
    the newest one is older than the interval.
  * `:archiver` - PostgreSQL's `pg_stat_archiver` view. If `:failed_count`
    keeps growing, WAL isn't reaching the storage and piles up on the
    device.

  Returns `{:error, :not_running}` when backups aren't configured or the
  server isn't running.
  """
  @spec backup_status(server()) :: map() | {:error, :not_running}
  def backup_status(server \\ __MODULE__) do
    case Backup.status(server) do
      %{} = status -> Map.put(status, :archiver, archiver_stats(server))
      error -> error
    end
  end

  defp archiver_stats(server) do
    case cmd("psql", ["-XAtqc", "SELECT row_to_json(a) FROM pg_stat_archiver a"], server: server) do
      {output, 0} ->
        {:ok, stats} = JSON.decode(String.trim(output))
        Map.new(stats, &archiver_stat/1)

      _ ->
        nil
    end
  catch
    :exit, _ -> nil
  end

  defp archiver_stat({key, value}) when is_binary(value) do
    if String.ends_with?(key, "_time") or key == "stats_reset",
      do: {String.to_atom(key), parse_time(value)},
      else: {String.to_atom(key), value}
  end

  defp archiver_stat({key, value}), do: {String.to_atom(key), value}

  # PostgreSQL's JSON timestamps are ISO 8601 with a "+00:00" offset
  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> value
    end
  end

  @doc """
  List the base backups in storage, oldest first

  Each backup is a map with `:name`, `:start_time`, `:finish_time`,
  `:timeline`, `:start_lsn`, `:finish_lsn`, `:system_identifier`,
  `:pg_version`, `:uncompressed_size`, `:compressed_size` and more.
  """
  @spec list_backups(server()) :: {:ok, [map()]} | {:error, term()}
  def list_backups(server \\ __MODULE__) do
    WalG.list(info(server))
  end

  @doc """
  Restore the cluster from backups, optionally to a point in time

  The backup is downloaded next to the data directory while the server keeps
  running, so there needs to be room for a second copy. Then the server
  stops, the current data directory is moved aside (to
  `<data_dir>.before-restore-<time>`) and the restored one takes its place.
  The server starts, replays archived WAL up to the target, and then begins
  a new timeline that's backed up like before. Delete the old data
  directory once you're happy with the result.

  Without a target, everything that was archived is replayed.

  ```elixir
  JustPostgres.restore(target_time: ~U[2026-11-27 09:55:00Z])
  ```

  Returns once the restored server has started. It may still be replaying
  WAL. `wait_until_ready/2` waits until it accepts connections, and
  `backup_status/1` shows `phase: :waiting` until recovery has finished.

  ## Options

  #{NimbleOptions.docs(@restore_schema)}
  """
  @spec restore(keyword()) :: {:ok, map()} | {:error, term()}
  def restore(opts \\ []) do
    opts = NimbleOptions.validate!(opts, @restore_schema)

    if Enum.count([:target_time, :target_lsn, :target_name, :target_xid], &opts[&1]) > 1 do
      raise ArgumentError,
            "pass only one of :target_time, :target_lsn, :target_name and :target_xid"
    end

    server = opts[:server]
    info = info(server)

    if info.backup do
      # Don't take backups (or delete old ones) while restoring
      _ = Backup.pause(server)

      try do
        do_restore(server, info, opts)
      after
        _ = Backup.resume(server)
      end
    else
      {:error, :backups_not_configured}
    end
  end

  @doc false
  @spec validate_lsn(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_lsn(lsn) when is_binary(lsn) do
    if lsn =~ ~r/\A[0-9A-Fa-f]{1,8}\/[0-9A-Fa-f]{1,8}\z/,
      do: {:ok, lsn},
      else: {:error, ~s(expected an LSN like "0/3002EC0", got: #{inspect(lsn)})}
  end

  def validate_lsn(lsn), do: {:error, "expected an LSN string, got: #{inspect(lsn)}"}

  defp do_restore(server, info, opts) do
    with {:ok, backups} <- WalG.list(info),
         {:ok, backup} <- Recovery.select_backup(backups, opts),
         _ = Logger.info("[JustPostgres] Restoring backup #{backup.name}"),
         {:ok, restored} <- Recovery.fetch(info, backup, Recovery.target_settings(opts)),
         {:ok, previous} <- GenServer.call(server, {:swap_data_dir, restored}, :infinity) do
      {:ok, %{backup: backup.name, previous_data_dir: previous}}
    end
  end
end
