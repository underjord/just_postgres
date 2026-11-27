defmodule JustPostgres.BackupTest do
  use ExUnit.Case, async: false

  import JustPostgres.TestHelper

  alias JustPostgres.Recovery
  alias JustPostgres.Server

  @moduletag timeout: 300_000

  setup do
    dir = tmp_dir!("backup")
    store = dir |> Path.join("store") |> tap(&File.mkdir_p!/1) |> give_to_server_user!()
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, store: store}
  end

  defp backup_opts(store, extra \\ []) do
    Keyword.merge([env: %{"WALG_FILE_PREFIX" => store}, retry_interval: 1_000], extra)
  end

  defp psql!(sql, server \\ JustPostgres) do
    {output, 0} =
      JustPostgres.cmd("psql", ["-XAtq", "-v", "ON_ERROR_STOP=1", "-c", sql], server: server)

    String.trim(output)
  end

  defp wait_for_first_backup(server \\ JustPostgres) do
    wait_for(fn ->
      case JustPostgres.backup_status(server) do
        %{phase: :idle, last_backup: %{} = backup} -> backup
        _ -> nil
      end
    end)
  end

  defp wait_until_primary() do
    :ok = JustPostgres.wait_until_ready()
    wait_for(fn -> psql!("SELECT pg_is_in_recovery()") == "f" end)
  end

  # Switch to a new WAL segment and wait until the one with everything so
  # far has been archived
  defp archive_now!() do
    segment = psql!("SELECT pg_walfile_name(pg_current_wal_lsn())")
    psql!("SELECT pg_switch_wal()")

    wait_for(fn ->
      psql!("SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver") >= segment
    end)
  end

  defp server_time!() do
    {:ok, json} = JSON.decode(psql!("SELECT to_json(clock_timestamp())"))
    {:ok, time, _} = DateTime.from_iso8601(json)
    time
  end

  test "archives WAL and takes a base backup of a new cluster", %{dir: dir, store: store} do
    opts = server_opts(dir, backup: backup_opts(store))
    start_supervised!({JustPostgres, opts})
    :ok = JustPostgres.wait_until_ready()

    backup = wait_for_first_backup()
    assert backup.timeline == 1
    assert {:ok, [%{name: name}]} = JustPostgres.list_backups()
    assert name == backup.name

    assert psql!("SHOW archive_mode") == "on"
    psql!("CREATE TABLE things (name text)")
    archive_now!()

    status = JustPostgres.backup_status()
    assert status.archiver.failed_count == 0
    assert %DateTime{} = status.archiver.last_archived_time
    assert %DateTime{} = status.archiver.stats_reset

    # The storage is marked as this cluster's
    {:ok, cluster} = Recovery.read_cluster(opts[:data_dir])
    owner = store |> Path.join("just_postgres/owner.json") |> File.read!() |> JSON.decode!()
    assert owner["cluster_id"] == cluster["cluster_id"]
    assert cluster["claim"] == false

    # Asking for one takes another
    assert {:ok, second} = JustPostgres.backup_now()
    assert second.name != backup.name
    assert {:ok, [_, _]} = JustPostgres.list_backups()
  end

  test "runs several servers side by side", %{dir: dir} do
    servers =
      for name <- [:jp_side_a, :jp_side_b] do
        store =
          dir |> Path.join("store_#{name}") |> tap(&File.mkdir_p!/1) |> give_to_server_user!()

        opts =
          dir
          |> Path.join(Atom.to_string(name))
          |> server_opts(name: name, password: "pw-#{name}", backup: backup_opts(store))
          # Use the default socket directory, which is per server
          |> Keyword.delete(:socket_dir)

        {name, opts, store}
      end

    # Both start at once, so their initdb runs at the same time
    for {_name, opts, _store} <- servers, do: start_supervised!({JustPostgres, opts})

    for {name, opts, store} <- servers do
      :ok = JustPostgres.wait_until_ready(name)
      assert JustPostgres.info(name).socket_dir =~ ~r"/just_postgres/#{name}$"

      # Each got its own superuser password
      tcp = ["-h", "localhost", "-p", "#{opts[:port]}", "-w", "-tAc", "SELECT 1"]

      assert {_, 0} =
               JustPostgres.cmd("psql", tcp, server: name, env: [{"PGPASSWORD", "pw-#{name}"}])

      assert {_, 2} = JustPostgres.cmd("psql", tcp, server: name, env: [{"PGPASSWORD", "wrong"}])

      psql!("CREATE TABLE #{name} (id int)", name)

      # ...and backs up to its own storage
      backup = wait_for_first_backup(name)
      assert {:ok, [^backup]} = JustPostgres.list_backups(name)
      {:ok, cluster} = Recovery.read_cluster(opts[:data_dir])
      owner = store |> Path.join("just_postgres/owner.json") |> File.read!() |> JSON.decode!()
      assert owner["cluster_id"] == cluster["cluster_id"]
    end

    assert psql!("SELECT count(*) FROM pg_tables WHERE tablename LIKE 'jp_side_%'", :jp_side_a) ==
             "1"

    # Stopping one leaves the other alone
    stop_supervised!(:jp_side_a)
    refute JustPostgres.ready?(:jp_side_a)
    assert JustPostgres.ready?(:jp_side_b)
    assert {:ok, _} = JustPostgres.backup_now(:jp_side_b)
  end

  test "servers can share a socket directory", %{dir: dir} do
    shared = Path.join(dir, "shared_run")

    servers =
      for name <- [:jp_shared_a, :jp_shared_b] do
        opts =
          dir
          |> Path.join(Atom.to_string(name))
          |> server_opts(name: name, password: "pw-#{name}", socket_dir: shared)

        start_supervised!({JustPostgres, opts})
        {name, opts}
      end

    for {name, opts} <- servers do
      :ok = JustPostgres.wait_until_ready(name)
      tcp = ["-h", "localhost", "-p", "#{opts[:port]}", "-w", "-tAc", "SELECT 1"]

      assert {_, 0} =
               JustPostgres.cmd("psql", tcp, server: name, env: [{"PGPASSWORD", "pw-#{name}"}])
    end
  end

  test "keeps only the configured number of full backups", %{dir: dir, store: store} do
    opts = server_opts(dir, backup: backup_opts(store, retain: 2))
    start_supervised!({JustPostgres, opts})
    :ok = JustPostgres.wait_until_ready()
    wait_for_first_backup()

    for _ <- 1..3 do
      psql!("SELECT pg_switch_wal()")
      assert {:ok, _} = JustPostgres.backup_now()
    end

    assert {:ok, [_, _]} = JustPostgres.list_backups()
  end

  test "restores the latest backup into an empty data directory", %{dir: dir, store: store} do
    opts = server_opts(dir, backup: backup_opts(store))
    start_supervised!({JustPostgres, opts})
    :ok = JustPostgres.wait_until_ready()
    wait_for_first_backup()
    {:ok, old_cluster} = Recovery.read_cluster(opts[:data_dir])

    psql!("CREATE TABLE things (name text)")
    psql!("INSERT INTO things VALUES ('after the backup')")
    archive_now!()

    # A new SD card, or a new device with the same configuration
    stop_supervised!(JustPostgres)
    File.rm_rf!(opts[:data_dir])

    start_supervised!({JustPostgres, opts})
    wait_until_primary()

    assert psql!("SELECT name FROM things") == "after the backup"
    assert psql!("SELECT substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8)") == "00000002"

    # The restored cluster is a new owner, and it backs up its new timeline
    {:ok, cluster} = Recovery.read_cluster(opts[:data_dir])
    assert cluster["cluster_id"] != old_cluster["cluster_id"]

    wait_for(fn ->
      match?(%{last_backup: %{timeline: 2}, phase: :idle}, JustPostgres.backup_status())
    end)

    owner = store |> Path.join("just_postgres/owner.json") |> File.read!() |> JSON.decode!()
    assert owner["cluster_id"] == cluster["cluster_id"]
  end

  test "restores to a point in time", %{dir: dir, store: store} do
    opts = server_opts(dir, backup: backup_opts(store))
    start_supervised!({JustPostgres, opts})
    :ok = JustPostgres.wait_until_ready()
    wait_for_first_backup()

    psql!("CREATE TABLE things (id int)")
    psql!("INSERT INTO things VALUES (1)")
    target = server_time!()
    Process.sleep(10)
    psql!("INSERT INTO things VALUES (2)")
    archive_now!()

    # A target PostgreSQL won't take is caught before the server is touched
    too_long = String.duplicate("x", 100)
    assert {:error, {:invalid_target, message}} = JustPostgres.restore(target_name: too_long)
    assert message =~ "recovery_target_name"
    assert_raise NimbleOptions.ValidationError, fn -> JustPostgres.restore(target_lsn: "soon") end
    assert psql!("SELECT count(*) FROM things") == "2"

    assert {:ok, %{previous_data_dir: previous}} = JustPostgres.restore(target_time: target)
    wait_until_primary()

    assert psql!("SELECT string_agg(id::text, ',') FROM things") == "1"
    assert File.exists?(Path.join(previous, "PG_VERSION"))

    # Backups carry on, on the new timeline
    wait_for(fn ->
      match?(%{last_backup: %{timeline: 2}, phase: :idle}, JustPostgres.backup_status())
    end)

    # Without a target, the new timeline's WAL is replayed to the end
    psql!("INSERT INTO things VALUES (3)")
    archive_now!()
    assert {:ok, _} = JustPostgres.restore()
    wait_until_primary()
    assert psql!("SELECT string_agg(id::text, ',' ORDER BY id) FROM things") == "1,3"
  end

  test "refuses to create a cluster next to backups when restore is off", %{
    dir: dir,
    store: store
  } do
    opts = server_opts(dir, backup: backup_opts(store))
    start_supervised!({JustPostgres, opts})
    :ok = JustPostgres.wait_until_ready()
    wait_for_first_backup()
    stop_supervised!(JustPostgres)

    Process.flag(:trap_exit, true)
    other = Path.join(dir, "other")
    other_opts = server_opts(other, backup: backup_opts(store, restore: false))
    {:ok, pid} = JustPostgres.start_link(other_opts)
    assert_receive {:EXIT, ^pid, {:backups_exist, _}}, 30_000
  end

  test "stops backing up when another cluster owns the storage", %{dir: dir, store: store} do
    opts = server_opts(dir, backup: backup_opts(store))
    start_supervised!({JustPostgres, opts})
    :ok = JustPostgres.wait_until_ready()
    wait_for_first_backup()

    # What a replacement device restored from these backups would write
    marker = Path.join(store, "just_postgres/owner.json")
    File.write!(marker, JSON.encode!(%{"cluster_id" => "someone-else", "hostname" => "other"}))
    give_to_server_user!(marker)

    assert {:error, {:not_owner, %{"cluster_id" => "someone-else"}}} = JustPostgres.backup_now()
    assert {:ok, [_]} = JustPostgres.list_backups()
    assert %{phase: :failed} = JustPostgres.backup_status()
  end

  test "waits for unreachable storage before creating a cluster", %{dir: dir} do
    # A storage directory that doesn't exist yet stands in for a network
    # that isn't up
    store = Path.join(dir, "late_store")
    opts = server_opts(dir, backup: backup_opts(store))
    start_supervised!({JustPostgres, opts})

    Process.sleep(1_500)
    refute JustPostgres.ready?()
    refute File.exists?(Path.join(opts[:data_dir], "PG_VERSION"))

    File.mkdir_p!(store)
    give_to_server_user!(store)
    :ok = JustPostgres.wait_until_ready(JustPostgres, 30_000)
    wait_for_first_backup()
  end

  test "backup options need a storage prefix" do
    assert_raise ArgumentError, ~r/storage prefix/, fn ->
      JustPostgres.child_spec(data_dir: "/tmp/x", backup: [env: %{"AWS_REGION" => "x"}])
    end

    # nil turns backups off
    spec = JustPostgres.child_spec(data_dir: "/tmp/x", backup: nil)
    assert spec.id == JustPostgres
  end

  test "settings_args/2 turns on archiving" do
    opts = [
      listen_addresses: "",
      port: 5432,
      socket_dir: "/run/pg",
      install_dir: "/pg",
      settings: [archive_timeout: 300],
      backup: [archive_timeout: 60]
    ]

    args = Server.settings_args(opts, %{"recovery_target_time" => "2026-01-01T00:00:00Z"})

    assert "archive_mode=on" in args
    assert ~s(archive_command="/pg/bin/wal-g" wal-push "%p") in args
    assert ~s(restore_command="/pg/bin/wal-g" wal-fetch "%f" "%p") in args
    # User settings win over the defaults
    assert "archive_timeout=300" in args
    assert "recovery_target_time=2026-01-01T00:00:00Z" in args
  end

  describe "Recovery" do
    defp backup(name, finish, lsn) do
      %{name: name, finish_time: finish, finish_lsn: lsn}
    end

    test "select_backup/2 picks the newest backup before the target" do
      backups = [
        backup("a", ~U[2026-01-01 00:00:00Z], 100),
        backup("b", ~U[2026-01-02 00:00:00Z], 200),
        backup("c", ~U[2026-01-03 00:00:00Z], 300)
      ]

      assert {:ok, %{name: "c"}} = Recovery.select_backup(backups, [])

      assert {:ok, %{name: "b"}} =
               Recovery.select_backup(backups, target_time: ~U[2026-01-02 12:00:00Z])

      assert {:ok, %{name: "a"}} = Recovery.select_backup(backups, target_lsn: "0/96")
      assert {:ok, %{name: "a"}} = Recovery.select_backup(backups, backup: "a")

      assert {:error, {:no_backup_before, _}} =
               Recovery.select_backup(backups, target_time: ~U[2025-01-01 00:00:00Z])

      assert {:error, {:unknown_backup, "x"}} = Recovery.select_backup(backups, backup: "x")
      assert {:error, :no_backups} = Recovery.select_backup([], [])
    end

    test "target_settings/1" do
      assert Recovery.target_settings([]) == %{}

      assert Recovery.target_settings(target_time: ~U[2026-01-01 10:00:00Z], inclusive: false) ==
               %{
                 "recovery_target_time" => "2026-01-01 10:00:00+00",
                 "recovery_target_inclusive" => "off",
                 "recovery_target_action" => "promote"
               }

      assert %{"recovery_target_name" => "before-migration"} =
               Recovery.target_settings(target_name: "before-migration")
    end

    test "check_space/2 refuses backups that don't fit" do
      dir = System.tmp_dir!()
      assert :ok = Recovery.check_space(dir, %{uncompressed_size: 1024})

      assert {:error, {:not_enough_space, ^dir, _needed, _available}} =
               Recovery.check_space(dir, %{uncompressed_size: 1024 ** 6})
    end

    test "parse_lsn/1" do
      assert Recovery.parse_lsn("0/3002EC0") == 0x3002EC0
      assert Recovery.parse_lsn("1/0") == 0x100000000
    end
  end
end
