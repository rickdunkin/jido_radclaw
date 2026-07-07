defmodule JidoClaw.Cluster.PeerHarness do
  @moduledoc """
  Multi-node test harness on OTP `:peer` — real BEAM nodes running the full
  app against ONE shared Postgres (WS6). Pure infrastructure, zero ExUnit
  coupling, so later cluster phases can reuse it for scenario choreography.

  The cross-BEAM model:

    * The test node is a pure coordinator (`cluster_enabled: false`): it seeds
      and asserts via the shared DB, or `:erpc`s into a peer via `call/5`.
      Telemetry and PubSub are node-local — they never carry an assertion
      across BEAMs.
    * Peers boot with an EMPTY app env (the built `.app` carries none; Mix
      config applies only to the test node), so `start_peers/2` snapshots the
      origin's full application env once and `boot/1` replays it on the peer
      before `Application.ensure_all_started(:jido_claw)`. Overrides
      (`cluster_enabled: true`, `cluster_strategy: :none`, ...) apply last.
    * Formation is `:none` topology + an explicit `Node.connect/1` mesh —
      libcluster stays idle (no gossip secret, no strategy polling) and the
      harness meshes peers deterministically.
    * Bootstrap rides the `:peer` control channel (`:peer.call/5`, stdio) —
      NOT `:erpc`, which needs working distribution, so a cookie/name-domain
      misconfiguration would surface as an opaque `:noconnection` before
      `boot/1` could return its staged error. Only after `boot/1` returns does
      `start_peers/2` prove distribution (connect + `:erpc` canary) and switch
      all test-time traffic to `call/5`.
    * Peers are started UNLINKED (`:peer.start/1`): `setup_all` runs in a
      transient process, and OTP link semantics would tear peers down when it
      exits. Lifecycle is owned explicitly instead — every failure class in
      `start_peers/2` stops the already-started peers before re-raising, and
      the stdio control channel makes peers self-halt if the origin BEAM dies.
  """

  alias JidoClaw.Repo

  @type peer :: %{node: node(), server: pid()}

  @default_boot_timeout_ms 60_000
  @db_boot_timeout_ms 30_000
  @poll_interval_ms 25

  @doc """
  Idempotently make the origin BEAM distributed: ensure epmd is up, then —
  unless the node is already alive — start distribution as
  `jc_origin_<os-pid>_<unique>@127.0.0.1` (longnames pinned to the loopback
  address dodge macOS/CI hostname-resolution flakiness). Returns `Node.self()`.
  """
  @spec ensure_distribution!() :: node()
  def ensure_distribution! do
    ensure_epmd!()

    if Node.alive?() do
      Node.self()
    else
      # Per-run unique node names are inherently runtime atoms; one per BEAM.
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name = :"jc_origin_#{run_suffix()}@127.0.0.1"

      case Node.start(name, name_domain: :longnames) do
        {:ok, _pid} -> Node.self()
        {:error, reason} -> raise "could not start distribution as #{name}: #{inspect(reason)}"
      end
    end
  end

  @doc """
  Boot `n` peers sequentially (shared-DB boot writers are idempotent, but there
  is no need to race them), mesh them peer-to-peer, and await the mesh settling.
  Returns the peers in boot order.

  Options:

    * `:boot_timeout` — per-stage bound in ms for `:peer.start` `wait_boot`,
      each control-channel call, and the mesh awaits (default 60s).
    * `:overrides` — extra `:jido_claw` app-env overrides merged over the
      harness defaults on every peer (the later-phase seam for short lease
      windows, per-peer pooler arming, etc.).

  ANY failure class — raise, exit, or throw, from `:peer` boot, the config
  push, or the mesh awaits — stops every already-started peer before
  re-raising with the original class and stacktrace, so a partial failure
  never leaks peers for the rest of the test BEAM.
  """
  @spec start_peers(pos_integer(), keyword()) :: [peer()]
  def start_peers(n, opts \\ []) do
    ensure_distribution!()
    boot_timeout = Keyword.get(opts, :boot_timeout, @default_boot_timeout_ms)

    boot_args = %{
      pushed: push_config(),
      extra: Keyword.get(opts, :overrides, []),
      suffix: run_suffix(),
      timeout: boot_timeout
    }

    peers =
      1..n
      |> Enum.reduce([], fn i, acc ->
        cleanup_on_failure(acc, fn -> [start_one(i, boot_args) | acc] end)
      end)
      |> Enum.reverse()

    cleanup_on_failure(peers, fn ->
      nodes = Enum.map(peers, & &1.node)
      connect_mesh(nodes)
      await_mesh!(nodes, boot_timeout)
      peers
    end)
  end

  @doc """
  The single peer-side boot procedure — runs ON THE PEER via the `:peer`
  control channel. Replays the origin's pushed config (`persistent: true`, the
  Mix config mechanism, applied before `:logger` starts so the pushed level
  governs from the first message), applies `:jido_claw` overrides last, starts
  the app, and polls the shared DB to a deadline.

  Returns `:ok`, or `{:error, {stage, reason}}` with `stage` one of
  `:ensure_all_started` / `:db_timeout` so setup failures stay attributable
  even when distribution is broken.
  """
  @spec boot(%{config: [{atom(), keyword()}], overrides: keyword()}) ::
          :ok | {:error, {:ensure_all_started | :db_timeout, term()}}
  def boot(%{config: config, overrides: overrides}) do
    {:ok, _apps} = Application.ensure_all_started(:elixir)
    Application.put_all_env(config, persistent: true)

    Enum.each(overrides, fn {key, value} ->
      Application.put_env(:jido_claw, key, value, persistent: true)
    end)

    {:ok, _apps} = Application.ensure_all_started(:logger)

    case Application.ensure_all_started(:jido_claw) do
      {:ok, _apps} -> await_db()
      {:error, reason} -> {:error, {:ensure_all_started, reason}}
    end
  end

  @doc """
  `Node.connect/1` every peer pair over `:erpc`. The origin↔peer edges already
  exist (proven during `start_peers/2`); peer↔peer edges are not implicit.
  """
  @spec connect_mesh([node()]) :: :ok
  def connect_mesh(nodes) do
    Enum.each(node_pairs(nodes), fn {a, b} ->
      true = :erpc.call(a, Node, :connect, [b])
    end)
  end

  @doc "Stop each peer via its `:peer` server. Idempotent: already-dead peers are skipped."
  @spec stop_peers([peer()]) :: :ok
  def stop_peers(peers) do
    Enum.each(peers, fn %{server: server} ->
      try do
        :peer.stop(server)
      catch
        # An already-stopped peer exits here; swallow it so the remaining
        # stops still run — cleanup must never mask the original failure.
        _kind, _reason -> :ok
      end
    end)
  end

  @doc "Thin `:erpc.call/5` — the test-time transport once distribution is proven."
  @spec call(node(), module(), atom(), [term()], timeout()) :: term()
  def call(node, module, fun, args, timeout \\ 15_000) do
    :erpc.call(node, module, fun, args, timeout)
  end

  @doc """
  The one bounded poll-until-true helper (never bare sleeps): re-run `fun`
  every #{@poll_interval_ms}ms until it returns `true` or `timeout` ms elapse.
  """
  @spec await((-> boolean()), non_neg_integer()) :: :ok | {:error, :timeout}
  def await(fun, timeout) do
    poll(fun, System.monotonic_time(:millisecond) + timeout)
  end

  # ── origin-side internals ─────────────────────────────────────────────────

  # Run `fun`; when it fails for ANY reason, stop `peers` and re-raise with the
  # original class + stacktrace. A two-arg `catch` covers all three classes —
  # `:error` (raises) included — where `rescue` alone would miss the exits
  # `:erpc.call`/`:peer.call` and peer boot failures produce.
  defp cleanup_on_failure(peers, fun) do
    fun.()
  catch
    kind, reason ->
      stop_peers(peers)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp start_one(i, %{suffix: suffix, timeout: timeout} = boot_args) do
    # Per-run unique node names are inherently runtime atoms; a handful per run.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"jc_peer#{i}_#{suffix}"

    case :peer.start(peer_start_options(name, timeout)) do
      {:ok, server, node} ->
        peer = %{node: node, server: server}
        cleanup_on_failure([peer], fn -> provision(peer, name, boot_args) end)

      other ->
        raise "peer #{name} failed to start: #{inspect(other)}"
    end
  end

  # Everything after `:peer.start` for one peer: code paths + config push +
  # app boot over the control channel, then the distribution proof. Returns
  # the peer; any failure raises (and `start_one` stops this peer).
  defp provision(%{server: server, node: node} = peer, name, boot_args) do
    %{pushed: pushed, extra: extra, timeout: timeout} = boot_args

    # Put every origin ebin (incl. test/support modules) on the peer path.
    :ok = :peer.call(server, :code, :add_paths, [:code.get_path()], timeout)

    boot_arg = %{config: pushed, overrides: Keyword.merge(peer_overrides(name), extra)}

    # Named MFA — never ship anonymous funs across nodes.
    case :peer.call(server, __MODULE__, :boot, [boot_arg], timeout) do
      :ok ->
        :ok

      {:error, {stage, reason}} ->
        raise "peer #{node} boot failed at #{stage}: #{inspect(reason)}"
    end

    prove_distribution!(node, timeout)
    peer
  end

  # `boot/1` returning `:ok` over stdio proves nothing about distribution, so
  # prove it separately: connect, await visibility, and canary an `:erpc`
  # round-trip. A failure HERE (with a green `boot/1`) is a cookie or
  # name-domain mismatch — exactly why bootstrap rides the control channel.
  defp prove_distribution!(node, timeout) do
    case await(fn -> Node.connect(node) == true and node in Node.list() end, timeout) do
      :ok ->
        ^node = :erpc.call(node, :erlang, :node, [], timeout)
        :ok

      {:error, :timeout} ->
        raise "distribution to #{node} not up after #{timeout}ms " <>
                "(boot/1 already returned over the control channel — " <>
                "suspect a cookie or name-domain mismatch)"
    end
  end

  defp peer_start_options(name, boot_timeout) do
    %{
      name: name,
      host: ~c"127.0.0.1",
      longnames: true,
      args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())],
      # Synchronous boot + explicit name ⇒ the return shape is {:ok, pid, node}.
      wait_boot: boot_timeout,
      # Stdio control channel: peers self-halt if the origin BEAM dies.
      connection: :standard_io
    }
  end

  # The origin env snapshot `boot/1` replays: every loaded app EXCEPT
  # :kernel/:stdlib (keep :elixir — it carries the tz-database config). This
  # carries the flag-switched Repo config (regular pool + cluster DB), the
  # Vault cipher, secrets, logger level, and the config-gated pollers (all off
  # in test env) to peers for free.
  defp push_config do
    for {app, _desc, _vsn} <- Application.loaded_applications(), app not in [:kernel, :stdlib] do
      {app, Application.get_all_env(app)}
    end
  end

  # The one construction site for the harness's per-peer override set.
  defp peer_overrides(name) do
    [
      cluster_enabled: true,
      cluster_strategy: :none,
      skip_discord: true,
      forge_home: Path.join(System.tmp_dir!(), "jido_claw_forge_#{name}")
    ]
  end

  defp await_mesh!(nodes, timeout) do
    settled =
      await(
        fn ->
          Enum.all?(nodes, fn node ->
            listed = :erpc.call(node, Node, :list, [], timeout)
            Enum.all?(nodes -- [node], &(&1 in listed))
          end)
        end,
        timeout
      )

    case settled do
      :ok ->
        :ok

      {:error, :timeout} ->
        raise "peer mesh did not settle within #{timeout}ms: #{inspect(nodes)}"
    end
  end

  defp node_pairs(nodes) do
    indexed = Enum.with_index(nodes)
    for {a, i} <- indexed, {b, j} <- indexed, i < j, do: {a, b}
  end

  defp ensure_epmd! do
    epmd = System.find_executable("epmd") || raise "epmd not found on PATH (it ships with OTP)"
    {_out, 0} = System.cmd(epmd, ["-daemon"], env: [])
    :ok
  end

  defp run_suffix, do: "#{System.pid()}_#{System.unique_integer([:positive])}"

  # ── peer-side internals ───────────────────────────────────────────────────

  defp await_db do
    case await(fn -> match?({:ok, _}, Repo.query("SELECT 1")) end, @db_boot_timeout_ms) do
      :ok ->
        :ok

      {:error, :timeout} ->
        case Repo.query("SELECT 1") do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, {:db_timeout, reason}}
        end
    end
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(@poll_interval_ms)
        poll(fun, deadline)
    end
  end
end
