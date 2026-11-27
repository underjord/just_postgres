defmodule JustPostgres.Server do
  @moduledoc false

  # Owns one PostgreSQL cluster: prepares directories, runs initdb the first
  # time, runs `postgres` under MuonTrap and stops it with a fast shutdown.

  use GenServer

  alias JustPostgres.OSUser

  require Logger

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
      daemon: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    opts = state.opts

    with {:ok, user} <- resolve_user(opts),
         env = env(opts),
         :ok <- check_install(opts, user),
         :ok <- prepare_dirs(opts, user),
         :ok <- maybe_initdb(opts, user, env),
         :ok <- write_hba(opts, user),
         :ok <- clear_stale_pid_file(opts[:data_dir]),
         {:ok, daemon} <- start_postgres(opts, user, env) do
      {:noreply, %{state | user: user, env: env, daemon: daemon}}
    else
      {:error, reason} ->
        Logger.error("[JustPostgres] #{format_error(reason)}")
        {:stop, reason, state}
    end
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    opts = state.opts

    info = %{
      data_dir: opts[:data_dir],
      socket_dir: opts[:socket_dir],
      port: opts[:port],
      superuser: opts[:superuser],
      install_dir: opts[:install_dir],
      user: state.user,
      env: state.env,
      os_pid: state.daemon && MuonTrap.Daemon.os_pid(state.daemon)
    }

    {:reply, info, state}
  end

  @impl GenServer
  def handle_info({:EXIT, daemon, reason}, %{daemon: daemon} = state) do
    Logger.error("[JustPostgres] postgres exited unexpectedly: #{inspect(reason)}")
    {:stop, {:postgres_exited, reason}, %{state | daemon: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{daemon: daemon} = state) when is_pid(daemon) do
    opts = state.opts
    timeout_s = max(div(opts[:shutdown_timeout], 1000), 1)

    {output, status} =
      MuonTrap.cmd(
        bin(opts, "pg_ctl"),
        ["stop", "-D", opts[:data_dir], "-m", "fast", "-w", "-t", "#{timeout_s}"],
        run_opts(state.user, state.env)
      )

    if status != 0 do
      Logger.warning("[JustPostgres] pg_ctl stop failed (#{status}): #{output}")
    end

    if Process.alive?(daemon), do: GenServer.stop(daemon, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

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

  @doc false
  @spec env(keyword()) :: [{String.t(), String.t()}]
  def env(opts) do
    lib_dir = Path.join(opts[:install_dir], "lib")

    [
      {"LD_LIBRARY_PATH", lib_dir},
      {"DYLD_LIBRARY_PATH", lib_dir},
      # Nerves sets LANG=en_US.UTF-8 but ships no locale data
      {"LANG", "C"},
      {"LC_ALL", "C"},
      {"TZ", "UTC"},
      {"HOME", opts[:data_dir]},
      {"PGDATA", opts[:data_dir]},
      {"PGHOST", opts[:socket_dir]},
      {"PGPORT", Integer.to_string(opts[:port])},
      {"PGUSER", opts[:superuser]},
      {"PGDATABASE", "postgres"}
    ] ++ opts[:env]
  end

  defp check_install(opts, user) do
    postgres = bin(opts, "postgres")

    cond do
      not File.exists?(postgres) ->
        {:error, {:missing_install, opts[:install_dir]}}

      user != nil and OSUser.blocking_ancestor(postgres, user) != nil ->
        {:error, {:not_searchable, OSUser.blocking_ancestor(postgres, user), user.name}}

      true ->
        :ok
    end
  end

  defp prepare_dirs(opts, user) do
    data_dir = opts[:data_dir]
    socket_dir = opts[:socket_dir]

    File.mkdir_p!(Path.dirname(data_dir))
    File.mkdir_p!(data_dir)
    File.mkdir_p!(socket_dir)

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

  defp chown!(path, user) do
    File.chown!(path, user.uid)
    File.chgrp!(path, user.gid)
  end

  defp maybe_initdb(opts, user, env) do
    data_dir = opts[:data_dir]

    case File.read(Path.join(data_dir, "PG_VERSION")) do
      {:ok, version} ->
        check_major_version(String.trim(version))

      {:error, :enoent} ->
        initdb(opts, user, env)

      {:error, reason} ->
        {:error, {:data_dir, data_dir, reason}}
    end
  end

  defp check_major_version(found) do
    expected = JustPostgres.postgres_major_version()

    if found == expected,
      do: :ok,
      else: {:error, {:major_version_mismatch, found, expected}}
  end

  defp initdb(opts, user, env) do
    Logger.info("[JustPostgres] Initializing a new cluster in #{opts[:data_dir]}")

    # initdb needs a password whenever a password auth method is in use. When
    # none is given, use a random one. Set a real one later via the socket.
    password = opts[:password] || Base.encode64(:crypto.strong_rand_bytes(32))
    pwfile = Path.join(opts[:socket_dir], ".initdb-pwfile")
    File.write!(pwfile, password)
    File.chmod!(pwfile, 0o600)
    if user, do: chown!(pwfile, user)

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
          Logger.debug("[JustPostgres] initdb: #{output}")
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

        File.write!(path, [
          "# Managed by JustPostgres. Changes are overwritten.\n",
          Enum.intersperse(lines, "\n"),
          "\n"
        ])

        File.chmod!(path, 0o600)
        if user, do: chown!(path, user)
        :ok
    end
  end

  # PostgreSQL refuses to start when postmaster.pid names a live process. On
  # Nerves, PIDs repeat from boot to boot, so the pid of a server that died
  # in a power cut can belong to something else after a reboot.
  defp clear_stale_pid_file(data_dir) do
    pid_file = Path.join(data_dir, "postmaster.pid")

    with {:ok, contents} <- File.read(pid_file),
         {pid, _} <- Integer.parse(contents),
         {:ok, comm} <- File.read("/proc/#{pid}/comm"),
         false <- String.trim(comm) == "postgres" do
      Logger.warning(
        "[JustPostgres] Removing stale postmaster.pid (pid #{pid} is #{String.trim(comm)})"
      )

      _ = File.rm(pid_file)
    end

    :ok
  end

  defp start_postgres(opts, user, env) do
    args = ["-D", opts[:data_dir] | settings_args(opts)]

    daemon_opts =
      [
        env: env,
        stderr_to_stdout: true,
        log_output: opts[:log_level],
        log_prefix: "postgres: ",
        delay_to_sigkill: 5_000
      ] ++ uid_opts(user)

    MuonTrap.Daemon.start_link(bin(opts, "postgres"), args, daemon_opts)
  end

  @doc false
  @spec settings_args(keyword()) :: [String.t()]
  def settings_args(opts) do
    defaults =
      %{
        "listen_addresses" => opts[:listen_addresses],
        "port" => opts[:port],
        "unix_socket_directories" => opts[:socket_dir]
      }
      |> Map.merge(platform_defaults())

    user_settings = Map.new(opts[:settings], fn {k, v} -> {to_string(k), v} end)

    defaults
    |> Map.merge(user_settings)
    |> Enum.sort()
    |> Enum.flat_map(fn {k, v} -> ["-c", "#{k}=#{format_value(v)}"] end)
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

  def format_error(other), do: inspect(other)
end
