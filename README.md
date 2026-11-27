# JustPostgres

Run a PostgreSQL server on a Nerves device, using a stock Nerves system.

`just_postgres` builds a relocatable PostgreSQL into its `priv` directory and
gives you a child spec that runs it. You don't need a custom Nerves system
or containers. The server is cross-compiled against the target's own
glibc, OpenSSL and zlib, so it fits in a normal firmware image.

It can also back up continuously to S3-compatible object storage with
[WAL-G](https://github.com/wal-g/wal-g), so you can restore to any point in
time, and a replacement device restores itself on first boot.

PostgreSQL adds about 12 MB to the squashfs and WAL-G another 12 MB.

Prebuilt archives are published for `aarch64-linux-gnu` (Raspberry Pi 3, 4
and 5, and other 64-bit ARM boards) and `x86_64-linux-gnu`, so most projects
never compile PostgreSQL. Other targets build from source automatically.

The current version bundles **PostgreSQL 18.7**.

## Installation

```elixir
def deps do
  [
    {:just_postgres, "~> 0.1.0"}
  ]
end
```

## Usage

Add the server to your application's supervision tree:

```elixir
children = [
  {JustPostgres,
   data_dir: "/data/postgres/data",
   listen_addresses: "*",
   password: "change me",
   hba: [
     "local all all trust",
     "hostssl all all 10.0.0.0/8 scram-sha-256"
   ],
   settings: [
     shared_buffers: "1GB",
     wal_compression: "zstd"
   ]}
]
```

On the first start, it runs `initdb`. After that it reuses the cluster. When
the child stops, for example on `Nerves.Runtime.reboot/0`, it does a fast
shutdown so the next boot doesn't need crash recovery.

From the device itself:

```elixir
JustPostgres.wait_until_ready()
JustPostgres.cmd("psql", ["-c", "SELECT version()"])
{:ok, conn} = Postgrex.start_link(JustPostgres.connect_options())
```

See `JustPostgres` for all options.

### More than one server

Nothing in `just_postgres` is global, so you can run several clusters side
by side. Give each its own `:name`, `:data_dir`, `:port` and, with backups,
storage prefix, and pass the name to the other functions:

```elixir
children = [
  {JustPostgres, name: MyApp.MainDB, data_dir: "/data/pg/main", port: 5432},
  {JustPostgres, name: MyApp.MetricsDB, data_dir: "/data/pg/metrics", port: 5433}
]

JustPostgres.wait_until_ready(MyApp.MetricsDB)
Postgrex.start_link(JustPostgres.connect_options(MyApp.MetricsDB))
```

Each server gets its own socket directory, and its log lines include its
name.

## Nerves setup

### Add a `postgres` user

PostgreSQL refuses to run as root. Nerves runs everything as root, so
`just_postgres` runs the server as the `postgres` user, which has to exist in
`/etc/passwd`. Nerves systems don't include one, so add it with a rootfs
overlay. Note that the overlay replaces the system's files, so start with
copies of them.

Copy `/etc/passwd` and `/etc/group` from your system's rootfs (for example
`unsquashfs -cat rootfs.squashfs etc/passwd` on the system's image), put them
in `rootfs_overlay/etc/` and append:

```text
# rootfs_overlay/etc/passwd
postgres:x:70:70:PostgreSQL:/data/postgres:/bin/false

# rootfs_overlay/etc/group
postgres:x:70:
```

You can also pass `user:` to use an account that already exists.

### Storage

Put the data directory on a writable filesystem, and use a subdirectory
rather than a mount point (`initdb` refuses directories with `lost+found`).
SD cards work, but a USB SSD or NVMe drive lasts much longer. Mount it
before starting `JustPostgres`. The rpi4 kernel has f2fs but not ext4; the
rpi5 kernel has both.

### Things handled for you

* **Locales**: Nerves has no locale data, so clusters use the builtin
  `C.UTF-8` locale provider (PostgreSQL 17+). Sorting is by code point.
* **Shared memory**: `erlinit` mounts `/dev` with a 1 MiB limit, so
  `dynamic_shared_memory_type` is set to `sysv`.
* **Stale lock files**: PIDs repeat across reboots. After a power cut,
  `postmaster.pid` can name a live process that isn't PostgreSQL, which
  would block startup. Those files are removed.

## Reboots, power cuts and firmware updates

### Reboots and firmware updates

`Nerves.Runtime.reboot/0` stops the supervision tree, and so does NervesHub
after it applies an update. That gives PostgreSQL a fast shutdown: it
closes connections and writes every changed page in a shutdown checkpoint,
so the next start needs no recovery. The new firmware then starts the same
cluster.

A reboot only waits so long, though. erlinit gives the whole Erlang VM 10
seconds to exit and then kills what's left. On a Raspberry Pi, the hardware
watchdog resets the board after 15 seconds either way. The checkpoint
usually takes well under a second. After a burst of writes on a slow SD
card it can take longer than 10 seconds. If PostgreSQL is killed, nothing
committed is lost: the next start replays the WAL first, which takes
longer. To give the checkpoint more time, raise both limits:

```elixir
# config/target.exs
config :nerves, :erlinit, graceful_shutdown_timeout: 30_000
```

```text
# rel/vm.args.eex, for the hardware watchdog
-env HEART_KERNEL_TIMEOUT 40
```

Each stop is logged with how long it took, for example "PostgreSQL stopped
in 2406 ms".

### Power cuts

PostgreSQL only reports a commit as done once it's flushed to disk. After a
power cut, the next start replays WAL from the last checkpoint and comes
back with everything that was committed. That relies on the storage
actually writing data when asked to flush it, which some cheap SD cards
don't. Leave `fsync` and `full_page_writes` on. `just_postgres` writes its
own files, such as `pg_hba.conf` and the cluster id used for backups, so
that a power cut leaves either the old version or the new one, never a
partial file.

### PostgreSQL versions

Each `just_postgres` release bundles one PostgreSQL version. A firmware
update to a new minor version (18.7 to 18.8) just works, and so does
rolling it back.

A new major version can't open an older cluster. A firmware with a
different major version doesn't start PostgreSQL, logs why and leaves the
cluster alone, so rolling the firmware back brings the database back.
`just_postgres` can't upgrade a cluster to a new major version yet. To move
one, dump it with `pg_dumpall` before the update. After the update, restore
the dump into a new `data_dir`, with a new backup storage prefix, because
the old backups are for the old version.

## Backups

Add `backup:` with [WAL-G settings](https://wal-g.readthedocs.io/STORAGES/)
for the storage:

```elixir
{JustPostgres,
 data_dir: "/data/postgres/data",
 backup: [
   env: %{
     "WALG_S3_PREFIX" => "s3://my-bucket/postgres/#{Nerves.Runtime.serial_number()}",
     "AWS_ACCESS_KEY_ID" => "...",
     "AWS_SECRET_ACCESS_KEY" => "...",
     "AWS_REGION" => "eu-north-1"
   }
 ]}
```

For other S3-compatible services (Cloudflare R2, Backblaze B2, Hetzner,
MinIO, Garage) add `"AWS_ENDPOINT"` and, if the service needs it,
`"AWS_S3_FORCE_PATH_STYLE" => "true"`. `WALG_SSH_PREFIX` backs up to any
machine you can reach over SFTP.

### What happens

* **WAL archiving**: PostgreSQL hands each finished 16 MB WAL segment to
  `wal-g wal-push`, which compresses it with zstd and uploads it.
  `archive_timeout` (60 s by default) forces a segment out at least that
  often, so a dead device loses at most about a minute of commits.
* **Base backups**: one is taken as soon as a new cluster starts, then every
  `interval` (24 hours by default). After each one, backups beyond `retain`
  (7) are deleted, along with WAL that only they needed. With the defaults
  you can restore to any moment in the last week.
* **Empty data directory**: if the storage has backups, the latest is
  restored and all archived WAL replayed before the server accepts
  connections. A new device with the same configuration, or a fresh SD
  card, comes back with the data. With `restore: false` it refuses to start
  instead. Without backups, `initdb` runs as usual.
* **Unreachable storage**: WAL waits in `pg_wal` on the device and is
  uploaded once the storage is back, so nothing is lost, but the disk
  fills if it stays down for long. A data directory that needs restoring
  waits for the storage instead of creating an empty cluster.

### Watching it

```elixir
JustPostgres.backup_status()
#=> %{phase: :idle,
#     last_backup: %{name: "base_000000010000000000000042", finish_time: ~U[...], ...},
#     last_error: nil,
#     next_check_at: ~U[...],
#     archiver: %{archived_count: 811, failed_count: 0, last_archived_time: ~U[...], ...}}
```

A growing `archiver.failed_count` means WAL isn't getting out. PostgreSQL
resets these counters after a crash or power cut. Failed backups are
retried with backoff and logged. `JustPostgres.backup_now/0`
takes a backup right away, and `JustPostgres.list_backups/0` lists what's
in storage.

### Restoring

To undo a mistake, go back to a point in time:

```elixir
JustPostgres.restore(target_time: ~U[2026-11-27 09:55:00Z])
```

This downloads the newest backup from before that time next to the data
directory while the server keeps running, then stops the server, moves the
current data directory aside to `data.before-restore-<time>`, and starts
the restored copy. It replays WAL up to the target and continues on a new
timeline, which is backed up from then on. Delete the old directory when
you're happy. You need room on the device for both copies.

`restore/1` also takes `:target_lsn`, `:target_name` (from
`pg_create_restore_point/1`) and `:target_xid`. Without a target, it
replays everything that was archived.

### One storage prefix per cluster

Every device needs its own prefix, which is why the example uses the serial
number. As a safety net, the prefix has an owner marker
(`just_postgres/owner.json`). A cluster only takes base backups and deletes
old ones while the marker names it. A restored copy gets a new identity and
takes over the marker, so if the device it replaced comes back, the old one
logs an error and stops taking backups instead of competing. WAL is
uploaded with `WALG_PREVENT_WAL_OVERWRITE`, so archived WAL never gets
replaced with different contents.

### Things to know

* Backups connect over the Unix socket as the superuser, so the socket's
  `pg_hba.conf` entry must not need a password (the default is `trust`, and
  only the server's user and root can reach the socket).
* Restoring by time uses commit timestamps, which come from the system
  clock. Raspberry Pis have no RTC, so make sure the clock is set (for
  example `NervesTime.synchronized?/0`) before relying on `:target_time`.
* WAL-G settings go to PostgreSQL's environment, because PostgreSQL runs
  `archive_command`. `JustPostgres.info/1` includes them, secrets too.
* For client-side encryption, set `WALG_PGP_KEY` (an armored OpenPGP key).
  libsodium encryption isn't available because WAL-G is built without cgo.
  Server-side encryption in the bucket also works.
* WAL-G logs "Archive ... does not exist" errors while a restore replays
  WAL. That's how PostgreSQL finds the end of the archive, not a failure.

## What's in the build

* The server, `psql`, `pg_dump`, `pg_basebackup`, `pg_upgrade` and the other
  client tools
* All contrib extensions, including `pgcrypto`, `pg_stat_statements` and
  `postgres_fdw`
* OpenSSL (TLS and `pgcrypto`), zlib, and lz4 and zstd (TOAST, WAL and
  backup compression). lz4 and zstd are linked statically.
* WAL-G, built from source as a static Go binary without cgo, with the S3,
  SSH and filesystem storage backends

Not included: ICU, readline, LLVM JIT, PL/Perl, PL/Python, PL/Tcl and
`uuid-ossp` (`gen_random_uuid()` and `uuidv7()` are built in).

## Precompiled archives and source builds

When `just_postgres` compiles, `elixir_make` looks for a precompiled archive
for the current target. For Nerves, the target comes from `TARGET_ARCH`,
`TARGET_OS` and `TARGET_ABI`, so every 64-bit ARM Nerves system uses the
`aarch64-linux-gnu` archive. The archives are built on Debian bookworm, so
they need glibc 2.36 or newer. Every current Nerves system has a newer one.

Everything else compiles from source with the Nerves toolchain. This
includes 32-bit ARM, RISC-V, musl systems and macOS hosts. A source build
needs `make`, `bison`, `flex`, `perl`, `curl` and, when cross-compiling, the
host's `zic`. Source tarballs are checked against pinned SHA-256 hashes and
cached in `~/.cache/just_postgres`.

WAL-G is built when `go` is installed (any version from 1.21 on; it fetches
the toolchain WAL-G needs). Without Go, the build warns and leaves WAL-G
out, and the `:backup` option fails with an explanation. Set
`JUST_POSTGRES_WALG=yes` to make a missing Go an error instead.

To force a source build:

```sh
JUST_POSTGRES_BUILD=1 mix compile
```

or in your config:

```elixir
config :elixir_make, :force_build, just_postgres: true
```

Git and path dependencies always build from source, because the archive
checksums are only included in Hex releases.

## License

`just_postgres` is Apache-2.0. PostgreSQL is distributed under the
[PostgreSQL License](https://www.postgresql.org/about/licence/), lz4 under
BSD-2-Clause, zstd under BSD-3-Clause and WAL-G under Apache-2.0. The
install includes their license texts, and those of the Go modules compiled
into WAL-G, in `share/licenses`.
