defmodule JustPostgres.Options do
  @moduledoc false

  @schema [
    data_dir: [
      type: :string,
      required: true,
      doc: """
      Where the database cluster lives (`PGDATA`). On Nerves this should be
      on a writable filesystem, for example `"/data/postgres/data"`. Don't use
      a mount point directly: `initdb` refuses directories that contain
      `lost+found`.
      """
    ],
    port: [type: :pos_integer, default: 5432, doc: "TCP port and socket name."],
    listen_addresses: [
      type: :string,
      default: "localhost",
      doc: """
      Addresses to listen on for TCP connections. Use `"*"` to accept
      connections from other machines, `""` for Unix socket only.
      """
    ],
    socket_dir: [
      type: :string,
      doc: """
      Directory for the Unix domain socket. Defaults to
      `just_postgres/<name>` in `System.tmp_dir!/0`, so each server gets its
      own. It's created with mode 0700 so that only the server's user (and
      root) can connect.
      """
    ],
    user: [
      type: :string,
      default: "postgres",
      doc: """
      The OS user that runs PostgreSQL when the BEAM runs as root, which it
      does on Nerves. PostgreSQL refuses to run as root. The user must be in
      `/etc/passwd`. See the README for adding one with a rootfs overlay.
      Ignored when the BEAM isn't running as root.
      """
    ],
    superuser: [
      type: :string,
      default: "postgres",
      doc: "Name of the database superuser that `initdb` creates."
    ],
    password: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: """
      Password for the superuser, set by `initdb` when the cluster is created.
      Changing it later has no effect. Use `ALTER ROLE` instead.
      """
    ],
    auth_local: [
      type: :string,
      default: "trust",
      doc: """
      `initdb` authentication method for Unix socket connections. The socket
      directory is only accessible to the server's user and root.
      """
    ],
    auth_host: [
      type: :string,
      default: "scram-sha-256",
      doc: "`initdb` authentication method for TCP connections."
    ],
    hba: [
      type: {:or, [{:list, :string}, nil]},
      default: nil,
      doc: """
      Lines for `pg_hba.conf`. When set, the file is rewritten on every start.
      When `nil`, the file from `initdb` is left alone.
      """
    ],
    settings: [
      type: {:or, [:keyword_list, {:map, {:or, [:atom, :string]}, :any}]},
      default: [],
      doc: """
      PostgreSQL configuration parameters, passed as `-c name=value` on the
      command line. They override `postgresql.conf`. Booleans become
      `on`/`off`.
      """
    ],
    initdb_args: [
      type: {:list, :string},
      default: [],
      doc: """
      Extra arguments for `initdb`. They come after the defaults, so they can
      override them. The defaults use the builtin `C.UTF-8` locale since
      Nerves has no locale data.
      """
    ],
    env: [
      type: {:or, [{:list, {:tuple, [:string, :string]}}, {:map, :string, :string}]},
      default: [],
      doc: """
      Extra environment variables for PostgreSQL. Commands run by the server,
      such as `archive_command`, inherit them.
      """
    ],
    backup: [
      type: :keyword_list,
      doc: """
      Continuous backups with [WAL-G](https://wal-g.readthedocs.io/). When
      set, WAL is archived to object storage as it's written, and base backups
      are taken on a schedule, so the database can be restored to any point
      in time since the oldest backup. See the README for the details.
      """,
      keys: [
        env: [
          type: {:or, [{:list, {:tuple, [:string, :string]}}, {:map, :string, :string}]},
          required: true,
          doc: """
          WAL-G settings, such as `WALG_S3_PREFIX` and `AWS_ACCESS_KEY_ID`.
          They're passed to WAL-G as environment variables, so any setting
          from the WAL-G documentation works. A storage prefix is required.
          Use a different prefix for every cluster.
          """
        ],
        interval: [
          type: :pos_integer,
          default: :timer.hours(24),
          doc: """
          Milliseconds between base backups. Restoring replays WAL from the
          base backup before the target time, so more frequent backups mean
          faster restores.
          """
        ],
        retain: [
          type: :pos_integer,
          default: 7,
          doc: """
          Number of full base backups to keep. After each backup, older
          backups and the WAL that only they need are deleted. With daily
          backups, the default allows restores to any point in the last
          week.
          """
        ],
        archive_timeout: [
          type: :non_neg_integer,
          default: 60,
          doc: """
          PostgreSQL's `archive_timeout` in seconds. WAL is uploaded in 16 MB
          segments, and this forces a partly filled segment to be uploaded
          after this long. It's about how much recent data a dead device can
          lose. `0` turns it off.
          """
        ],
        restore: [
          type: :boolean,
          default: true,
          doc: """
          What to do when the data directory has no cluster but the storage
          has backups, for example on a replacement device or SD card. When
          `true`, the latest backup is restored and all archived WAL is
          replayed. When `false`, the server refuses to start rather than
          creating a new cluster next to the old one's backups.
          """
        ],
        retry_interval: [
          type: :pos_integer,
          default: :timer.minutes(1),
          doc: """
          Milliseconds to wait before retrying a failed backup or an
          unreachable storage. The wait doubles on each failure, up to an
          hour.
          """
        ]
      ]
    ],
    log_level: [
      type: {:in, [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug]},
      default: :info,
      doc: "Logger level for PostgreSQL's output."
    ],
    shutdown_timeout: [
      type: :pos_integer,
      default: 60_000,
      doc: """
      Milliseconds to wait for a fast shutdown before PostgreSQL is killed.
      A killed server recovers on the next start, which is safe but slower.
      """
    ],
    install_dir: [
      type: :string,
      doc: """
      Use a PostgreSQL installation other than the one bundled with
      `just_postgres`. Mostly useful for tests.
      """
    ],
    name: [
      type: :atom,
      default: JustPostgres,
      doc: """
      Name to register the server under, and its child id. To run several
      servers, give each its own name, `data_dir`, `port` and backup storage
      prefix. Pass the name to `info/1`, `cmd/3` and the other functions.
      """
    ]
  ]

  @doc false
  @spec schema() :: keyword()
  def schema(), do: @schema

  @doc false
  @spec docs() :: String.t()
  def docs(), do: NimbleOptions.docs(@schema)

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) do
    # Allow `backup: nil` so that backups can be turned off with a conditional
    opts =
      opts
      |> Keyword.reject(&match?({:backup, nil}, &1))
      |> NimbleOptions.validate!(@schema)

    opts
    |> Keyword.put_new_lazy(:socket_dir, fn ->
      # One per server. Each server makes its directory 0700 and gives it to
      # its own OS user.
      name = opts[:name] |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
      Path.join([System.tmp_dir!(), "just_postgres", name])
    end)
    |> Keyword.put_new_lazy(:install_dir, &JustPostgres.install_dir/0)
    |> Keyword.update!(:data_dir, &Path.expand/1)
    |> Keyword.update!(:env, &Enum.to_list/1)
    |> validate_backup!()
  end

  # WAL-G settings that name the storage. WAL-G can also read them from a
  # config file.
  @storage_settings ~w(WALG_S3_PREFIX WALE_S3_PREFIX WALG_SSH_PREFIX WALG_FILE_PREFIX
                       WALG_STORAGE_PREFIX WALG_CONFIG_PATH)

  defp validate_backup!(opts) do
    case opts[:backup] do
      nil ->
        opts

      backup ->
        env = Enum.to_list(backup[:env])
        check_storage_setting!(env)
        Keyword.put(opts, :backup, Keyword.put(backup, :env, env))
    end
  end

  defp check_storage_setting!(env) do
    if not Enum.any?(env, fn {k, _} -> k in @storage_settings end) do
      raise ArgumentError, """
      JustPostgres backup env needs a storage prefix: one of \
      #{Enum.join(@storage_settings, ", ")}\
      """
    end
  end
end
