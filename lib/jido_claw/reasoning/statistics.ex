defmodule JidoClaw.Reasoning.Statistics do
  @moduledoc """
  Aggregate query scaffold over `reasoning_outcomes`.

  0.4.1 ships the queries and the `execution_kind` filter plumbing that lets
  `:strategy_run` rows be analyzed separately from certificate-verification
  and react-stub rows added in later phases. 0.4.3 wires the output of
  `best_strategies_for/2` into `Classifier.recommend/2`.

  Queries go through `Ecto` directly (not Ash) to use `GROUP BY` — Ash's
  aggregate API can be layered on later if we need composable filters.
  """

  import Ecto.Query

  @doc """
  Return the top-performing strategies for a given task type, ordered by
  success rate (descending) then sample count (descending).

  Options:
    * `:execution_kind` — `:strategy_run` (default) or `:all` to include
      every row regardless of kind. Specific atoms work too.
    * `:since` — only include rows with `started_at >= since`.
    * `:limit` — cap the number of strategies returned (default 10).
  """
  @spec best_strategies_for(atom(), keyword()) :: [
          %{
            strategy: String.t(),
            success_rate: float(),
            avg_duration_ms: float(),
            samples: integer()
          }
        ]
  def best_strategies_for(task_type, opts \\ []) when is_atom(task_type) do
    execution_kind = Keyword.get(opts, :execution_kind, :strategy_run)
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit, 10)

    query =
      from(o in "reasoning_outcomes",
        where: o.task_type == ^Atom.to_string(task_type),
        group_by: o.strategy,
        select: %{
          strategy: o.strategy,
          samples: count(o.id),
          ok_count: fragment("SUM(CASE WHEN ? = 'ok' THEN 1 ELSE 0 END)", o.status),
          avg_duration_ms: avg(o.duration_ms)
        }
      )
      |> maybe_filter_execution_kind(execution_kind)
      |> maybe_filter_since(since)

    rows = JidoClaw.Repo.all(query)

    rows
    |> Enum.map(fn row ->
      samples = row.samples
      ok = row.ok_count || 0
      success = if samples > 0, do: ok / samples, else: 0.0

      %{
        strategy: row.strategy,
        samples: samples,
        success_rate: success * 1.0,
        avg_duration_ms: avg_to_float(row.avg_duration_ms)
      }
    end)
    |> Enum.sort_by(fn %{success_rate: sr, samples: n} -> {-sr, -n} end)
    |> Enum.take(limit)
  end

  @doc """
  Cross-task summary of strategy usage. Returns per-strategy and per-task-type
  rollups for dashboard-style consumers (e.g. the `/strategies stats` REPL
  command).

  Per-strategy rows:
    `%{strategy, samples, success_rate, avg_duration_ms}`, sorted by
    `success_rate desc, samples desc`.

  Per-task-type rows:
    `%{task_type, samples, success_rate}`, sorted by `samples desc`.
  """
  @spec summary(keyword()) :: %{strategies: [map()], task_types: [map()]}
  def summary(opts \\ []) do
    execution_kind = Keyword.get(opts, :execution_kind, :strategy_run)

    strategies_query =
      from(o in "reasoning_outcomes",
        group_by: o.strategy,
        select: %{
          strategy: o.strategy,
          samples: count(o.id),
          ok_count: fragment("SUM(CASE WHEN ? = 'ok' THEN 1 ELSE 0 END)", o.status),
          avg_duration_ms: avg(o.duration_ms)
        }
      )
      |> maybe_filter_execution_kind(execution_kind)

    task_types_query =
      from(o in "reasoning_outcomes",
        group_by: o.task_type,
        select: %{
          task_type: o.task_type,
          samples: count(o.id),
          ok_count: fragment("SUM(CASE WHEN ? = 'ok' THEN 1 ELSE 0 END)", o.status)
        }
      )
      |> maybe_filter_execution_kind(execution_kind)

    strategies =
      JidoClaw.Repo.all(strategies_query)
      |> Enum.map(fn row ->
        samples = row.samples
        ok = row.ok_count || 0

        %{
          strategy: row.strategy,
          samples: samples,
          success_rate: success_rate(ok, samples),
          avg_duration_ms: avg_to_float(row.avg_duration_ms)
        }
      end)
      |> Enum.sort_by(fn %{success_rate: sr, samples: n} -> {-sr, -n} end)

    task_types =
      JidoClaw.Repo.all(task_types_query)
      |> Enum.map(fn row ->
        samples = row.samples
        ok = row.ok_count || 0

        %{
          task_type: row.task_type,
          samples: samples,
          success_rate: success_rate(ok, samples)
        }
      end)
      |> Enum.sort_by(fn %{samples: n} -> -n end)

    %{strategies: strategies, task_types: task_types}
  end

  defp success_rate(_ok, 0), do: 0.0
  defp success_rate(ok, samples), do: ok / samples * 1.0

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp maybe_filter_execution_kind(query, :all), do: query

  defp maybe_filter_execution_kind(query, kind) when is_atom(kind) do
    from(o in query, where: o.execution_kind == ^Atom.to_string(kind))
  end

  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, %DateTime{} = since) do
    from(o in query, where: o.started_at >= ^since)
  end

  defp avg_to_float(nil), do: 0.0
  defp avg_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp avg_to_float(n) when is_number(n), do: n * 1.0
end
