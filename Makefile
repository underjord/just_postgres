# Builds PostgreSQL and installs a relocatable copy into
# $(MIX_APP_PATH)/priv/pg.
#
# This Makefile is normally invoked by elixir_make. In a Nerves project the
# Nerves environment exports CC, CFLAGS, LDFLAGS and friends for the target,
# so the result links against the system's own glibc, OpenSSL and zlib.
# Outside Nerves it builds for the host. Most users never run it because
# precompiled archives are downloaded instead. See the README.
#
# lz4 and zstd are built as static libraries since Nerves systems don't ship
# them. OpenSSL and zlib are linked dynamically when their headers are found.
#
# WAL-G, for backups, is built with Go as a static binary with cgo disabled,
# so it runs on any Linux regardless of libc. It's skipped when Go isn't
# installed, unless JUST_POSTGRES_WALG=yes.
#
# Variables you might want to override:
#
#   JUST_POSTGRES_DL_DIR  Where source tarballs are cached
#   JUST_POSTGRES_SSL     auto (default), yes or no
#   JUST_POSTGRES_WALG    auto (default), yes or no
#   WALG_STORAGES         WAL-G storage backends (default "s3 sh", plus fs)
#   GO                    The go command
#   JOBS                  Parallel build jobs

# Rebuild everything when this file changes, e.g. on a version bump
THIS_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))

PG_VERSION = 18.7
PG_SHA256 = 441dfae4280cae3e0425e5f876f80559fb0731c140f1aae22b3e5a54d0411bfd
PG_TARBALL = postgresql-$(PG_VERSION).tar.bz2
PG_URL = https://ftp.postgresql.org/pub/source/v$(PG_VERSION)/$(PG_TARBALL)

LZ4_VERSION = 1.10.0
LZ4_SHA256 = 537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
LZ4_TARBALL = lz4-$(LZ4_VERSION).tar.gz
LZ4_URL = https://github.com/lz4/lz4/releases/download/v$(LZ4_VERSION)/$(LZ4_TARBALL)

ZSTD_VERSION = 1.5.7
ZSTD_SHA256 = eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
ZSTD_TARBALL = zstd-$(ZSTD_VERSION).tar.gz
ZSTD_URL = https://github.com/facebook/zstd/releases/download/v$(ZSTD_VERSION)/$(ZSTD_TARBALL)

WALG_VERSION = 3.0.10
WALG_SHA256 = e7ad190500da1eb7cc7fdbe7e86543ce5b884992e99491042c5b2592caacf5fe
WALG_TARBALL = wal-g-$(WALG_VERSION).tar.gz
WALG_URL = https://github.com/wal-g/wal-g/archive/refs/tags/v$(WALG_VERSION).tar.gz

# Set by mix.exs. The marker file lets elixir_make notice version changes.
JUST_POSTGRES_VERSION ?= dev

MIX_APP_PATH ?= $(CURDIR)/_build/make
PREFIX = $(MIX_APP_PATH)/priv
PG_INSTALL_DIR = $(PREFIX)/pg
MARKER = $(PG_INSTALL_DIR)/.just_postgres-$(JUST_POSTGRES_VERSION)

ifeq ($(JUST_POSTGRES_DL_DIR),)
ifneq ($(XDG_CACHE_HOME),)
JUST_POSTGRES_DL_DIR = $(XDG_CACHE_HOME)/just_postgres
else
JUST_POSTGRES_DL_DIR = $(HOME)/.cache/just_postgres
endif
endif
DL_DIR = $(JUST_POSTGRES_DL_DIR)

# Host triple, used to name the build directory, and to decide whether this
# is a cross-compile.
CC ?= cc
TARGET_TRIPLE := $(shell $(CC) -dumpmachine)
BUILD_TRIPLE := $(shell $(or $(CC_FOR_BUILD),cc) -dumpmachine)

ifeq ($(TARGET_TRIPLE),)
$(error Could not run "$(CC) -dumpmachine". Is a C compiler installed?)
endif

BUILD = $(MIX_APP_PATH)/obj/$(TARGET_TRIPLE)
DEPS_PREFIX = $(BUILD)/deps
STAGING = $(BUILD)/staging
# The configure prefix contains "pgsql" so PostgreSQL installs into
# bin, lib and share without adding "postgresql" subdirectories. The
# installation is relocatable, so this path never appears on the device.
PG_PREFIX = /usr/local/pgsql

ifneq ($(TARGET_TRIPLE),$(BUILD_TRIPLE))
CROSS_COMPILING = yes
# configure checks these linker flags by running a test program, which it
# can't do when cross-compiling, so it assumes "no". Without
# --export-dynamic, extensions can't resolve symbols in the server and even
# initdb fails. GNU ld supports both.
CONFIGURE_CROSS_ARGS = --host=$(TARGET_TRIPLE) --build=$(BUILD_TRIPLE) \
	pgac_cv_prog_cc_LDFLAGS_EX_BE__Wl___export_dynamic=yes \
	pgac_cv_prog_cc_LDFLAGS__Wl___as_needed=yes
# The timezone compiler runs at install time, so it must run on the build
# machine. Nearly every Linux and macOS install has one.
HOST_ZIC := $(shell command -v zic 2>/dev/null || ls /usr/sbin/zic 2>/dev/null)
PG_INSTALL_ARGS = ZIC=$(HOST_ZIC)
endif

ifneq ($(findstring darwin,$(TARGET_TRIPLE)),)
TARGET_DARWIN = yes
endif

ifeq ($(STRIP),)
ifneq ($(filter %gcc,$(CC)),)
STRIP = $(patsubst %gcc,%strip,$(CC))
else
STRIP = strip
endif
endif

ifneq ($(filter %gcc,$(CC)),)
READELF ?= $(patsubst %gcc,%readelf,$(CC))
else
READELF ?= readelf
endif

JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)

SHA256SUM := $(shell command -v sha256sum 2>/dev/null || echo "shasum -a 256")

# Check whether a header is available to the (cross) compiler.
have_header = $(shell echo '\#include <$(1)>' | $(CC) $(CPPFLAGS) $(CFLAGS) -E -x c - >/dev/null 2>&1 && echo yes)

JUST_POSTGRES_SSL ?= auto
ifeq ($(JUST_POSTGRES_SSL),auto)
USE_SSL := $(call have_header,openssl/ssl.h)
else ifeq ($(JUST_POSTGRES_SSL),yes)
USE_SSL = yes
endif

USE_ZLIB := $(call have_header,zlib.h)

DEPS_CFLAGS = $(CFLAGS) -fPIC

# WAL-G. Map the target triple to GOOS/GOARCH. With cgo off, Go
# cross-compiles by itself, so the C toolchain isn't involved.
GO ?= go
WALG_STORAGES ?= s3 sh
WALG_TAGS = disable_grpc_modules grpcnotrace $(addprefix storage_,$(WALG_STORAGES))
TARGET_CPU := $(firstword $(subst -, ,$(TARGET_TRIPLE)))
GOARCH_aarch64 = arm64
GOARCH_arm64 = arm64
GOARCH_x86_64 = amd64
GOARCH_riscv64 = riscv64
GOARCH_i686 = 386
WALG_GOARCH := $(or $(GOARCH_$(TARGET_CPU)),$(if $(filter arm%,$(TARGET_CPU)),arm))
WALG_GOOS := $(if $(findstring linux,$(TARGET_TRIPLE)),linux,$(if $(findstring darwin,$(TARGET_TRIPLE)),darwin))
ifeq ($(WALG_GOARCH),arm)
WALG_GOARM := $(shell echo | $(CC) $(CFLAGS) -dM -E -x c - | sed -n 's/^\#define __ARM_ARCH \([0-9]*\)$$/\1/p')
endif
WALG_GOENV = CGO_ENABLED=0 GOOS=$(WALG_GOOS) GOARCH=$(WALG_GOARCH) $(if $(WALG_GOARM),GOARM=$(WALG_GOARM))
WALG_LDFLAGS = -s -w -X github.com/wal-g/wal-g/cmd/pg.walgVersion=v$(WALG_VERSION)

JUST_POSTGRES_WALG ?= auto
ifeq ($(JUST_POSTGRES_WALG),auto)
HAVE_GO := $(shell command -v $(GO) >/dev/null 2>&1 && echo yes)
USE_WALG := $(if $(and $(HAVE_GO),$(WALG_GOOS),$(WALG_GOARCH)),yes)
else ifeq ($(JUST_POSTGRES_WALG),yes)
USE_WALG = yes
endif

# Nerves exports TARGET_ARCH (e.g. "aarch64"), but GNU make's built-in
# compile rules append $(TARGET_ARCH) to the compiler command line. Clear it
# for the sub-makes.
SUBMAKE = $(MAKE) TARGET_ARCH=

PG_CONFIGURE_ARGS = \
	--prefix=$(PG_PREFIX) \
	$(CONFIGURE_CROSS_ARGS) \
	--disable-rpath \
	--without-readline \
	--without-icu \
	--with-lz4 \
	--with-zstd \
	$(if $(USE_SSL),--with-ssl=openssl) \
	$(if $(USE_ZLIB),,--without-zlib)

# Things in the install that aren't needed to run a server
PRUNE = include share/doc lib/pkgconfig lib/pgxs bin/ecpg lib/libecpg* lib/libpgtypes* lib/*.a

LICENSES = $(PG_INSTALL_DIR)/share/licenses

all: $(MARKER)

$(MARKER): $(BUILD)/.pg-installed $(if $(USE_WALG),$(BUILD)/.walg-built)
	@if [ -z "$(USE_SSL)" ]; then echo "just_postgres: WARNING: building without OpenSSL. TLS connections won't be available."; fi
	@if [ -z "$(USE_WALG)" ]; then echo "just_postgres: WARNING: building without WAL-G (is Go installed?). Backups won't be available."; fi
	rm -rf $(PG_INSTALL_DIR)
	mkdir -p $(PREFIX)
	cp -a $(STAGING)$(PG_PREFIX) $(PG_INSTALL_DIR)
	mkdir -p $(LICENSES)
	cp $(BUILD)/postgresql-$(PG_VERSION)/COPYRIGHT $(LICENSES)/postgresql.txt
	cp $(BUILD)/lz4/lib/LICENSE $(LICENSES)/lz4.txt
	cp $(BUILD)/zstd/LICENSE $(LICENSES)/zstd.txt
ifneq ($(USE_WALG),)
	cp $(BUILD)/wal-g $(PG_INSTALL_DIR)/bin/wal-g
	cp -R $(BUILD)/wal-g-licenses $(LICENSES)/wal-g
endif
	touch $@

$(BUILD)/.pg-installed: $(BUILD)/.pg-built
ifeq ($(CROSS_COMPILING),yes)
	@if [ -z "$(HOST_ZIC)" ]; then echo "just_postgres: zic is required on the build machine when cross-compiling"; exit 1; fi
endif
	rm -rf $(STAGING)
	$(SUBMAKE) -s -C $(BUILD)/pg install-world-bin DESTDIR=$(STAGING) $(PG_INSTALL_ARGS)
	cd $(STAGING)$(PG_PREFIX) && rm -rf $(PRUNE)
ifneq ($(TARGET_DARWIN),yes)
	find $(STAGING)$(PG_PREFIX)/bin -type f -exec $(STRIP) {} +
	find $(STAGING)$(PG_PREFIX)/lib -type f -name '*.so*' -exec $(STRIP) --strip-unneeded {} +
	@# Extensions resolve symbols in the server binary. If they aren't
	@# exported, initdb fails on the device, so catch it here instead.
	@$(READELF) --dyn-syms -W $(STAGING)$(PG_PREFIX)/bin/postgres | grep -q ' CurrentMemoryContext$$' || \
		(echo "just_postgres: bin/postgres doesn't export its symbols (missing -Wl,--export-dynamic?)"; exit 1)
endif
	touch $@

$(BUILD)/.pg-built: $(BUILD)/.pg-configured
	# PostgreSQL only builds its generated headers automatically when make
	# runs at the top level (MAKELEVEL 0), which isn't the case here.
	$(SUBMAKE) -s -C $(BUILD)/pg/src/backend generated-headers
	$(SUBMAKE) -s -C $(BUILD)/pg -j$(JOBS) world-bin
	touch $@

$(BUILD)/.pg-configured: $(BUILD)/.pg-extracted $(BUILD)/.lz4-installed $(BUILD)/.zstd-installed $(THIS_MAKEFILE)
	mkdir -p $(BUILD)/pg
	cd $(BUILD)/pg && $(BUILD)/postgresql-$(PG_VERSION)/configure --quiet $(PG_CONFIGURE_ARGS) \
		CPP="$(CC) -E" \
		CPPFLAGS="$(CPPFLAGS)" \
		LZ4_CFLAGS="-I$(DEPS_PREFIX)/include" \
		LZ4_LIBS="-L$(DEPS_PREFIX)/lib -llz4" \
		ZSTD_CFLAGS="-I$(DEPS_PREFIX)/include" \
		ZSTD_LIBS="-L$(DEPS_PREFIX)/lib -lzstd"
	touch $@

$(BUILD)/.pg-extracted: $(DL_DIR)/$(PG_TARBALL) $(THIS_MAKEFILE)
	mkdir -p $(BUILD)
	rm -rf $(BUILD)/postgresql-$(PG_VERSION) $(BUILD)/pg
	tar -xjf $< -C $(BUILD)
	touch $@

$(BUILD)/.lz4-installed: $(DL_DIR)/$(LZ4_TARBALL) $(THIS_MAKEFILE)
	rm -rf $(BUILD)/lz4
	mkdir -p $(BUILD)/lz4 $(DEPS_PREFIX)/include $(DEPS_PREFIX)/lib
	tar -xzf $< -C $(BUILD)/lz4 --strip-components=1
	$(SUBMAKE) -C $(BUILD)/lz4/lib -j$(JOBS) liblz4.a CC="$(CC)" CFLAGS="$(DEPS_CFLAGS)"
	cp $(BUILD)/lz4/lib/lz4.h $(BUILD)/lz4/lib/lz4hc.h $(BUILD)/lz4/lib/lz4frame.h $(DEPS_PREFIX)/include/
	cp $(BUILD)/lz4/lib/liblz4.a $(DEPS_PREFIX)/lib/
	touch $@

$(BUILD)/.zstd-installed: $(DL_DIR)/$(ZSTD_TARBALL) $(THIS_MAKEFILE)
	rm -rf $(BUILD)/zstd
	mkdir -p $(BUILD)/zstd $(DEPS_PREFIX)/include $(DEPS_PREFIX)/lib
	tar -xzf $< -C $(BUILD)/zstd --strip-components=1
	$(SUBMAKE) -C $(BUILD)/zstd/lib -j$(JOBS) libzstd.a CC="$(CC)" CFLAGS="$(DEPS_CFLAGS)" ZSTD_LEGACY_SUPPORT=0
	cp $(BUILD)/zstd/lib/zstd.h $(BUILD)/zstd/lib/zstd_errors.h $(BUILD)/zstd/lib/zdict.h $(DEPS_PREFIX)/include/
	cp $(BUILD)/zstd/lib/libzstd.a $(DEPS_PREFIX)/lib/
	touch $@

# Go downloads WAL-G's dependencies through the module proxy and checks them
# against WAL-G's go.sum. If the installed Go is older than WAL-G needs, it
# fetches the right toolchain the same way. The licenses of everything linked
# into the binary are collected for the install.
$(BUILD)/.walg-built: $(DL_DIR)/$(WALG_TARBALL) $(THIS_MAKEFILE)
	rm -rf $(BUILD)/wal-g-src $(BUILD)/wal-g $(BUILD)/wal-g-licenses
	mkdir -p $(BUILD)/wal-g-src $(BUILD)/wal-g-licenses
	tar -xzf $< -C $(BUILD)/wal-g-src --strip-components=1
	cd $(BUILD)/wal-g-src && $(WALG_GOENV) $(GO) build -trimpath -tags "$(WALG_TAGS)" \
		-ldflags "$(WALG_LDFLAGS)" -o $(BUILD)/wal-g ./main/pg
	cd $(BUILD)/wal-g-src && cp "$$($(GO) env GOROOT)/LICENSE" $(BUILD)/wal-g-licenses/go.txt && \
		$(WALG_GOENV) $(GO) list -deps -tags "$(WALG_TAGS)" \
			-f '{{with .Module}}{{.Path}}{{"\t"}}{{.Dir}}{{end}}' ./main/pg | sort -u | \
		while IFS="$$(printf '\t')" read -r mod dir; do \
			mkdir -p "$(BUILD)/wal-g-licenses/$$mod" && \
			find "$$dir" -maxdepth 1 -type f \( -iname 'licen[cs]e*' -o -iname 'copying*' -o -iname 'notice*' \) \
				-exec cp {} "$(BUILD)/wal-g-licenses/$$mod/" \; ; \
		done
	chmod -R u+w $(BUILD)/wal-g-licenses
	touch $@

# download(url, file, sha256)
define download
	mkdir -p $(DL_DIR)
	curl -fL --retry 3 -o $(2).tmp $(1)
	echo "$(3)  $(2).tmp" | $(SHA256SUM) -c -
	mv $(2).tmp $(2)
endef

$(DL_DIR)/$(PG_TARBALL):
	$(call download,$(PG_URL),$@,$(PG_SHA256))

$(DL_DIR)/$(LZ4_TARBALL):
	$(call download,$(LZ4_URL),$@,$(LZ4_SHA256))

$(DL_DIR)/$(ZSTD_TARBALL):
	$(call download,$(ZSTD_URL),$@,$(ZSTD_SHA256))

$(DL_DIR)/$(WALG_TARBALL):
	$(call download,$(WALG_URL),$@,$(WALG_SHA256))

info:
	@echo "PostgreSQL:     $(PG_VERSION)"
	@echo "Target:         $(TARGET_TRIPLE)"
	@echo "Build machine:  $(BUILD_TRIPLE)"
	@echo "Cross-compile:  $(or $(CROSS_COMPILING),no)"
	@echo "OpenSSL:        $(or $(USE_SSL),no)"
	@echo "zlib:           $(or $(USE_ZLIB),no)"
	@echo "WAL-G:          $(if $(USE_WALG),$(WALG_VERSION) for $(WALG_GOOS)/$(WALG_GOARCH)$(if $(WALG_GOARM),v$(WALG_GOARM)) with $(WALG_STORAGES) fs,no)"
	@echo "Install to:     $(PG_INSTALL_DIR)"
	@echo "Downloads:      $(DL_DIR)"

clean:
	rm -rf $(MIX_APP_PATH)/obj $(PG_INSTALL_DIR)

.PHONY: all clean info
