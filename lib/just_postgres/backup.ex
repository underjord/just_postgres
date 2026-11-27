defmodule JustPostgres.Backup do
  @moduledoc false

  # Takes base backups on a schedule and applies retention. The server starts
  # it once PostgreSQL is running and stops it before PostgreSQL stops.
  #
  # Each check runs in a task, so status calls get answered during a long
  # backup. A check asks the storage for the newest backup and takes a new
  # one when there's none, when it's older than the interval, or when it's
  # from an older timeline (after a restore). Before writing anything it
  # makes sure the storage belongs to this cluster.

  use GenServer

  alias JustPostgres.Recovery
  alias JustPostgres.WalG

  require Logger

  # How often to look again while PostgreSQL starts or recovers
  @poll_interval 1_000
  @max_retry_interval :timer.hours(1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name(opts[:server]))
  end

  @spec name(atom()) :: atom()
  def name(server) when is_atom(server), do: Module.concat(server, Backup)

  @spec backup_now(atom(), timeout()) :: {:ok, WalG.backup()} | {:error, term()}
  def backup_now(server, timeout), do: call(server, :backup_now, timeout)

  @spec status(atom()) :: map() | {:error, :not_running}
  def status(server), do: call(server, :status, 5_000)

  @doc """
  Cancel any running backup and stop scheduling new ones until `resume/1`
  """
  @spec pause(atom()) :: :ok | {:error, :not_running}
  def pause(server), do: call(server, :pause, 30_000)

  @spec resume(atom()) :: :ok | {:error, :not_running}
  def resume(server), do: call(server, :resume, 5_000)

  defp call(server, message, timeout) do
    GenServer.call(name(server), message, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      server: opts[:server],
      opts: opts[:backup],
      task: nil,
      phase: :starting,
      forced: false,
      callers: [],
      paused: false,
      timer: nil,
      next_at: nil,
      failures: 0,
      last_backup: nil,
      last_error: nil
    }

    {:ok, schedule(state, 0)}
  end

  @impl GenServer
  def handle_call(:backup_now, _from, %{paused: true} = state) do
    {:reply, {:error, :paused}, state}
  end

  def handle_call(:backup_now, from, state) do
    state = %{state | callers: [from | state.callers], forced: true}

    if state.task,
      do: {:noreply, state},
      else: {:noreply, start_check(state)}
  end

  def handle_call(:status, _from, state) do
    status = %{
      phase: if(state.paused, do: :paused, else: state.phase),
      last_backup: state.last_backup,
      last_error: state.last_error,
      next_check_at: state.next_at
    }

    {:reply, status, state}
  end

  def handle_call(:pause, _from, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    state = reply_all(state, {:error, :paused})
    state = cancel_timer(%{state | task: nil, paused: true, forced: false})
    {:reply, :ok, state}
  end

  def handle_call(:resume, _from, state) do
    if state.paused,
      do: {:reply, :ok, schedule(%{state | paused: false}, 0)},
      else: {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    state = %{state | timer: nil}

    if state.paused or state.task,
      do: {:noreply, state},
      else: {:noreply, start_check(state)}
  end

  def handle_info({:phase, phase}, state) do
    {:noreply, %{state | phase: phase}}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_result(result, %{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, handle_result({:error, {:crashed, reason}}, %{state | task: nil})}
  end

  def handle_info(_message, state) do
    # Task exits (trapped) and replies from cancelled tasks
    {:noreply, state}
  end

  defp start_check(state) do
    %{server: server, opts: opts, forced: forced} = state
    parent = self()
    task = Task.async(fn -> check(parent, server, opts, forced) end)
    %{cancel_timer(state) | task: task, forced: false, phase: :checking}
  end

  defp handle_result(:not_ready, state) do
    # Keep a pending backup_now/2 for when the server is ready
    state = %{state | phase: :waiting, forced: state.callers != []}
    schedule(state, @poll_interval)
  end

  defp handle_result({:not_due, latest}, state) do
    state = %{state | phase: :idle, last_backup: latest, last_error: nil, failures: 0}
    interval = state.opts[:interval]

    if state.callers == [] do
      age = DateTime.diff(DateTime.utc_now(), latest.finish_time, :millisecond)
      # A clock that's behind (no RTC, no NTP yet) makes the age negative
      schedule(state, min(max(interval - age, 0), interval))
    else
      # backup_now/2 came in during a check that found nothing to do
      schedule(%{state | forced: true}, 0)
    end
  end

  defp handle_result({:backed_up, latest, count}, state) do
    Logger.info(
      "[JustPostgres] Base backup #{latest.name} finished. #{count} backup(s) in storage."
    )

    state = %{state | phase: :idle, last_backup: latest, last_error: nil, failures: 0}
    state = reply_all(state, {:ok, latest})
    schedule(state, state.opts[:interval])
  end

  defp handle_result({:error, reason}, state) do
    delay = min(state.opts[:retry_interval] * Integer.pow(2, state.failures), @max_retry_interval)

    Logger.error(
      "[JustPostgres] Backup failed: #{JustPostgres.Server.format_error(reason)}. " <>
        "Retrying in #{div(delay, 1000)} s."
    )

    state = %{state | phase: :failed, last_error: reason, failures: state.failures + 1}
    state = reply_all(state, {:error, reason})
    schedule(state, delay)
  end

  defp reply_all(state, reply) do
    Enum.each(state.callers, &GenServer.reply(&1, reply))
    %{state | callers: []}
  end

  defp schedule(state, delay) do
    state = cancel_timer(state)
    timer = Process.send_after(self(), :tick, delay)
    %{state | timer: timer, next_at: DateTime.add(DateTime.utc_now(), delay, :millisecond)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  ## The check, run in a task

  defp check(parent, server, opts, forced) do
    with {:ok, ctx} <- server_context(server),
         {:ok, local} <- local_state(server),
         {:ok, backups} <- WalG.list(ctx),
         latest = List.last(backups),
         :ok <- check_system_identifier(latest, local),
         :ok <- check_owner(ctx, local) do
      if due?(forced, latest, local, opts[:interval]) do
        send(parent, {:phase, :backing_up})
        backup(ctx, opts)
      else
        {:not_due, latest}
      end
    end
  end

  defp backup(ctx, opts) do
    Logger.info("[JustPostgres] Starting a base backup")

    with :ok <- WalG.push(ctx),
         :ok <- retain(ctx, opts[:retain]),
         {:ok, backups} <- WalG.list(ctx) do
      {:backed_up, List.last(backups), length(backups)}
    end
  end

  # The backup worked even if cleaning up after it didn't, so only warn
  defp retain(ctx, count) do
    case WalG.delete_retain(ctx, count) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[JustPostgres] Deleting old backups failed: #{JustPostgres.Server.format_error(reason)}"
        )

        :ok
    end
  end

  defp server_context(server) do
    if JustPostgres.ready?(server),
      do: {:ok, JustPostgres.info(server)},
      else: :not_ready
  catch
    :exit, _ -> :not_ready
  end

  @local_state_sql """
  SELECT json_build_object(
    'in_recovery', pg_is_in_recovery(),
    'system_identifier', s.system_identifier::text,
    'timeline', CASE WHEN pg_is_in_recovery() THEN NULL
                ELSE substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8) END)
  FROM pg_control_system() s
  """

  defp local_state(server) do
    case JustPostgres.cmd("psql", ["-XAtqc", @local_state_sql], server: server) do
      {output, 0} ->
        case JSON.decode(String.trim(output)) do
          # Base backups need a primary, so wait until recovery is done
          {:ok, %{"in_recovery" => true}} ->
            :not_ready

          {:ok, %{"system_identifier" => id, "timeline" => timeline}} ->
            {:ok,
             %{
               system_identifier: String.to_integer(id),
               timeline: String.to_integer(timeline, 16)
             }}

          _ ->
            {:error, {:unexpected_output, output}}
        end

      _ ->
        # Most likely the server stopped or restarted in the meantime
        :not_ready
    end
  catch
    :exit, _ -> :not_ready
  end

  defp check_system_identifier(nil, _local), do: :ok

  defp check_system_identifier(latest, local) do
    if latest.system_identifier == local.system_identifier,
      do: :ok,
      else: {:error, {:foreign_backups, latest.name, latest.system_identifier}}
  end

  # Only the cluster named in the storage's owner marker takes backups and
  # deletes old ones. A cluster that was just created or restored has
  # `claim` set and takes over the marker. That's how a replacement device
  # takes over from the one it replaces, which stops backing up if it ever
  # comes back.
  defp check_owner(ctx, local) do
    cluster = Recovery.ensure_cluster!(ctx.data_dir, ctx.user)

    with {:ok, owner} <- WalG.read_owner(ctx) do
      cond do
        cluster["claim"] == true or owner == nil -> claim(ctx, cluster, local)
        owner["cluster_id"] == cluster["cluster_id"] -> :ok
        true -> {:error, {:not_owner, owner}}
      end
    end
  end

  defp claim(ctx, cluster, local) do
    {:ok, hostname} = :inet.gethostname()

    owner = %{
      "cluster_id" => cluster["cluster_id"],
      "system_identifier" => Integer.to_string(local.system_identifier),
      "hostname" => to_string(hostname),
      "claimed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    with :ok <- WalG.write_owner(ctx, owner) do
      Logger.info("[JustPostgres] This cluster now owns the backup storage")
      _ = Recovery.write_cluster!(ctx.data_dir, ctx.user, Map.put(cluster, "claim", false))
      :ok
    end
  end

  defp due?(true, _latest, _local, _interval), do: true
  defp due?(_forced, nil, _local, _interval), do: true

  defp due?(_forced, latest, local, interval) do
    latest.timeline != local.timeline or
      DateTime.diff(DateTime.utc_now(), latest.finish_time, :millisecond) >= interval
  end
end
