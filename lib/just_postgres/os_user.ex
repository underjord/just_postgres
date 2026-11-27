defmodule JustPostgres.OSUser do
  @moduledoc false

  # Helpers for running PostgreSQL as an unprivileged user when the BEAM is
  # root. Nerves has no `id` or `getent`, so this reads /proc and /etc/passwd.

  @type t() :: %{name: String.t(), uid: non_neg_integer(), gid: non_neg_integer()}

  @doc """
  Return the effective uid of the BEAM
  """
  @spec euid() :: non_neg_integer()
  def euid() do
    case File.read("/proc/self/status") do
      {:ok, status} ->
        [_, euid | _] = Regex.run(~r/^Uid:\s+(\d+)\s+(\d+)/m, status)
        String.to_integer(euid)

      {:error, _} ->
        {out, 0} = System.cmd("id", ["-u"])
        out |> String.trim() |> String.to_integer()
    end
  end

  @doc """
  Return true if the BEAM runs as root
  """
  @spec root?() :: boolean()
  def root?(), do: euid() == 0

  @doc """
  Look up a user in /etc/passwd
  """
  @spec lookup(String.t(), Path.t()) :: {:ok, t()} | {:error, :not_found}
  def lookup(name, passwd_path \\ "/etc/passwd") do
    with {:ok, contents} <- File.read(passwd_path),
         [_, uid, gid] <- Regex.run(~r/^#{Regex.escape(name)}:[^:]*:(\d+):(\d+):/m, contents) do
      {:ok, %{name: name, uid: String.to_integer(uid), gid: String.to_integer(gid)}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Return the first ancestor directory of `path` that `user` can't search

  Only owner, group and other permission bits are checked, not
  supplementary groups or ACLs.
  """
  @spec blocking_ancestor(Path.t(), t()) :: Path.t() | nil
  def blocking_ancestor(path, user) do
    path
    |> Path.expand()
    |> ancestors()
    |> Enum.find(fn dir -> not searchable?(dir, user) end)
  end

  defp ancestors(path) do
    case Path.dirname(path) do
      ^path -> []
      parent -> ancestors(parent) ++ [parent]
    end
  end

  defp searchable?(dir, user) do
    case File.stat(dir) do
      {:ok, %File.Stat{mode: mode, uid: uid, gid: gid}} ->
        import Bitwise

        cond do
          user.uid == 0 -> true
          uid == user.uid -> (mode &&& 0o100) != 0
          gid == user.gid -> (mode &&& 0o010) != 0
          true -> (mode &&& 0o001) != 0
        end

      {:error, _} ->
        # Doesn't exist yet. The parent check covers it.
        true
    end
  end
end
