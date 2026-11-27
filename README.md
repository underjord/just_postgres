# JustPostgres

Run a PostgreSQL server on a Nerves device, using a stock Nerves system.

`just_postgres` builds a relocatable PostgreSQL into its `priv` directory and
gives you a child spec that runs it. You don't need a custom Nerves system
or containers. The server is cross-compiled against the target's own
glibc, OpenSSL and zlib, so it fits in a normal firmware image. A trimmed
install adds about 12 MB to the squashfs.

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
* **Firmware updates**: a firmware with a different PostgreSQL major
  version won't start against an existing cluster. You'll get a clear error
  instead of a confusing one. Minor versions are safe to update and roll
  back.

## What's in the build

* The server, `psql`, `pg_dump`, `pg_basebackup`, `pg_upgrade` and the other
  client tools
* All contrib extensions, including `pgcrypto`, `pg_stat_statements` and
  `postgres_fdw`
* OpenSSL (TLS and `pgcrypto`), zlib, and lz4 and zstd (TOAST, WAL and
  backup compression). lz4 and zstd are linked statically.

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
BSD-2-Clause and zstd under BSD-3-Clause.
