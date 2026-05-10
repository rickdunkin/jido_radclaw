defmodule JidoClaw.Audit.AsyncWriter do
  @moduledoc """
  Hybrid sync/async dispatcher for `Audit.Event` writes.

  * `sync/1` runs in the caller's transaction. Used by tx-bound
    producers (memory writes, solution shares, session start/end);
    a rollback in the outer action rolls the audit row back too.
  * `cast/1` runs in a Task.Supervisor child. Used by hot-path
    producers (tool-call signal listener, auth events) so audit-
    write latency doesn't gate the request. Failures are logged,
    never raised — losing an audit row is preferable to dropping
    a request.

  Both call shapes accept attrs containing `tenant_id`; the writer
  strips it from attrs and threads it via `tenant:` opt to match
  the `:attribute` multitenancy contract.
  """

  alias JidoClaw.Audit.Event
  require Logger

  @sup JidoClaw.Audit.TaskSupervisor

  @spec cast(map()) :: :ok
  def cast(attrs) when is_map(attrs) do
    case Task.Supervisor.start_child(@sup, fn ->
           safe_record(attrs, :async)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Audit.AsyncWriter] cast failed to spawn: #{inspect(reason)}")
        :ok
    end
  end

  @spec sync(map()) :: :ok
  def sync(attrs) when is_map(attrs) do
    safe_record(attrs, :sync)
    :ok
  end

  defp safe_record(attrs, mode) do
    do_record(attrs)
  rescue
    e ->
      Logger.warning(
        "[Audit.AsyncWriter] #{mode} write failed: #{Exception.message(e)} attrs=#{inspect(attrs)}"
      )
  catch
    kind, payload ->
      Logger.warning(
        "[Audit.AsyncWriter] #{mode} write #{kind}: #{inspect(payload)} attrs=#{inspect(attrs)}"
      )
  end

  defp do_record(%{tenant_id: tenant_id} = attrs) when is_binary(tenant_id) do
    attrs
    |> Map.delete(:tenant_id)
    |> Event.record(tenant: tenant_id)
    |> case do
      {:ok, _} ->
        :ok

      {:error, %Ash.Error.Invalid{} = err} ->
        Logger.debug("[Audit.AsyncWriter] write rejected: #{inspect(err)}")
        :ok

      other ->
        Logger.warning("[Audit.AsyncWriter] write returned: #{inspect(other)}")
        :ok
    end
  end

  defp do_record(attrs) do
    Logger.warning(
      "[Audit.AsyncWriter] dropping audit attrs without tenant_id: #{inspect(attrs)}"
    )

    :ok
  end
end
