# Changelog

## v0.1.0

Initial release.

* PostgreSQL 18.7, with lz4 1.10.0 and zstd 1.5.7 linked statically
* Precompiled archives for `aarch64-linux-gnu` and `x86_64-linux-gnu`
* Source builds against the Nerves toolchain and sysroot for all other targets
* `JustPostgres` child spec that runs `initdb` on first start, runs the server
  as an unprivileged user and stops it with a fast shutdown
