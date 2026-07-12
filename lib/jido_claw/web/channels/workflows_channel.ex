defmodule JidoClaw.Web.WorkflowsChannel do
  @moduledoc """
  Read-only per-run lifecycle topic for the argus SPA:
  `workflows:run:<uuid>`, joined over `JidoClaw.Web.ArgusSocket` only.

  Minimal-payload posture (argus OVERVIEW §4.2): pushes `run_event`
  frames of `%{id, kind}` — id bound to the *authorized* run, kind from
  the lifecycle allowlist — and the client refetches via GraphQL. The
  broadcast `info` map is never forwarded. The join reply carries the
  authoritative `%{id, status}` (lowercase-snake wire casing) so the
  client can reconcile anything that happened between its list fetch and
  the join.

  Join is canonicalize → subscribe → authorize:

    1. `Ecto.UUID.cast/1` FIRST — an uppercase UUID would otherwise
       authorize via Ash cast but subscribe to a differently-cased topic
       and hear nothing.
    2. `RunPubSub.subscribe/1` BEFORE the authorizing read — a terminal
       landing between read and subscribe would be lost, and a refused
       join kills the channel process (its subscription with it).
    3. `WorkflowRun.by_id/2` under the caller's tenant + actor — the read
       policy folds tenant match + active-tenant EXISTS, so cross-tenant,
       suspended-tenant, and nonexistent ids all map to one uniform
       `"not_found"` (no oracle); infra failures are `"unavailable"`.
  """
  use Phoenix.Channel

  alias JidoClaw.Core.AshErrors
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowRun

  # Exact inventory of lifecycle kinds riding `orchestration:run:<id>`
  # (reactor_middleware, reactor_runner, cancellation, cases,
  # gate_disposition, route_composer — composer terminals broadcast their
  # status FAMILY kind, never a `route_*` kind). Sourced from the producers'
  # own module so the allowlist can't drift; everything else on the topic is
  # dropped.
  @lifecycle_kinds RunPubSub.lifecycle_kinds()

  @impl Phoenix.Channel
  def join("workflows:run:" <> raw_id, _payload, socket) do
    case socket.assigns[:current_actor] do
      %{tenant_id: tenant_id} = actor when is_binary(tenant_id) and byte_size(tenant_id) > 0 ->
        join_run(raw_id, tenant_id, actor, socket)

      _missing_or_malformed ->
        {:error, %{reason: "not_found"}}
    end
  end

  # Explicit reject (rpc_channel.ex precedent): a missing clause would crash
  # the join with a FunctionClauseError instead of this clean error.
  def join("workflows:" <> _topic, _payload, _socket) do
    {:error, %{reason: "unauthorized topic"}}
  end

  @impl Phoenix.Channel
  def handle_info({kind, run_id, _info}, %{assigns: %{run_id: run_id}} = socket)
      when kind in @lifecycle_kinds do
    push(socket, "run_event", %{id: run_id, kind: kind})
    {:noreply, socket}
  end

  # Unknown kinds AND mismatched tuple ids are dropped, never forwarded.
  def handle_info(_message, socket), do: {:noreply, socket}

  @doc false
  # Not-found (bare or Invalid-wrapped) means "gone" — uniform not_found;
  # anything else is a real read failure (infra ≠ absence). Public for
  # direct unit coverage.
  @spec read_error_reason(term()) :: String.t()
  def read_error_reason(reason) do
    if AshErrors.not_found_error?(reason), do: "not_found", else: "unavailable"
  end

  defp join_run(raw_id, tenant_id, actor, socket) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, canonical_id} -> subscribe_then_authorize(canonical_id, tenant_id, actor, socket)
      :error -> {:error, %{reason: "not_found"}}
    end
  end

  defp subscribe_then_authorize(canonical_id, tenant_id, actor, socket) do
    case RunPubSub.subscribe(canonical_id) do
      :ok -> authorize_run(canonical_id, tenant_id, actor, socket)
      {:error, _reason} -> {:error, %{reason: "unavailable"}}
    end
  end

  defp authorize_run(canonical_id, tenant_id, actor, socket) do
    case WorkflowRun.by_id(canonical_id, tenant: tenant_id, actor: actor) do
      {:ok, run} ->
        {:ok, %{id: run.id, status: to_string(run.status)}, assign(socket, :run_id, run.id)}

      {:error, reason} ->
        {:error, %{reason: read_error_reason(reason)}}
    end
  end
end
