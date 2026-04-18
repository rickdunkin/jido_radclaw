defmodule JidoClaw.Reasoning.TaskProfile do
  @moduledoc """
  Structured profile of a reasoning task. Output of the heuristic classifier.
  Carries the signals `Classifier.recommend/2` uses to pick a strategy.
  """

  @type task_type ::
          :planning
          | :debugging
          | :refactoring
          | :exploration
          | :verification
          | :qa
          | :open_ended

  @type complexity :: :simple | :moderate | :complex | :highly_complex

  @type t :: %__MODULE__{
          prompt_length: non_neg_integer(),
          word_count: non_neg_integer(),
          domain: String.t() | nil,
          target: String.t() | nil,
          task_type: task_type(),
          complexity: complexity(),
          has_code_block: boolean(),
          has_constraints: non_neg_integer(),
          has_enumeration: boolean(),
          mentions_multiple_files: boolean(),
          error_signal: boolean(),
          keyword_buckets: %{optional(atom()) => non_neg_integer()}
        }

  defstruct [
    :prompt_length,
    :word_count,
    :domain,
    :target,
    :task_type,
    :complexity,
    :has_code_block,
    :has_constraints,
    :has_enumeration,
    :mentions_multiple_files,
    :error_signal,
    :keyword_buckets
  ]
end
