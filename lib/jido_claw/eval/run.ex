defmodule JidoClaw.Eval.Run do
  @moduledoc """
  Result of running a `JidoClaw.Eval.Case` (the `Jidoka.Eval.Run` shape,
  adapted): the case's id/kind, an overall `status`, the per-kind execution
  `result` (or the normalized `error` map when execution failed), the
  evaluated assertion records, and per-kind `observations`.

  Each assertion record is
  `%{name: atom, status: :passed | :failed, expected: term, actual: term}`
  (`expected`/`actual` optional).
  """

  alias JidoClaw.Eval.Case, as: EvalCase

  @statuses [:passed, :failed, :error]

  @enforce_keys [:case_id, :kind, :status]
  defstruct [
    :case_id,
    :kind,
    :status,
    :result,
    :error,
    assertions: [],
    observations: %{},
    metadata: %{}
  ]

  @type status :: :passed | :failed | :error
  @type assertion :: %{
          required(:name) => atom(),
          required(:status) => :passed | :failed,
          optional(:expected) => term(),
          optional(:actual) => term()
        }
  @type t :: %__MODULE__{
          case_id: String.t(),
          kind: EvalCase.kind(),
          status: status(),
          result: term(),
          error: term(),
          assertions: [assertion()],
          observations: map(),
          metadata: map()
        }

  @doc "The three run statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Build a validated run from keyword or map attrs."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    with {:ok, case_id} <- run_case_id(attrs),
         {:ok, kind} <- run_kind(attrs),
         {:ok, status} <- run_status(attrs) do
      {:ok,
       %__MODULE__{
         case_id: case_id,
         kind: kind,
         status: status,
         result: Map.get(attrs, :result),
         error: Map.get(attrs, :error),
         assertions: Map.get(attrs, :assertions, []),
         observations: Map.get(attrs, :observations, %{}),
         metadata: Map.get(attrs, :metadata, %{})
       }}
    end
  end

  @doc "Like `new/1` but raises `ArgumentError` on an invalid run."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, run} -> run
      {:error, reason} -> raise ArgumentError, "invalid eval run: #{inspect(reason)}"
    end
  end

  defp run_case_id(attrs) do
    case Map.get(attrs, :case_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      other -> {:error, {:invalid_eval_case_id, other}}
    end
  end

  defp run_kind(attrs) do
    kind = Map.get(attrs, :kind)

    if kind in EvalCase.kinds() do
      {:ok, kind}
    else
      {:error, {:invalid_eval_kind, kind}}
    end
  end

  defp run_status(attrs) do
    case Map.get(attrs, :status) do
      status when status in @statuses -> {:ok, status}
      other -> {:error, {:invalid_eval_run_status, other}}
    end
  end
end
