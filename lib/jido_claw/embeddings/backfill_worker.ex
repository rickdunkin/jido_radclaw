defmodule JidoClaw.Embeddings.BackfillWorker do
  @moduledoc """
  GenServer that scans the `solutions` and `memory_facts` tables for
  rows in `embedding_status: :pending` (or expired `:processing`),
  claims them atomically via `FOR UPDATE SKIP LOCKED`, and dispatches
  each to Voyage (`:default`), Ollama (`:local_only`), or no-op
  (`:disabled`) per the workspace's `embedding_policy`.

  Two trigger paths:

    * **Periodic scan** — every `:scan_interval_seconds` (default 30 in
      dev, 300 in prod). Backstop for missed hints. Both resources are
      scanned per tick.
    * **Hint-by-id** — Solution.store / Solution.import_legacy emit
      `{:hint_pending, id}`. Memory.Fact.record emits
      `{:hint_pending_memory_fact, id}`. Each hint runs an atomic
      claim against the matching table.

  Lease expiry: claims set `embedding_next_attempt_at = now() +
  INTERVAL '5 minutes'`. The periodic-scan SQL has a two-branch WHERE:
  pick up `:pending` rows OR `:processing` rows whose lease has
  expired. Without the second branch, a worker that died mid-dispatch
  would leave its claimed rows stuck in `:processing` forever.

  ## Rate-pacing the Voyage path

  Every Voyage dispatch goes through
  `JidoClaw.Embeddings.RatePacer.acquire/2` (per-node bucket) and
  `RatePacer.try_admit/2` (cluster-global window). When either gate
  rejects, the row is rescheduled with a short fixed retry window
  (see `@rate_limited_retry_seconds`) and **does not** consume an
  attempt — operator backpressure is not a per-row failure.

  ## Test seam

  Override `:voyage_module`, `:local_module`, `:rate_pacer`, or
  `:policy_resolver` via `Application.put_env/3` for the application
  before spawning the GenServer. Defaults resolve to the real
  modules. We don't take per-call opts because `dispatch_one/1` runs
  inside a `Task.async_stream` started from the GenServer state.
  """

  use GenServer
  require Logger

  alias JidoClaw.Embeddings.PolicyResolver
  alias JidoClaw.Repo

  @default_scan_interval_seconds 30
  @default_lease_seconds 300
  @default_min_age_seconds 60
  @default_batch_limit 16
  @default_concurrency 4

  @rate_limited_retry_seconds 30

  # Whitelist of (table, content_column) pairs the worker is allowed
  # to scan + update. Anything outside this list is rejected before
  # the SQL is built, so the table interpolation can't be turned
  # into an injection vector.
  @resources [
    {:solutions, "solutions", "solution_content"},
    {:memory_facts, "memory_facts", "content"}
  ]

  defstruct [
    :scan_timer_ref,
    scan_interval_ms: @default_scan_interval_seconds * 1000,
    lease_seconds: @default_lease_seconds,
    min_age_seconds: @default_min_age_seconds,
    batch_limit: @default_batch_limit,
    concurrency: @default_concurrency
  ]

  # ---------------------------------------------------------------------------
  # Client
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force a scan now, bypassing the periodic timer. Used in tests so
  the test doesn't need to wait `:scan_interval_seconds`.
  """
  @spec tick() :: :ok
  def tick do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, :tick)
    end
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      scan_interval_ms:
        Keyword.get(opts, :scan_interval_seconds, @default_scan_interval_seconds) * 1000,
      lease_seconds: Keyword.get(opts, :lease_seconds, @default_lease_seconds),
      min_age_seconds: Keyword.get(opts, :min_age_seconds, @default_min_age_seconds),
      batch_limit: Keyword.get(opts, :batch_limit, @default_batch_limit),
      concurrency: Keyword.get(opts, :concurrency, @default_concurrency)
    }

    {:ok, schedule_scan(state)}
  end

  @impl true
  def handle_info(:scan, state) do
    do_scan(state)
    {:noreply, schedule_scan(state)}
  end

  def handle_info({:hint_pending, id}, state) do
    case claim_by_id(:solutions, id, state) do
      {:ok, row} -> dispatch_async(row, state)
      :none -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:hint_pending_memory_fact, id}, state) do
    case claim_by_id(:memory_facts, id, state) do
      {:ok, row} -> dispatch_async(row, state)
      :none -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:tick, state) do
    do_scan(state)
    {:noreply, state}
  end

  defp schedule_scan(state) do
    if state.scan_timer_ref, do: Process.cancel_timer(state.scan_timer_ref)
    ref = Process.send_after(self(), :scan, state.scan_interval_ms)
    %{state | scan_timer_ref: ref}
  end

  # ---------------------------------------------------------------------------
  # Scan + claim
  # ---------------------------------------------------------------------------

  defp do_scan(state) do
    Enum.each(@resources, fn {kind, _table, _content_col} ->
      case claim_batch(kind, state) do
        [] ->
          :ok

        rows ->
          rows
          |> Task.async_stream(
            fn row -> dispatch_one(row) end,
            max_concurrency: state.concurrency,
            ordered: false,
            on_timeout: :kill_task,
            timeout: 60_000
          )
          |> Stream.run()
      end
    end)

    :ok
  end

  defp claim_batch(kind, state) do
    {^kind, table, content_col} = lookup_resource!(kind)

    sql = """
    UPDATE #{table}
       SET embedding_status = 'processing',
           embedding_next_attempt_at = now() + ($1 || ' seconds')::interval
     WHERE id IN (
       SELECT id FROM #{table}
        WHERE (
                embedding_status = 'pending'
                OR (embedding_status = 'processing' AND embedding_next_attempt_at <= now())
              )
          AND (embedding_next_attempt_at IS NULL OR embedding_next_attempt_at <= now())
          AND inserted_at < now() - ($2 || ' seconds')::interval
        ORDER BY embedding_next_attempt_at ASC NULLS FIRST
        LIMIT $3
        FOR UPDATE SKIP LOCKED
     )
     RETURNING id, tenant_id, workspace_id, #{content_col} AS content,
               embedding_attempt_count, embedding_model
    """

    params = [
      Integer.to_string(state.lease_seconds),
      Integer.to_string(state.min_age_seconds),
      state.batch_limit
    ]

    case Repo.query(sql, params) do
      {:ok, %Postgrex.Result{columns: cols, rows: rows}} ->
        Enum.map(rows, fn row ->
          row
          |> Enum.zip(cols)
          |> Enum.into(%{}, fn {v, k} -> {k, v} end)
          |> Map.put("__resource__", kind)
        end)

      _ ->
        []
    end
  end

  defp claim_by_id(kind, id, state) do
    {^kind, table, content_col} = lookup_resource!(kind)

    sql = """
    UPDATE #{table}
       SET embedding_status = 'processing',
           embedding_next_attempt_at = now() + ($2 || ' seconds')::interval
     WHERE id = $1
       AND (
             embedding_status = 'pending'
             OR (embedding_status = 'processing' AND embedding_next_attempt_at <= now())
           )
     RETURNING id, tenant_id, workspace_id, #{content_col} AS content,
               embedding_attempt_count, embedding_model
    """

    case Repo.query(sql, [Ecto.UUID.dump!(id), Integer.to_string(state.lease_seconds)]) do
      {:ok, %Postgrex.Result{columns: cols, rows: [row]}} ->
        zipped =
          row
          |> Enum.zip(cols)
          |> Enum.into(%{}, fn {v, k} -> {k, v} end)
          |> Map.put("__resource__", kind)

        {:ok, zipped}

      _ ->
        :none
    end
  end

  defp lookup_resource!(kind) do
    Enum.find(@resources, fn {k, _, _} -> k == kind end) ||
      raise "unknown resource discriminator: #{inspect(kind)}"
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  defp dispatch_async(row, state) do
    Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> dispatch_one(row) end,
      restart: :temporary
    )

    _ = state
    :ok
  end

  defp dispatch_one(row) do
    workspace_id = row["workspace_id"]
    content = row["content"]
    id = row["id"]
    kind = row["__resource__"]

    resolver = Application.get_env(:jido_claw, :policy_resolver, PolicyResolver)

    case resolver.resolve(workspace_id) do
      :disabled ->
        transition_to_disabled(kind, id)

      :local_only ->
        embed_via_local(kind, id, content)

      :default ->
        embed_via_voyage(kind, id, content)
    end
  rescue
    err ->
      Logger.warning("[BackfillWorker] dispatch crashed: #{inspect(err)}")
      :ok
  end

  defp transition_to_disabled(kind, id) do
    {^kind, table, _} = lookup_resource!(kind)

    Repo.query!(
      "UPDATE #{table} SET embedding_status = 'disabled', " <>
        "embedding_attempt_count = 0, embedding_last_error = NULL, " <>
        "embedding_next_attempt_at = NULL WHERE id = $1",
      [id]
    )

    :ok
  end

  defp embed_via_voyage(kind, id, content) do
    voyage_mod = Application.get_env(:jido_claw, :voyage_module, JidoClaw.Embeddings.Voyage)
    rate_pacer = Application.get_env(:jido_claw, :rate_pacer, JidoClaw.Embeddings.RatePacer)
    stored_model = "voyage-4-large"

    with :ok <- rate_pacer.acquire(:voyage, 1),
         :ok <- rate_pacer.try_admit("voyage", 1),
         {:ok, vector} <- voyage_mod.embed_for_storage(content, stored_model) do
      on_success(kind, id, vector, stored_model)
    else
      {:error, :timeout} -> on_failure(kind, id, :rate_limited_local)
      {:error, :budget_exhausted} -> on_failure(kind, id, :rate_limited_cluster)
      {:error, reason} -> on_failure(kind, id, reason)
    end
  end

  defp embed_via_local(kind, id, content) do
    local_mod = Application.get_env(:jido_claw, :local_module, JidoClaw.Embeddings.Local)

    model =
      Application.get_env(:jido_claw, JidoClaw.Embeddings.Local, [])[:model] ||
        "mxbai-embed-large"

    case local_mod.embed_for_storage(content) do
      {:ok, vector} -> on_success(kind, id, vector, model)
      {:error, reason} -> on_failure(kind, id, reason)
    end
  end

  defp on_success(kind, id, vector, model) do
    {^kind, table, _} = lookup_resource!(kind)

    Repo.query!(
      """
      UPDATE #{table}
         SET embedding = $2::vector,
             embedding_model = $3,
             embedding_status = 'ready',
             embedding_attempt_count = 0,
             embedding_next_attempt_at = NULL,
             embedding_last_error = NULL
       WHERE id = $1
      """,
      [id, vector, model]
    )

    :ok
  end

  defp on_failure(kind, id, reason) do
    err_str =
      case reason do
        {:rate_limited, retry_after} -> "rate_limited: retry_after=#{retry_after}"
        :rate_limited_local -> "rate_limited: per-node bucket"
        :rate_limited_cluster -> "rate_limited: cluster window"
        other -> inspect(other) |> String.slice(0, 500)
      end

    case reason do
      {:rate_limited, retry_after} when is_integer(retry_after) ->
        reschedule_without_attempt(kind, id, retry_after, err_str)

      :rate_limited_local ->
        reschedule_without_attempt(kind, id, @rate_limited_retry_seconds, err_str)

      :rate_limited_cluster ->
        reschedule_without_attempt(kind, id, @rate_limited_retry_seconds, err_str)

      _ ->
        backoff_failure(kind, id, err_str)
    end

    :ok
  end

  defp reschedule_without_attempt(kind, id, retry_after, err_str) do
    {^kind, table, _} = lookup_resource!(kind)

    Repo.query!(
      """
      UPDATE #{table}
         SET embedding_status = 'pending',
             embedding_next_attempt_at = now() + ($2 || ' seconds')::interval,
             embedding_last_error = $3
       WHERE id = $1
      """,
      [id, Integer.to_string(retry_after), err_str]
    )
  end

  @max_attempts 8

  defp backoff_failure(kind, id, err_str) do
    {^kind, table, _} = lookup_resource!(kind)

    Repo.query!(
      """
      UPDATE #{table}
         SET embedding_attempt_count = embedding_attempt_count + 1,
             embedding_last_error = $2,
             embedding_status = CASE
               WHEN embedding_attempt_count + 1 >= $3 THEN 'failed'
               ELSE 'pending'
             END,
             embedding_next_attempt_at = CASE
               WHEN embedding_attempt_count + 1 >= $3 THEN NULL
               ELSE now() + (LEAST(POWER(2, embedding_attempt_count + 1), 3600) || ' seconds')::interval
             END
       WHERE id = $1
      """,
      [id, err_str, @max_attempts]
    )
  end
end
