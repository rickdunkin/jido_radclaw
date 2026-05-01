defmodule JidoClaw.Embeddings.BackfillWorkerTest do
  @moduledoc """
  Regression coverage for `BackfillWorker` (Findings 3 & 4 wiring).

  Locks in:

    * `:disabled` workspaces transition rows to `embedding_status:
      :disabled` and never call the Voyage stub.
    * The Voyage dispatch path is gated by `RatePacer.acquire/2` and
      `try_admit/2`. When either rejects, the row is rescheduled
      with `embedding_attempt_count` unchanged (rate-limited by the
      operator's own backpressure, not the row's intrinsic problem).

  Uses the application-supervised BackfillWorker — the test does not
  spawn its own. Instead it injects test-specific module overrides via
  `Application.put_env/3` (the BackfillWorker reads them on each
  dispatch) and seeds rows through raw SQL so the resource's
  `ResolveInitialEmbeddingStatus` change can't auto-stamp them at
  create time.
  """

  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Embeddings.BackfillWorker
  alias JidoClaw.Repo

  defmodule SpyVoyage do
    @moduledoc false
    def embed_for_storage(_content, _model) do
      pid = :persistent_term.get({__MODULE__, :test_pid}, nil)
      if pid, do: send(pid, :voyage_called)
      {:ok, List.duplicate(0.01, 1024)}
    end

    def install(pid), do: :persistent_term.put({__MODULE__, :test_pid}, pid)
    def uninstall, do: :persistent_term.erase({__MODULE__, :test_pid})
  end

  defmodule LocalRateLimit do
    @moduledoc false
    def acquire(_, _), do: {:error, :timeout}
    def try_admit(_, _), do: :ok
  end

  defmodule ClusterRateLimit do
    @moduledoc false
    def acquire(_, _), do: :ok
    def try_admit(_, _), do: {:error, :budget_exhausted}
  end

  defmodule PassRatePacer do
    @moduledoc false
    def acquire(_, _), do: :ok
    def try_admit(_, _), do: :ok
  end

  setup do
    SpyVoyage.install(self())

    on_exit(fn ->
      SpyVoyage.uninstall()
      Application.delete_env(:jido_claw, :voyage_module)
      Application.delete_env(:jido_claw, :rate_pacer)
      Application.delete_env(:jido_claw, :policy_resolver)
    end)

    Application.put_env(:jido_claw, :voyage_module, SpyVoyage)

    {:ok, tenant_id: unique_tenant_id()}
  end

  describe ":disabled workspace path (Fix 3 wiring)" do
    test "rows in a :disabled workspace transition to :disabled and skip Voyage",
         %{tenant_id: tenant_id} do
      Application.put_env(:jido_claw, :rate_pacer, PassRatePacer)

      ws = workspace_fixture(tenant_id, embedding_policy: :disabled)
      id = insert_pending_solution(tenant_id, ws.id, "anything")

      run_one_dispatch(id)

      refute_received :voyage_called
      assert column(id, "embedding_status") == "disabled"
    end
  end

  describe "rate-limited paths (Fix 4 wiring)" do
    test "RatePacer.acquire/2 rejection reschedules WITHOUT consuming an attempt",
         %{tenant_id: tenant_id} do
      Application.put_env(:jido_claw, :rate_pacer, LocalRateLimit)

      ws = workspace_fixture(tenant_id, embedding_policy: :default)
      id = insert_pending_solution(tenant_id, ws.id, "anything-content")

      run_one_dispatch(id)

      refute_received :voyage_called
      assert column(id, "embedding_status") == "pending"
      assert column(id, "embedding_attempt_count") == 0
      assert column(id, "embedding_last_error") =~ "rate_limited"
    end

    test "RatePacer.try_admit/2 rejection reschedules WITHOUT consuming an attempt",
         %{tenant_id: tenant_id} do
      Application.put_env(:jido_claw, :rate_pacer, ClusterRateLimit)

      ws = workspace_fixture(tenant_id, embedding_policy: :default)
      id = insert_pending_solution(tenant_id, ws.id, "anything-cluster")

      run_one_dispatch(id)

      refute_received :voyage_called
      assert column(id, "embedding_status") == "pending"
      assert column(id, "embedding_attempt_count") == 0
      assert column(id, "embedding_last_error") =~ "rate_limited"
    end

    test "fully-clear path actually invokes Voyage", %{tenant_id: tenant_id} do
      Application.put_env(:jido_claw, :rate_pacer, PassRatePacer)

      ws = workspace_fixture(tenant_id, embedding_policy: :default)
      id = insert_pending_solution(tenant_id, ws.id, "anything-clear")

      run_one_dispatch(id)

      assert_received :voyage_called
      assert column(id, "embedding_status") == "ready"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_pending_solution(tenant_id, workspace_id, content) do
    id = Ecto.UUID.generate()
    sig = "sig-#{System.unique_integer([:positive])}"

    Repo.query!(
      """
      INSERT INTO solutions
        (id, tenant_id, workspace_id, problem_signature, solution_content,
         language, sharing, tags, verification, trust_score, embedding_status,
         embedding_attempt_count, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, 'elixir', 'local', '{}', '{}'::jsonb, 0.0,
              'pending', 0, now() - interval '1 hour', now())
      """,
      [Ecto.UUID.dump!(id), tenant_id, Ecto.UUID.dump!(workspace_id), sig, content]
    )

    id
  end

  # Trigger the worker to scan + dispatch, then wait for the cast to
  # finish. `:sys.get_state/1` is a synchronous call so it queues
  # behind the cast that we just sent — when it returns, do_scan/1
  # (and its inline Stream.run wait on the dispatch tasks) is done.
  # Mailbox lookups (refute_received / column/2) after this are safe.
  defp run_one_dispatch(_id) do
    BackfillWorker.tick()
    _ = :sys.get_state(BackfillWorker)
    :ok
  end

  defp column(id, name) do
    %Postgrex.Result{rows: [[value]]} =
      Repo.query!("SELECT #{name} FROM solutions WHERE id = $1", [Ecto.UUID.dump!(id)])

    value
  end
end
