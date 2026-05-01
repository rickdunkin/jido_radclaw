defmodule JidoClaw.Embeddings.PolicyResolverTest do
  @moduledoc """
  Regression coverage for `PolicyResolver` (Decisions 2 & 3).

  Locks in:

    * Fail-closed: missing/unreadable/malformed workspace UUID maps
      to `:disabled` rather than `:default`.
    * `model_for_query/1` returns distinct request and stored model
      strings for `:default` (Voyage), so the request hits `voyage-4`
      while the stored-side filter pins `voyage-4-large`.
    * Raw 16-byte binary UUIDs (the form `BackfillWorker.dispatch_one/1`
      sees off the SQL claim) round-trip through `resolve/1`.
  """

  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Embeddings.PolicyResolver

  setup do
    {:ok, tenant_id: unique_tenant_id()}
  end

  describe "resolve/1 — fail-closed semantics" do
    test "missing workspace returns :disabled (NOT :default)" do
      missing = Ecto.UUID.generate()
      assert PolicyResolver.resolve(missing) == :disabled
    end

    test "nil workspace_id returns :disabled" do
      assert PolicyResolver.resolve(nil) == :disabled
    end

    test "malformed UUID string returns :disabled" do
      assert PolicyResolver.resolve("not-a-uuid") == :disabled
    end
  end

  describe "resolve/1 — happy paths" do
    test "explicit :disabled workspace returns :disabled", %{tenant_id: tenant_id} do
      ws = workspace_fixture(tenant_id, embedding_policy: :disabled)
      assert PolicyResolver.resolve(ws.id) == :disabled
    end

    test ":local_only workspace returns :local_only", %{tenant_id: tenant_id} do
      ws = workspace_fixture(tenant_id, embedding_policy: :local_only)
      assert PolicyResolver.resolve(ws.id) == :local_only
    end

    test ":default workspace returns :default", %{tenant_id: tenant_id} do
      ws = workspace_fixture(tenant_id, embedding_policy: :default)
      assert PolicyResolver.resolve(ws.id) == :default
    end

    test "accepts raw 16-byte binary UUIDs (BackfillWorker form)",
         %{tenant_id: tenant_id} do
      ws = workspace_fixture(tenant_id, embedding_policy: :default)
      {:ok, raw} = Ecto.UUID.dump(ws.id)
      assert PolicyResolver.resolve(raw) == :default
    end
  end

  describe "model_for_query/1" do
    test ":default — Voyage with distinct request_model and stored_model" do
      assert %{provider: :voyage, request_model: "voyage-4", stored_model: "voyage-4-large"} =
               PolicyResolver.model_for_query(:default)
    end

    test ":local_only — Local with shared model on both sides" do
      assert %{provider: :local, request_model: model, stored_model: model} =
               PolicyResolver.model_for_query(:local_only)

      assert is_binary(model)
    end

    test ":disabled passes through" do
      assert PolicyResolver.model_for_query(:disabled) == :disabled
    end
  end

  describe "model_for_storage/1" do
    test ":default — Voyage uses voyage-4-large for both request and stored" do
      assert %{provider: :voyage, request_model: "voyage-4-large", stored_model: "voyage-4-large"} =
               PolicyResolver.model_for_storage(:default)
    end

    test ":local_only mirrors local model for both sides" do
      assert %{provider: :local, request_model: model, stored_model: model} =
               PolicyResolver.model_for_storage(:local_only)

      assert is_binary(model)
    end

    test ":disabled passes through" do
      assert PolicyResolver.model_for_storage(:disabled) == :disabled
    end
  end
end
