defmodule JidoClaw.Reasoning.Compactor.Telemetry do
  @moduledoc """
  Telemetry wrapper for compaction runs.

  `with_compaction/4` runs `fun` between two `JidoClaw.Trace.emit(:compaction, ...)`
  calls. Mirrors the shape of `JidoClaw.Reasoning.Telemetry.with_outcome/4` —
  start + exactly one terminal event (`:summarized` / `:skipped` / `:error`),
  with `duration_ms` measurements.

  The `:compaction` category is pre-wired in the Trace collector
  (`event_name_label/2` reads `metadata[:compaction] || metadata[:name]`;
  `:summarized` and `:skipped` both map to status `:completed`).

  The wrapped fun is expected to return one of:

    * `{:ok, :summarized, %Snapshot{}, measurements_map}`
    * `{:ok, :skipped, snapshot_or_nil, %{reason: atom()}}`
    * `{:error, term()}`

  Unhandled exceptions and exits are caught and converted to an `:error`
  terminal event; the wrapper re-raises the original exception so callers can
  still pattern-match on it if they want, but typical callers (best-effort
  compaction in `maybe_compact/3`) catch with `try/rescue` themselves.
  """

  require Logger

  @type metadata :: %{optional(atom()) => term()}

  @type fun_result ::
          {:ok, :summarized, term(), metadata()}
          | {:ok, :skipped, term(), metadata()}
          | {:error, term()}

  @doc """
  Run `fun` with start + terminal compaction telemetry.

  `name` is a short label (e.g. `"summary"`) that ends up in
  `metadata[:compaction]` and `metadata[:name]`. `base_metadata` is merged
  into both the start and terminal event metadata.
  """
  @spec with_compaction(String.t(), metadata(), (-> fun_result()), keyword()) ::
          fun_result()
  def with_compaction(name, base_metadata, fun, _opts \\ [])
      when is_binary(name) and is_map(base_metadata) and is_function(fun, 0) do
    started_mono = System.monotonic_time()

    :ok =
      JidoClaw.Trace.emit(
        :compaction,
        Map.merge(base_metadata, %{
          event: :start,
          phase: :compaction,
          name: name,
          compaction: name
        }),
        %{system_time: System.system_time()}
      )

    result =
      try do
        fun.()
      rescue
        e ->
          Logger.debug("[Compactor.Telemetry] compaction #{name} raised: #{Exception.message(e)}")
          duration_ms = elapsed_ms(started_mono)
          emit_error(name, base_metadata, duration_ms, e)
          reraise e, __STACKTRACE__
      catch
        :exit, reason ->
          Logger.debug("[Compactor.Telemetry] compaction #{name} exited: #{inspect(reason)}")
          {:caught_exit, reason}
      end

    duration_ms = elapsed_ms(started_mono)

    case result do
      {:ok, :summarized, _snapshot, extras} = ok ->
        emit_terminal(:summarized, name, base_metadata, duration_ms, extras)
        ok

      {:ok, :skipped, _snapshot, extras} = ok ->
        emit_terminal(:skipped, name, base_metadata, duration_ms, extras)
        ok

      {:error, reason} = err ->
        emit_error(name, base_metadata, duration_ms, reason)
        err

      {:caught_exit, reason} ->
        emit_error(name, base_metadata, duration_ms, reason)
        {:error, reason}
    end
  end

  defp emit_terminal(event, name, base_metadata, duration_ms, extras)
       when event in [:summarized, :skipped] do
    metadata =
      base_metadata
      |> Map.merge(extras_for_metadata(extras))
      |> Map.merge(%{
        event: event,
        phase: :compaction,
        name: name,
        compaction: name,
        status: event
      })

    :ok = JidoClaw.Trace.emit(:compaction, metadata, %{duration_ms: duration_ms})
  end

  defp emit_error(name, base_metadata, duration_ms, reason) do
    metadata =
      base_metadata
      |> Map.merge(%{
        event: :error,
        phase: :compaction,
        name: name,
        compaction: name,
        status: :error,
        reason: inspect(reason)
      })

    :ok = JidoClaw.Trace.emit(:compaction, metadata, %{duration_ms: duration_ms})
  end

  defp extras_for_metadata(extras) when is_map(extras), do: extras
  defp extras_for_metadata(_), do: %{}

  defp elapsed_ms(started_mono) do
    System.convert_time_unit(System.monotonic_time() - started_mono, :native, :millisecond)
  end
end
