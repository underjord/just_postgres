defmodule JustPostgres.TestHelper do
  @moduledoc false

  # When the tests run as root (CI containers, Nerves-like setups), the server
  # runs as `nobody`. That user can't reach the build directory under a
  # private home directory, so copy the installation somewhere it can.
  def install_dir() do
    if JustPostgres.OSUser.root?() do
      dir = Path.join(System.tmp_dir!(), "just_postgres_test_install")

      if stale_copy?(JustPostgres.install_dir(), dir) do
        File.rm_rf!(dir)
        # -a keeps modification times for stale_copy?/2
        {_, 0} = System.cmd("cp", ["-a", JustPostgres.install_dir(), dir])
        File.chmod!(dir, 0o755)
      end

      dir
    else
      JustPostgres.install_dir()
    end
  end

  defp stale_copy?(source, copy) do
    Enum.any?(["bin/postgres", "bin/wal-g"], fn file ->
      case {File.stat(Path.join(source, file)), File.stat(Path.join(copy, file))} do
        {{:ok, a}, {:ok, b}} -> a.mtime != b.mtime or a.size != b.size
        {{:ok, _}, _} -> true
        _ -> false
      end
    end)
  end

  def user(), do: if(JustPostgres.OSUser.root?(), do: "nobody", else: "postgres")

  # Give a directory to the user the server runs as
  def give_to_server_user!(path) do
    if JustPostgres.OSUser.root?() do
      {:ok, user} = JustPostgres.OSUser.lookup(user())
      File.chown!(path, user.uid)
      File.chgrp!(path, user.gid)
    end

    path
  end

  def wait_for(fun, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          raise ExUnit.AssertionError, message: "timed out waiting for a condition"
        end

        Process.sleep(100)
        do_wait_for(fun, deadline)

      result ->
        result
    end
  end

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
