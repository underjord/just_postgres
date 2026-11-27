# Releasing

Precompiled archives are built by the `Precompile` workflow and attached to
a GitHub release. The Hex package carries `checksum.exs` so `elixir_make`
can verify downloads.

1. Update `@version` in `mix.exs` and add a `CHANGELOG.md` entry. If
   PostgreSQL changed, update the version in the README.

2. Commit, then tag and push:

   ```sh
   git tag v0.1.0
   git push origin main v0.1.0
   ```

3. Wait for the `Precompile` workflow. It builds each target, runs
   `scripts/smoke_test.sh` against the archive and publishes the release.

4. Generate `checksum.exs` from the published archives:

   ```sh
   mix elixir_make.checksum --all --ignore-unavailable --print
   ```

   Compare it with `checksums.txt` on the release.

5. Publish:

   ```sh
   mix hex.publish
   ```

`checksum.exs` is in `.gitignore`. If it were committed, builds from `main`
would download archives for the tagged version instead of building the
current Makefile.

## Updating PostgreSQL, lz4 or zstd

Bump the version and SHA-256 in the `Makefile`. The hashes are published
next to each tarball:

* <https://ftp.postgresql.org/pub/source/>
* <https://github.com/lz4/lz4/releases>
* <https://github.com/facebook/zstd/releases>

A new PostgreSQL major version is a breaking change for anyone with an
existing cluster, so it needs a major (or pre-1.0 minor) version bump and a
CHANGELOG entry explaining the upgrade path.

## Trying the precompile workflow

Running `Precompile` by hand from the Actions tab builds and smoke tests
the archives without creating a release. Download them from the run's
artifacts.

To build an archive locally for the current machine:

```sh
MIX_ENV=prod CC_PRECOMPILER_PRECOMPILE_ONLY_LOCAL=true mix elixir_make.precompile
scripts/smoke_test.sh ~/.cache/elixir_make/just_postgres-port-*.tar.gz
```
