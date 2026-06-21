defmodule JidoClaw.Triage do
  @moduledoc """
  AR-8 triage (AR-2 §8/§14): the always-on classifier the front door consults on
  every user turn to pick exactly one *path* — `talk` / `sketch` / `code` /
  `system` — plus advisory early signals.

  This module is the **behaviour** and the **façade**. The default impl
  (`JidoClaw.Triage.LLM`) makes one `Jido.AI.generate_object/3` call; a test injects
  a stub via `config :jido_claw, :triage_impl` (the `:ask_runtime` seam idiom).

  `classify/2` is the **single fail-safe boundary**: it coerces *any* impl
  `{:error, _}`, non-`Verdict` return, raise, or throw/exit into `{:ok, talk}` —
  so `JidoClaw.FrontDoor.decide/2` can hard-match `{:ok, %Verdict{}}` and no impl
  can crash a turn. Because it is the only layer that both *times* the call and
  knows whether it had to *coerce*, it is also the **single telemetry point**:
  it emits `[:jido_claw, :triage, :classified]` and the `jido_claw.triage.classified`
  signal with the path, model, duration, and `fallback?` (the fail-safe rate —
  which therefore *counts* LLM failures rather than hiding them as a normal `talk`).
  """

  alias JidoClaw.Triage.Verdict

  @callback classify(String.t(), keyword()) :: {:ok, Verdict.t()} | {:error, term()}

  @doc """
  Classify `message` (with optional `:history`), always returning `{:ok, %Verdict{}}`.

  Any impl failure (`{:error, _}`, a non-`Verdict` value, a raise, or a
  throw/exit) is coerced to `{:ok, Verdict.talk()}` and recorded as
  `fallback?: true`. A genuine `{:ok, %Verdict{path: :talk}}` is *not* a fallback.
  """
  @spec classify(String.t(), keyword()) :: {:ok, Verdict.t()}
  def classify(message, opts \\ []) when is_binary(message) do
    start = System.monotonic_time()

    {verdict, fallback?} =
      try do
        case impl().classify(message, opts) do
          {:ok, %Verdict{} = verdict} -> {verdict, false}
          _other -> {Verdict.talk(), true}
        end
      rescue
        # reach:disable-next-line bare_rescue
        _ -> {Verdict.talk(), true}
      catch
        # Covers :throw and :exit (a thrown value or an exit from any impl must
        # not crash the turn). R6-P3.
        _kind, _reason -> {Verdict.talk(), true}
      end

    emit_telemetry(verdict.path, fallback?, ms_since(start))
    {:ok, verdict}
  end

  defp emit_telemetry(path, fallback?, duration_ms) do
    model = triage_model()

    :telemetry.execute(
      [:jido_claw, :triage, :classified],
      %{duration_ms: duration_ms},
      %{path: path, fallback?: fallback?, model: model}
    )

    JidoClaw.SignalBus.emit("jido_claw.triage.classified", %{
      path: to_string(path),
      fallback?: fallback?,
      model: model_label(model),
      duration_ms: duration_ms
    })

    :ok
  end

  defp impl, do: Application.get_env(:jido_claw, :triage_impl, JidoClaw.Triage.LLM)

  # The configured model tier — shared with `Triage.LLM.resolve_model/0`; useful
  # in telemetry even when a stub impl is active in tests.
  defp triage_model, do: Application.get_env(:jido_claw, :triage_model, :fast)

  defp model_label(model) when is_atom(model), do: to_string(model)
  defp model_label(model) when is_binary(model), do: model
  defp model_label(model), do: inspect(model)

  defp ms_since(start) do
    System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
  end
end
