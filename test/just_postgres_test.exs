defmodule JustPostgresTest do
  use ExUnit.Case, async: false

  import JustPostgres.TestHelper

  alias JustPostgres.OSUser
  alias JustPostgres.Server

  setup do
    dir = tmp_dir!("server")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "reports the bundled version" do
    assert JustPostgres.postgres_version() =~ ~r/^\d+\.\d+$/

    assert JustPostgres.postgres_major_version() ==
             hd(String.split(JustPostgres.postgres_version(), "."))
  end

  test "initializes, serves queries and keeps data across restarts", %{dir: dir} do
    opts = server_opts(dir, password: "secret", settings: [wal_compression: "zstd"])

    start_supervised!({JustPostgres, opts})
    assert :ok = JustPostgres.wait_until_ready()

    {:ok, conn} = Postgrex.start_link(JustPostgres.connect_options())
    Postgrex.query!(conn, "CREATE TABLE things (name text)", [])
    Postgrex.query!(conn, "INSERT INTO things VALUES ('kept')", [])

    assert %{rows: [["zstd"]]} = Postgrex.query!(conn, "SHOW wal_compression", [])
    assert %{rows: [["on"]]} = Postgrex.query!(conn, "SHOW data_checksums", [])
    assert %{rows: [["sysv"]]} = Postgrex.query!(conn, "SHOW dynamic_shared_memory_type", [])

    assert %{rows: [["C.UTF-8"]]} =
             Postgrex.query!(
               conn,
               "SELECT datlocale FROM pg_database WHERE datname = 'postgres'",
               []
             )

    # OpenSSL-backed extension and lz4 TOAST compression are built in
    Postgrex.query!(conn, "CREATE EXTENSION pgcrypto", [])
    Postgrex.query!(conn, "CREATE TABLE squashed (body text COMPRESSION lz4)", [])

    GenServer.stop(conn)

    assert {output, 0} = JustPostgres.cmd("psql", ["-tAc", "SELECT count(*) FROM things"])
    assert String.trim(output) == "1"

    stop_supervised!(JustPostgres)
    assert cluster_state(opts) == "shut down"

    start_supervised!({JustPostgres, opts})
    assert :ok = JustPostgres.wait_until_ready()
    assert {output, 0} = JustPostgres.cmd("psql", ["-tAc", "SELECT name FROM things"])
    assert String.trim(output) == "kept"
  end

  test "password authentication over TCP", %{dir: dir} do
    opts = server_opts(dir, password: "secret")
    start_supervised!({JustPostgres, opts})
    assert :ok = JustPostgres.wait_until_ready()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: "localhost",
        port: opts[:port],
        username: "postgres",
        password: "secret",
        database: "postgres"
      )

    assert %{rows: [[1]]} = Postgrex.query!(conn, "SELECT 1", [])
    GenServer.stop(conn)

    psql_tcp = ["-h", "localhost", "-w", "-tAc", "SELECT 1"]
    assert {output, 2} = JustPostgres.cmd("psql", psql_tcp, env: [{"PGPASSWORD", "wrong"}])
    assert output =~ "password authentication failed"
  end

  test "isn't ready when the server isn't running" do
    refute JustPostgres.ready?(:not_started)
    assert {:error, :timeout} = JustPostgres.wait_until_ready(:not_started, 200)
  end

  test "rewrites pg_hba.conf from :hba", %{dir: dir} do
    hba = ["local all all trust", "host all all 127.0.0.1/32 reject"]
    opts = server_opts(dir, hba: hba)

    start_supervised!({JustPostgres, opts})
    assert :ok = JustPostgres.wait_until_ready()

    contents = File.read!(Path.join(opts[:data_dir], "pg_hba.conf"))
    assert contents =~ "host all all 127.0.0.1/32 reject"
  end

  test "refuses a data directory from another major version", %{dir: dir} do
    opts = server_opts(dir)
    File.mkdir_p!(opts[:data_dir])
    File.write!(Path.join(opts[:data_dir], "PG_VERSION"), "9\n")

    Process.flag(:trap_exit, true)

    {:ok, pid} = JustPostgres.start_link(opts)
    assert_receive {:EXIT, ^pid, {:major_version_mismatch, "9", _}}, 5_000
  end

  test "removes a stale postmaster.pid that belongs to another process", %{dir: dir} do
    opts = server_opts(dir)
    start_supervised!({JustPostgres, opts})
    assert :ok = JustPostgres.wait_until_ready()
    stop_supervised!(JustPostgres)

    # Simulate a power cut where the old pid now belongs to the BEAM
    File.write!(
      Path.join(opts[:data_dir], "postmaster.pid"),
      "#{System.pid()}\n#{opts[:data_dir]}\n"
    )

    start_supervised!({JustPostgres, opts})
    assert :ok = JustPostgres.wait_until_ready()
  end

  describe "settings_args/1" do
    test "formats values and lets settings override defaults" do
      opts = [
        listen_addresses: "*",
        port: 5433,
        socket_dir: "/run/pg",
        settings: [fsync: true, shared_buffers: "128MB", port: 6000]
      ]

      args = Server.settings_args(opts)

      assert "fsync=on" in args
      assert "shared_buffers=128MB" in args
      assert "listen_addresses=*" in args
      assert "unix_socket_directories=/run/pg" in args
      assert "port=6000" in args
      refute "port=5433" in args
    end
  end

  describe "durable files" do
    test "write_private_file! replaces the file and leaves nothing behind", %{dir: dir} do
      path = Path.join(dir, "marker.json")
      File.write!(path, "old")

      assert :ok = Server.write_private_file!(path, ["new", " contents"], nil)

      assert File.read!(path) == "new contents"
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      assert File.ls!(dir) == ["marker.json"]
    end

    test "fsync_tree! syncs files and directories", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "a/b"))
      File.write!(Path.join(dir, "a/b/file"), "x")
      File.ln_s!("missing", Path.join(dir, "a/link"))

      assert :ok = Server.fsync_tree!(dir)
      assert_raise File.Error, fn -> Server.fsync!(Path.join(dir, "nope")) end
    end
  end

  describe "OSUser" do
    test "looks users up in a passwd file", %{dir: dir} do
      passwd = Path.join(dir, "passwd")

      File.write!(
        passwd,
        "root:x:0:0:root:/root:/bin/sh\npostgres:x:70:71:PostgreSQL:/data:/bin/false\n"
      )

      assert {:ok, %{name: "postgres", uid: 70, gid: 71}} = OSUser.lookup("postgres", passwd)
      assert {:error, :not_found} = OSUser.lookup("post", passwd)
    end

    test "finds directories a user can't search", %{dir: dir} do
      locked = Path.join(dir, "locked")
      File.mkdir_p!(Path.join(locked, "inner"))
      File.chmod!(locked, 0o700)

      user = %{name: "someone", uid: 12_345, gid: 12_345}
      assert OSUser.blocking_ancestor(Path.join([locked, "inner", "file"]), user) == locked
      assert OSUser.blocking_ancestor(Path.join(dir, "file"), user) == nil
    end
  end

  defp cluster_state(opts) do
    {output, 0} =
      System.cmd(Path.join([opts[:install_dir], "bin", "pg_controldata"]), [opts[:data_dir]],
        env: [{"LD_LIBRARY_PATH", Path.join(opts[:install_dir], "lib")}, {"LC_ALL", "C"}]
      )

    [_, state] = Regex.run(~r/Database cluster state:\s+(.+)/, output)
    String.trim(state)
  end
end
