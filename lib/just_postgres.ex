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

  ## Options

  #{JustPostgres.Options.docs()}
  """

  alias JustPostgres.Options
  alias JustPostgres.Server

  @makefile Path.expand("../Makefile", __DIR__)
  @external_resource @makefile
  @postgres_version (case Regex.run(~r/^PG_VERSION = (\S+)$/m, File.read!(@makefile)) do
                       [_, version] -> version
                     end)

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
  Return the path to the bundled PostgreSQL installation
  """
  @spec install_dir() :: Path.t()
  def install_dir(), do: Application.app_dir(:just_postgres, ["priv", "pg"])

  @doc """
  Return details about a running server

  The map includes `:data_dir`, `:socket_dir`, `:port`, `:superuser`,
  `:install_dir`, `:user` (the OS user, or `nil` when not running as root),
  `:env` (the environment for PostgreSQL programs) and `:os_pid`.
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
end
