# Changelog

## v0.1.0

Initial release.

* PostgreSQL 18.7, with lz4 1.10.0 and zstd 1.5.7 linked statically
* Precompiled archives for `aarch64-linux-gnu` and `x86_64-linux-gnu`
* Source builds against the Nerves toolchain and sysroot for all other targets
* `JustPostgres` child spec that runs `initdb` on first start, runs the server
  as an unprivileged user and stops it with a fast shutdown
* WAL-G 3.0.10, built without cgo, for continuous backups to S3-compatible
  storage, SFTP or a directory
* `:backup` option: WAL archiving, scheduled base backups with retention,
  automatic restore into an empty data directory, and an owner marker that
  keeps two clusters from managing the same storage
* `JustPostgres.restore/1` for point-in-time recovery, plus `backup_now/2`,
  `backup_status/1` and `list_backups/1`
* Files that `just_postgres` writes into the data directory are replaced
  atomically and synced, so a power cut can't leave them half written
* Each server stop is logged with how long it took
* License texts for everything in the build in `share/licenses`
