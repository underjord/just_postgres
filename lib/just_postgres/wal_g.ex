defmodule JustPostgres.WalG do
  @moduledoc false

  # Runs WAL-G commands as the server's OS user with the server's
  # environment. `ctx` is the map returned by `JustPostgres.info/1`, or one
  # with the same keys built while the server starts.

  alias JustPostgres.Server

  # Marks which cluster may write base backups to a storage prefix
  @owner_path "just_postgres/owner.json"

  # Storage listings and small objects. Unreachable storage makes WAL-G retry
  # for a long time, so give up and let the caller retry later.
  @short_timeout 120_000

  @type ctx() :: map()

  @type backup() :: %{
          name: String.t(),
          start_time: DateTime.t(),
          finish_time: DateTime.t(),
          wal_file_name: String.t(),
          timeline: pos_integer(),
          system_identifier: non_neg_integer(),
          pg_version: non_neg_integer(),
          start_lsn: non_neg_integer(),
          finish_lsn: non_neg_integer(),
          uncompressed_size: non_neg_integer(),
          compressed_size: non_neg_integer(),
          permanent: boolean()
        }

  @spec path(ctx()) :: Path.t()
  def path(ctx), do: Path.join([ctx.install_dir, "bin", "wal-g"])

  @doc """
  Run a WAL-G command. Returns `{output, status}` like `MuonTrap.cmd/3`.
  """
  @spec run(ctx(), [String.t()], keyword()) :: {String.t(), non_neg_integer() | :timeout}
  def run(ctx, args, opts \\ []) do
    MuonTrap.cmd(path(ctx), args, Server.run_opts(ctx.user, ctx.env) ++ opts)
  end

  @doc """
  List base backups, oldest first
  """
  @spec list(ctx()) :: {:ok, [backup()]} | {:error, term()}
  def list(ctx) do
    with {:ok, output} <-
           ok(run(ctx, ["backup-list", "--detail", "--json"], timeout: @short_timeout)),
         {:ok, json} <- decode_json_line(output, "[") do
      backups =
        json
        |> Enum.map(&parse_backup/1)
        |> Enum.sort_by(& &1.finish_time, DateTime)

      {:ok, backups}
    end
  end

  defp parse_backup(b) do
    wal = b["wal_file_name"]

    %{
      name: b["backup_name"],
      start_time: parse_time(b["start_time"]),
      finish_time: parse_time(b["finish_time"]),
      wal_file_name: wal,
      timeline: wal |> binary_part(0, 8) |> String.to_integer(16),
      system_identifier: b["system_identifier"],
      pg_version: b["pg_version"],
      start_lsn: b["start_lsn"],
      finish_lsn: b["finish_lsn"],
      uncompressed_size: b["uncompressed_size"],
      compressed_size: b["compressed_size"],
      permanent: b["is_permanent"] == true
    }
  end

  defp parse_time(string) do
    {:ok, time, _} = DateTime.from_iso8601(string)
    time
  end

  @doc """
  Take a base backup of the running server
  """
  @spec push(ctx()) :: :ok | {:error, term()}
  def push(ctx) do
    with {:ok, _} <- ok(run(ctx, ["backup-push", ctx.data_dir])), do: :ok
  end

  @doc """
  Keep the newest `count` full backups and delete everything older
  """
  @spec delete_retain(ctx(), pos_integer()) :: :ok | {:error, term()}
  def delete_retain(ctx, count) do
    args = ["delete", "retain", "FULL", Integer.to_string(count), "--confirm"]
    with {:ok, _} <- ok(run(ctx, args, timeout: :timer.minutes(30))), do: :ok
  end

  @doc """
  Download a base backup into an empty directory
  """
  @spec fetch(ctx(), Path.t(), String.t()) :: :ok | {:error, term()}
  def fetch(ctx, dir, backup_name) do
    with {:ok, _} <- ok(run(ctx, ["backup-fetch", dir, backup_name])), do: :ok
  end

  @doc """
  Read the storage's owner marker. Returns `{:ok, nil}` if there's none.
  """
  @spec read_owner(ctx()) :: {:ok, map() | nil} | {:error, term()}
  def read_owner(ctx) do
    case run(ctx, ["st", "cat", @owner_path], timeout: @short_timeout) do
      {output, 0} ->
        decode_json_line(output, "{")

      {output, status} when is_integer(status) ->
        if output =~ "not found in storage",
          do: {:ok, nil},
          else: {:error, {:wal_g, status, output}}

      {_output, :timeout} ->
        {:error, :timeout}
    end
  end

  @doc """
  Write the storage's owner marker
  """
  @spec write_owner(ctx(), map()) :: :ok | {:error, term()}
  def write_owner(ctx, owner) do
    # WAL-G runs as the server's user, so the file goes in the socket
    # directory, which belongs to that user.
    file =
      Path.join(ctx.socket_dir, ".just_postgres_owner-#{System.unique_integer([:positive])}.json")

    Server.write_private_file!(file, JSON.encode!(owner), ctx.user)

    args = ["st", "put", "--force", "--no-compress", "--no-encrypt", file, @owner_path]

    try do
      with {:ok, _} <- ok(run(ctx, args, timeout: @short_timeout)), do: :ok
    after
      File.rm(file)
    end
  end

  defp ok({output, 0}), do: {:ok, output}
  defp ok({_output, :timeout}), do: {:error, :timeout}
  defp ok({output, status}), do: {:error, {:wal_g, status, output}}

  # WAL-G logs to stderr, which is mixed into the output, and prints its
  # result on one line.
  defp decode_json_line(output, start) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, start))
    |> List.last()
    |> case do
      nil -> {:error, {:unexpected_output, output}}
      line -> JSON.decode(line)
    end
  end
end
