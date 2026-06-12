defmodule JidoClaw.Tools.OutputShaper.Store do
  @moduledoc """
  Best-effort persistence seam between `JidoClaw.Tools.OutputShaper` and
  `JidoClaw.Conversations.ToolOutput`.

  Storage must never block a tool result: every entry point is fully
  rescued and degrades to `:error` / `:none`. Tenant absence is handled
  **upstream** as an OutputShaper pass-through guard, so `put/2` only
  runs when storage is possible — a missing tenant here is a defensive
  `:error`, not an expected path.

  The `command` attribute is redacted with
  `JidoClaw.Security.Redaction.Patterns.redact/1` before insert (tool
  params never pass through result redaction, so a secret-bearing
  command would otherwise land in the DB verbatim). The fingerprint is
  computed on the **raw** command before redaction, keeping fingerprints
  stable across redaction-pattern changes.
  """

  # Best-effort persistence seam: a storage fault of ANY kind degrades to
  # `:error`/`:none` instead of crashing the tool result, so the rescues
  # are deliberately catch-all (same boundary contract as MCPScope).
  # reach:disable-for-this-file bare_rescue

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.ToolOutput
  alias JidoClaw.Security.Redaction.Patterns
  alias JidoClaw.Tools.OutputShaper

  @prune_batch 500

  @doc """
  Store a captured tool output, returning `{:ok, ref}` or `:error`.

  `attrs` carries `:tool`, `:content`, `:byte_size`, `:truncated`, and
  optionally `:command` (raw — redacted here), `:exit_code`, `:summary`.
  `tool_context` supplies tenant/actor/session scope. After a successful
  insert, rows older than the configured TTL are pruned best-effort for
  this tenant.
  """
  @spec put(map(), map()) :: {:ok, String.t()} | :error
  def put(attrs, tool_context) when is_map(attrs) and is_map(tool_context) do
    case Map.get(tool_context, :tenant_id) do
      tenant_id when is_binary(tenant_id) and tenant_id != "" ->
        do_put(attrs, tenant_id, tool_context)

      _ ->
        Logger.warning("[OutputShaper.Store] put without tenant_id — refusing to store")
        :error
    end
  rescue
    e ->
      Logger.warning("[OutputShaper.Store] store raised: #{Exception.message(e)}")
      emit_error(attrs, e)
      :error
  end

  @doc """
  Latest stored row for `(session, fingerprint, tool)` — the
  previous-run delta lookup. Returns `:none` on any miss or failure.
  """
  @spec latest_for_fingerprint(String.t(), String.t(), String.t(), map()) ::
          {:ok, ToolOutput.t()} | :none
  def latest_for_fingerprint(session_uuid, fingerprint, tool, tool_context)
      when is_binary(session_uuid) and is_binary(fingerprint) and is_binary(tool) and
             is_map(tool_context) do
    case Map.get(tool_context, :tenant_id) do
      tenant_id when is_binary(tenant_id) and tenant_id != "" ->
        actor = Map.get(tool_context, :actor) || Actor.system(tenant_id)

        case ToolOutput.latest_for_fingerprint(session_uuid, fingerprint, tool,
               tenant: tenant_id,
               actor: actor
             ) do
          {:ok, row} -> {:ok, row}
          _ -> :none
        end

      _ ->
        :none
    end
  rescue
    _ -> :none
  end

  def latest_for_fingerprint(_, _, _, _), do: :none

  @doc """
  Stable fingerprint of a command string: sha256 over the
  downcased/trimmed/whitespace-collapsed text. Computed on the raw
  command (before redaction) so historical rows stay comparable.
  """
  @spec fingerprint(String.t() | nil) :: String.t() | nil
  def fingerprint(nil), do: nil

  def fingerprint(command) when is_binary(command) do
    normalized =
      command
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    :sha256
    |> :crypto.hash(normalized)
    |> Base.encode16(case: :lower)
  end

  # -- Private ----------------------------------------------------------------

  defp do_put(attrs, tenant_id, tool_context) do
    actor = Map.get(tool_context, :actor) || Actor.system(tenant_id)
    raw_command = Map.get(attrs, :command)

    insert_attrs =
      attrs
      |> Map.put(:command, redact_command(raw_command))
      |> Map.put(:command_fingerprint, fingerprint(raw_command))
      |> Map.put(:session_id, Map.get(tool_context, :session_uuid))
      |> Map.put(:ref, generate_ref())

    case insert(insert_attrs, tenant_id, actor) do
      {:ok, ref} ->
        prune(tenant_id, actor)
        {:ok, ref}

      :error ->
        # One retry with a fresh ref covers a random-collision unique
        # violation; a second failure is a real storage fault.
        case insert(Map.put(insert_attrs, :ref, generate_ref()), tenant_id, actor) do
          {:ok, ref} ->
            prune(tenant_id, actor)
            {:ok, ref}

          :error ->
            emit_error(attrs, :insert_failed)
            :error
        end
    end
  end

  defp insert(attrs, tenant_id, actor) do
    case ToolOutput.store(attrs, tenant: tenant_id, actor: actor) do
      {:ok, %{ref: ref}} ->
        {:ok, ref}

      {:error, reason} ->
        Logger.warning("[OutputShaper.Store] insert failed: #{inspect(reason)}")
        :error
    end
  end

  defp redact_command(nil), do: nil
  defp redact_command(command) when is_binary(command), do: Patterns.redact(command)

  defp generate_ref do
    "out_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  # Best-effort prune-on-insert: delete rows older than the configured
  # TTL for this tenant. Fully rescued — a prune failure never fails
  # the store that triggered it.
  defp prune(tenant_id, actor) do
    ttl_days = OutputShaper.ref_ttl_days()
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_days * 86_400, :second)

    case ToolOutput.expired(cutoff,
           tenant: tenant_id,
           actor: actor,
           query: [limit: @prune_batch]
         ) do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        _ = Ash.bulk_destroy(rows, :destroy, %{}, tenant: tenant_id, actor: actor)
        :ok

      {:error, reason} ->
        Logger.warning("[OutputShaper.Store] prune read failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[OutputShaper.Store] prune raised: #{Exception.message(e)}")
      :ok
  end

  defp emit_error(attrs, reason) do
    JidoClaw.Trace.emit(
      :output,
      %{
        event: :error,
        name: Map.get(attrs, :tool) || "output_shaper",
        stage: :store,
        reason: inspect(reason)
      },
      %{system_time: System.system_time()}
    )
  rescue
    _ -> :ok
  end
end
