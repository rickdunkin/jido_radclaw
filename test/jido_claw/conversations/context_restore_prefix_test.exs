defmodule JidoClaw.Conversations.ContextRestorePrefixTest do
  @moduledoc """
  CC2-2 system-half: the provider prompt cache keys on the system block (+
  tools array), so resume must keep the system-prompt BYTES identical:

    * `Startup.resolve_prompt/2` returns byte-identical strings for the
      saved vs reloaded Session row (frozen `prompt_snapshot` reuse — and
      `:cli_run` sessions DO get snapshots; only `:cron` skips),
    * the prompt injected on a fresh boot (P1), the prompt injected on
      resume (P2), and the restored context's `system_prompt` (C2) are
      byte-for-byte equal.
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Conversations.ContextRestore
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Conversations.Resolver, as: ConvResolver
  alias JidoClaw.Startup
  alias JidoClaw.Test.CapturingAgent
  alias JidoClaw.Workspaces.Resolver, as: WsResolver

  setup do
    tmp = Path.join(System.tmp_dir!(), "prefix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    tenant_id = seed_tenant("prefix")
    actor = actor_for(tenant_id)
    {:ok, ws} = WsResolver.ensure_workspace(tenant_id, tmp, actor: actor)

    {:ok, session} =
      ConvResolver.ensure_session(tenant_id, ws.id, :cli_run, "sess-prefix",
        actor: actor,
        project_dir: tmp
      )

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tenant_id: tenant_id, actor: actor, session: session, tmp: tmp}
  end

  test "resolve_prompt is byte-identical for the saved vs reloaded row (snapshot reuse)", ctx do
    # :cli_run sessions get a persisted frozen snapshot at creation — the
    # anchor of the whole byte-identity claim.
    assert %{"prompt_snapshot" => snap} = ctx.session.metadata
    assert is_binary(snap) and snap != ""

    {:ok, reloaded} = Session.by_id(ctx.session.id, tenant: ctx.tenant_id, actor: ctx.actor)

    p_saved = Startup.resolve_prompt(ctx.session, ctx.tmp)
    p_reloaded = Startup.resolve_prompt(reloaded, ctx.tmp)

    assert p_saved == snap
    assert p_reloaded == snap

    # build_context/2 carries those exact bytes into the restored context.
    built = ContextRestore.build_context([], p_reloaded)
    assert built.system_prompt == snap
  end

  test "injected prompt (fresh) == injected prompt (resume) == restored context prompt", ctx do
    {:ok, _} =
      Message.append(
        %{session_id: ctx.session.id, role: :user, content: "hello", request_id: "req-p"},
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    # Fresh boot: P1.
    {:ok, fresh_pid} = CapturingAgent.start_link(self())
    assert :ok = Startup.inject_system_prompt(fresh_pid, ctx.tmp, ctx.session)
    assert_receive {:injected_prompt, p1}, 2_000

    # Resume against a reloaded row and a new agent process: P2, then the
    # restore payload's system prompt: C2.
    {:ok, reloaded} = Session.by_id(ctx.session.id, tenant: ctx.tenant_id, actor: ctx.actor)
    {:ok, resumed_pid} = CapturingAgent.start_link(self())

    assert :ok = Startup.inject_system_prompt(resumed_pid, ctx.tmp, reloaded)
    assert_receive {:injected_prompt, p2}, 2_000

    assert :ok = ContextRestore.restore(resumed_pid, reloaded, ctx.tmp, actor: ctx.actor)
    assert_receive {:context_modify, %{operation: op}}, 2_000
    c2 = op.result_context.system_prompt

    assert p1 == p2
    assert p2 == c2
  end
end
