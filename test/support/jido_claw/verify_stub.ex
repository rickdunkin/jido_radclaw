defmodule JidoClaw.Test.VerifyStub do
  @moduledoc """
  The hermetic `:verify` runner + git seam for tests (item 5) — wired in via
  `config :jido_claw, :verify, runner:/git:` (test.exs), so a full-catalog
  composer launch never spawns a subprocess or touches real git.

  Unscripted defaults are a **certified green**: every check exits 0 and the
  git captures are stable (`head`/`tree_digest` constant, porcelain clean), so
  an incidental verify stage in an unrelated e2e converges. Tests script it
  via the `:route_composer_verify_stub` app env map:

    * `results: [{exit | :output_limit, log_tail}]` — counter-driven per
      runner call (the `SystemLoopWorker` pattern; the last entry repeats once
      exhausted);
    * `head:` / `porcelain:` / `diff_digest:` — a static value, an explicit
      `nil` (a capture failure — present-nil is deliberate here), or a LIST
      consumed per call (mid-verify tamper scripts).

  Counters live in `JidoClaw.RouteComposer.TestSupport.StubStore` — call
  `StubStore.setup()` in the test setup so the table is test-owned and every
  counter starts fresh.
  """

  alias JidoClaw.RouteComposer.TestSupport.StubStore

  @spec run(map(), String.t()) :: {integer() | :output_limit, binary()}
  def run(_check, _repo) do
    case Map.get(script(), :results) do
      [_ | _] = results ->
        n = StubStore.bump(:verify_stub_runner_calls)
        Enum.at(results, min(n, length(results)) - 1)

      _unscripted ->
        {0, ""}
    end
  end

  @spec head(String.t()) :: String.t() | nil
  def head(_repo), do: scripted(:head, "verifystubhead", :verify_stub_head_calls)

  @spec porcelain(String.t()) :: String.t() | nil
  def porcelain(_repo), do: scripted(:porcelain, "", :verify_stub_porcelain_calls)

  @spec diff_digest(String.t()) :: String.t() | nil
  def diff_digest(_repo),
    do: scripted(:diff_digest, "verifystubdigest", :verify_stub_digest_calls)

  # `Map.fetch` (not `Map.get`) so a PRESENT nil scripts a capture failure —
  # the one place present-nil is the point, not the trap.
  defp scripted(key, default, counter) do
    case Map.fetch(script(), key) do
      :error ->
        default

      {:ok, values} when is_list(values) ->
        n = StubStore.bump(counter)
        Enum.at(values, min(n, length(values)) - 1)

      {:ok, value} ->
        value
    end
  end

  defp script, do: Application.get_env(:jido_claw, :route_composer_verify_stub, %{})
end
