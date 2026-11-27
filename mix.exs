defmodule JustPostgres.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/underjord/just_postgres"

  def project do
    [
      app: :just_postgres,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      make_env: %{"JUST_POSTGRES_VERSION" => @version},
      make_error_message: make_error_message(),
      make_precompiler: {:port, CCPrecompiler},
      make_precompiler_url: "#{@source_url}/releases/download/v#{@version}/@{artefact_filename}",
      # elixir_make skips downloading when this file exists. Including the
      # version makes upgrades replace the previous build.
      make_precompiler_filename: "pg/.just_postgres-#{@version}",
      make_force_build: System.get_env("JUST_POSTGRES_BUILD") in ["1", "true"],
      cc_precompiler: [
        # Precompiled archives are only published for these targets. Every
        # other target (32-bit ARM, RISC-V, musl, macOS) builds from source.
        compilers: %{
          {:unix, :linux} => %{
            "x86_64-linux-gnu" => "x86_64-linux-gnu-",
            "aarch64-linux-gnu" => "aarch64-linux-gnu-"
          }
        }
      ],
      deps: deps(),
      name: "JustPostgres",
      description: "PostgreSQL server binaries and supervision for Nerves devices",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "RELEASING.md"]
    ]
  end

  def package do
    [
      name: :just_postgres,
      files: [
        "lib",
        "Makefile",
        "mix.exs",
        "checksum.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE.md"
      ],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  def aliases do
    [
      check: [
        "hex.audit",
        "compile --warnings-as-errors --force",
        "format --check-formatted",
        "credo --strict",
        "deps.unlock --check-unused",
        "spellweaver.check",
        "dialyzer"
      ],
      precommit: [
        "hex.audit",
        "compile --warnings-as-errors --force",
        "format",
        "credo --strict",
        "deps.unlock --unused",
        "spellweaver.check",
        "dialyzer",
        "test"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  def dialyzer do
    [
      plt_add_apps: [:mix],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp make_error_message do
    """
    Building PostgreSQL from source failed.

    A source build needs a C compiler, make, bison, flex, perl and curl.
    Cross-compiles also need zic on the build machine. OpenSSL and zlib
    headers are used when the compiler can find them. WAL-G, for backups,
    is built when Go is installed.

    Precompiled archives exist for aarch64-linux-gnu and x86_64-linux-gnu.
    If you're on one of those, check that checksum.exs lists them.
    """
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_make, "~> 0.10.1", runtime: false},
      {:cc_precompiler, "~> 0.1.11", runtime: false},
      {:muontrap, "~> 1.6 or ~> 2.0"},
      {:nimble_options, "~> 1.1"},
      {:postgrex, "~> 0.23.0", only: :test},
      {:nstandard, "~> 0.5", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:spellweaver, "~> 0.1.8", only: [:dev, :test], runtime: false}
    ]
  end
end
