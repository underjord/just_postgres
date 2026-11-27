defmodule JustPostgres.TestHelper do
  @moduledoc false

  # When the tests run as root (CI containers, Nerves-like setups), the server
  # runs as `nobody`. That user can't reach the build directory under a
  # private home directory, so copy the installation somewhere it can.
  def install_dir() do
    if JustPostgres.OSUser.root?() do
      dir = Path.join(System.tmp_dir!(), "just_postgres_test_install")

      if not File.exists?(Path.join(dir, "bin/postgres")) do
        File.rm_rf!(dir)
        File.cp_r!(JustPostgres.install_dir(), dir)
        File.chmod!(dir, 0o755)
      end

      dir
    else
      JustPostgres.install_dir()
    end
  end

  def user(), do: if(JustPostgres.OSUser.root?(), do: "nobody", else: "postgres")

  def tmp_dir!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "just_postgres_test_#{name}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o755)
    dir
  end

  def server_opts(dir, extra \\ []) do
    [
      data_dir: Path.join(dir, "data"),
      socket_dir: Path.join(dir, "run"),
      port: 20_000 + rem(System.unique_integer([:positive]), 10_000),
      user: user(),
      install_dir: install_dir(),
      log_level: :debug
    ]
    |> Keyword.merge(extra)
  end
end

ExUnit.start()
