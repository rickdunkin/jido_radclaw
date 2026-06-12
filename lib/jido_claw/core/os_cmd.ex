defmodule JidoClaw.Core.OsCmd do
  @moduledoc """
  Port-based external command runner with OS process-**tree** kill on
  timeout.

  `System.cmd/3` wrapped in a `Task` (the previous pattern at the Forge
  and shell call sites) only kills the BEAM side on timeout — the Task is
  brutally killed or the port closed, but the spawned OS process and any
  grandchildren it forked (`sh -c` pipelines, agent CLIs like `claude` /
  `codex`) keep running unsupervised. This module runs the command
  through a `Port` so the OS pid is known up front, and on timeout kills
  the whole descendant tree.

  `setsid`/process-group approaches are deliberately avoided: `setsid(1)`
  does not exist on macOS, and an `exec` prefix is unsafe for pipeline
  commands. Instead `kill_tree/1` walks the live process table.

  Output accumulation is bounded by default (`:max_output_bytes`, see
  `run/3`): a runaway child cannot balloon BEAM memory — past the cap
  the tree is killed and the cap-sized prefix returned with
  `:output_limit`.

  ## Tree-kill strategy

  `kill_tree/1` is a bounded STOP-fixpoint followed by a single KILL:

  1. `SIGSTOP` the root so it cannot fork while the tree is walked
     (SIGKILL works fine on stopped processes).
  2. Snapshot `ps -A -o pid= -o ppid=` (POSIX flags — macOS and Linux),
     BFS the descendants of the stopped set, `SIGSTOP` any newly found
     ones, and re-snapshot until the set is stable or a small attempt
     cap is hit — already-running descendants can fork between snapshot
     and kill, so a single optimistic pass is not enough.
  3. One `kill -KILL` of the whole collected set.

  A snapshot failure mid-walk degrades to killing everything collected
  so far (root included) — a raise between STOP and KILL must never
  leave the tree frozen forever.
  """

  alias JidoClaw.Security.Redaction.Env

  # Default per-command output cap. Matches the jido_shell streaming cap
  # (`BackendHost.max_output_bytes/0`) and sits far above the 32 KB tool
  # and 10 KB forge-persistence caps, so it only catches runaways.
  @default_max_output_bytes 10_000_000

  # Cap on STOP→snapshot rounds before giving up on finding new
  # descendants. Each round STOPs everything it found, so even a
  # hostile fork loop loses its forking ancestors within a few rounds.
  @stop_fixpoint_attempts 5

  # How long to wait for the port to deliver the SIGKILL'd child's
  # buffered output + exit_status before force-closing it.
  @post_kill_drain_ms 1_000

  @doc """
  Runs `executable` with `args` through a `Port`, returning
  `{output, exit_status}` — or `{partial_output, :timeout}` after
  killing the OS process tree when `:timeout` elapses, or
  `{capped_output, :output_limit}` after killing the tree when the
  output cap is exceeded.

  Options:

    * `:cd` — working directory (default `File.cwd!()`)
    * `:timeout` — milliseconds or `:infinity` (default `:infinity`);
      a wall-clock cap on total runtime — output activity does not
      extend it
    * `:max_output_bytes` — positive integer or `:infinity` (default:
      the `:os_cmd_max_output_bytes` app env, 10 MB). When the
      accumulated output would exceed the cap, the overflowing chunk
      is cut at exactly the cap, the OS process tree is killed, and
      `{capped_output, :output_limit}` is returned — the result is
      exactly cap-sized. `:infinity` (no cap) is honored only as an
      explicit per-call option; the app env accepts positive integers
      only, so global config can never silently disable the default
    * `:env` — environment in `System.cmd/3` format
      (`[{String.t(), String.t() | nil}]`); defaults to
      `Env.scrubbed_cmd_env()` so a caller that forgets the option
      never leaks parent secrets into the child. Pass `:env` built via
      `Env.scrubbed_cmd_env(overrides)` to inject vars — an explicit
      `:env` is used as-is

  stderr is merged into stdout, mirroring
  `System.cmd(..., stderr_to_stdout: true)`.
  """
  @spec run(binary(), [binary()], keyword()) ::
          {binary(), integer() | :timeout | :output_limit}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    cd = Keyword.get(opts, :cd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, :infinity)
    env = Keyword.get_lazy(opts, :env, &Env.scrubbed_cmd_env/0)

    max_bytes =
      opts
      |> Keyword.get(:max_output_bytes, configured_max_output_bytes())
      |> normalize_max_output_bytes()

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:cd, cd},
        {:env, to_port_env(env)}
      ])

    # Capture the OS pid immediately: `Port.info/2` returns `nil` once
    # the port is closed, so this must be a nil-safe `case`, not a
    # destructuring match.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    collect(port, os_pid, [], 0, max_bytes, deadline(timeout))
  end

  # Normalize the `:os_cmd_max_output_bytes` app env: only a positive
  # integer is honored — `:infinity` deliberately included in the
  # rejects, so global config can never silently disable the safety
  # default (opt out per call instead). Same fail-closed normalization
  # as `Allocate.payload_leaf_cap/0`: a nil cap would fail open under
  # Erlang term ordering, a non-positive one would cap everything to
  # empty. Public for tests — the invalid-config fallback is unit-
  # testable without generating >10 MB of real output.
  @doc false
  @spec configured_max_output_bytes() :: pos_integer()
  def configured_max_output_bytes do
    case Application.get_env(:jido_claw, :os_cmd_max_output_bytes, @default_max_output_bytes) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _invalid -> @default_max_output_bytes
    end
  end

  # The per-call option additionally accepts `:infinity` (explicit
  # opt-out); anything else invalid falls back to the configured cap.
  defp normalize_max_output_bytes(:infinity), do: :infinity
  defp normalize_max_output_bytes(bytes) when is_integer(bytes) and bytes > 0, do: bytes
  defp normalize_max_output_bytes(_invalid), do: configured_max_output_bytes()

  @doc """
  Kills the OS process rooted at `os_pid` together with all of its
  descendants. Always returns `:ok` — already-dead pids and failed
  signals are ignored.

  Callers must guard the `nil` case themselves (e.g. when
  `Port.info(port, :os_pid)` came back empty); this function only
  accepts an integer pid.
  """
  @spec kill_tree(pos_integer()) :: :ok
  def kill_tree(os_pid) when is_integer(os_pid) do
    root = Integer.to_string(os_pid)
    signal("-STOP", [root])

    stopped = stop_fixpoint(MapSet.new([root]), @stop_fixpoint_attempts)

    signal("-KILL", MapSet.to_list(stopped))
  end

  # -- run/3 internals ---------------------------------------------------------

  # The deadline is checked *before* each receive, not just enforced via
  # `after` — a zero-timeout receive still consumes queued `{:data, _}`
  # messages first, so a chatty child with a mailbox backlog could keep
  # delaying the kill past the deadline. The deadline check also comes
  # before the cap check: a chunk tripping both reports `:timeout`.
  defp collect(port, os_pid, acc, bytes_so_far, max_bytes, deadline) do
    case remaining(deadline) do
      0 ->
        timeout(port, os_pid, acc)

      wait ->
        receive do
          {^port, {:data, chunk}} ->
            new_total = bytes_so_far + byte_size(chunk)

            if within_cap?(max_bytes, new_total) do
              collect(port, os_pid, [acc, chunk], new_total, max_bytes, deadline)
            else
              # Keep the prefix of the overflowing chunk up to exactly
              # the cap, so the result is exactly cap-sized.
              kept = binary_part(chunk, 0, max_bytes - bytes_so_far)
              output_limit(port, os_pid, [acc, kept])
            end

          {^port, {:exit_status, status}} ->
            flush_port(port)
            {IO.iodata_to_binary(acc), status}
        after
          wait ->
            timeout(port, os_pid, acc)
        end
    end
  end

  # Explicit clause for the uncapped case — `new_total <= :infinity`
  # would "work" via Erlang term ordering, but opaquely.
  defp within_cap?(:infinity, _new_total), do: true
  defp within_cap?(max_bytes, new_total), do: new_total <= max_bytes

  # Once the deadline passes we report `:timeout` even if the child raced
  # to completion — `kill_tree/1` on an already-dead pid is a no-op and
  # `drain_after_kill/2` still collects the queued output.
  defp timeout(port, os_pid, acc) do
    output =
      if is_integer(os_pid) do
        kill_tree(os_pid)
        drain_after_kill(port, acc)
      else
        # No OS pid to kill (port already gone) — just close.
        close_port(port)
        acc
      end

    flush_port(port)
    {IO.iodata_to_binary(output), :timeout}
  end

  # Mirrors timeout/3 — including the nil-os_pid safety branch — but the
  # post-kill drain *discards* the child's buffered output instead of
  # accumulating it: the cap exists to bound memory, so the drain keeps
  # only the mailbox/port hygiene, never regrows the result.
  defp output_limit(port, os_pid, acc) do
    if is_integer(os_pid) do
      kill_tree(os_pid)
      drain_after_kill_discard(port)
    else
      # No OS pid to kill (port already gone) — just close.
      close_port(port)
    end

    flush_port(port)
    {IO.iodata_to_binary(acc), :output_limit}
  end

  defp deadline(:infinity), do: :infinity

  defp deadline(timeout_ms) when is_integer(timeout_ms),
    do: System.monotonic_time(:millisecond) + timeout_ms

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # After SIGKILL the port still delivers the child's buffered output
  # and its exit_status; collect those so the caller gets the partial
  # output. Fall back to a hard close if the port never reports.
  defp drain_after_kill(port, acc) do
    receive do
      {^port, {:data, chunk}} -> drain_after_kill(port, [acc, chunk])
      {^port, {:exit_status, _status}} -> acc
    after
      @post_kill_drain_ms ->
        close_port(port)
        acc
    end
  end

  # The output-limit twin of drain_after_kill/2: consume-and-drop port
  # messages until the exit_status (or the drain cap), force-closing the
  # port on the timeout branch exactly like its accumulating sibling.
  defp drain_after_kill_discard(port) do
    receive do
      {^port, {:data, _chunk}} -> drain_after_kill_discard(port)
      {^port, {:exit_status, _status}} -> :ok
    after
      @post_kill_drain_ms ->
        close_port(port)
    end
  end

  # Zero-timeout flush of any straggler port messages — including the
  # `{:EXIT, port, _}` a trapping caller receives on port death.
  # Mirrors `System.cmd/3` hygiene.
  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
      {:EXIT, ^port, _reason} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  catch
    # Already closed — `Port.close/1` raises `:badarg` on a dead port.
    :error, :badarg -> :ok
  end

  # Callers pass env in `System.cmd/3` format, already scrubbed; this is
  # a pure shape conversion to the port format (charlists, `nil` →
  # `false` to unset) — same conversion as `Env.scrubbed_port_env/1`.
  defp to_port_env(env) do
    for {k, v} <- env do
      {String.to_charlist(k), if(is_nil(v), do: false, else: String.to_charlist(v))}
    end
  end

  # -- kill_tree/1 internals ---------------------------------------------------

  # Repeatedly snapshot the process table, STOP any newly discovered
  # descendants of the stopped set, and re-snapshot until stable (or the
  # attempt cap). Returns the full stopped set. A failed snapshot
  # returns what was collected so far — the caller's KILL must always
  # run so no STOPped process is left frozen.
  defp stop_fixpoint(stopped, 0), do: stopped

  defp stop_fixpoint(stopped, attempts_left) do
    case ps_children_by_ppid() do
      {:ok, children_by_ppid} ->
        new =
          stopped
          |> descendants(children_by_ppid)
          |> MapSet.difference(stopped)

        if MapSet.size(new) == 0 do
          stopped
        else
          signal("-STOP", MapSet.to_list(new))
          stop_fixpoint(MapSet.union(stopped, new), attempts_left - 1)
        end

      :error ->
        stopped
    end
  end

  # BFS over the ppid → pids map starting from every pid in `roots`.
  # Pids stay strings throughout so nothing but strings ever reaches a
  # kill/ps argv.
  defp descendants(roots, children_by_ppid) do
    walk_descendants(MapSet.to_list(roots), roots, children_by_ppid)
  end

  defp walk_descendants([], seen, _children_by_ppid), do: seen

  defp walk_descendants([pid | rest], seen, children_by_ppid) do
    new_kids =
      children_by_ppid
      |> Map.get(pid, [])
      |> Enum.reject(&MapSet.member?(seen, &1))

    walk_descendants(new_kids ++ rest, Enum.into(new_kids, seen), children_by_ppid)
  end

  defp ps_children_by_ppid do
    case run_cmd("ps", ["-A", "-o", "pid=", "-o", "ppid="]) do
      {output, 0} -> {:ok, parse_ps(output)}
      _other -> :error
    end
  end

  defp parse_ps(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line) do
        [pid, ppid] -> Map.update(acc, ppid, [pid], &[pid | &1])
        _other -> acc
      end
    end)
  end

  defp signal(_flag, []), do: :ok

  defp signal(flag, pids) do
    # Nonzero exits are expected (already-dead pids) and ignored.
    _ = run_cmd("kill", [flag | Enum.map(pids, &to_string/1)])
    :ok
  end

  defp run_cmd(cmd, args) do
    case System.find_executable(cmd) do
      nil -> {"", 127}
      path -> System.cmd(path, args, env: Env.scrubbed_cmd_env(), stderr_to_stdout: true)
    end
  rescue
    # Defensive: a posix failure spawning ps/kill must not raise out of
    # the kill path — kill_tree always falls through to its final KILL.
    _ in [ErlangError, ArgumentError] -> {"", 1}
  end
end
