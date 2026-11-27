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
      Directory for the Unix domain socket. Defaults to a `just_postgres`
      directory in `System.tmp_dir!/0`. It's created with mode 0700 so that
      only the server's user (and root) can connect.
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
      type: {:list, {:tuple, [:string, :string]}},
      default: [],
      doc: """
      Extra environment variables for PostgreSQL. Commands run by the server,
      such as `archive_command`, inherit them.
      """
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
    name: [type: :atom, default: JustPostgres, doc: "Name to register the server under."]
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
    opts = NimbleOptions.validate!(opts, @schema)

    opts
    |> Keyword.put_new_lazy(:socket_dir, fn ->
      Path.join(System.tmp_dir!(), "just_postgres")
    end)
    |> Keyword.put_new_lazy(:install_dir, &JustPostgres.install_dir/0)
    |> Keyword.update!(:data_dir, &Path.expand/1)
  end
end
