defmodule JidoClaw.Eval.Case do
  @moduledoc """
  Deterministic evaluation case for one prompt-as-data surface (the
  `Jidoka.Eval.Case` shape, adapted).

  A case is ordinary data: a `kind` naming which production surface to
  exercise, a kind-keyed `request` map, and lightweight `assertions` that
  `JidoClaw.Eval.run_case/2` evaluates against the execution result. Unlike
  the jidoka source (Zoi-validated `Agent.Spec` + `Turn.Request` sub-structs),
  the request here is an intentionally heterogeneous kind-keyed map, so the
  struct stays a plain `defstruct` and the real invariants (non-empty id,
  known kind, map request) are guarded clauses.

  Top-level attrs accept atom or string keys; `kind` accepts the four atoms
  or their exact string forms (explicit per-value mapping — never
  `String.to_atom/1`). A `%Case{}` handed to `from_input/2` is re-validated
  through `new/2`, so a hand-built invalid struct never reaches the runner.
  """

  @kinds [:prompt, :schema, :composer, :coherence]

  @enforce_keys [:id, :kind, :request]
  defstruct [:id, :kind, :request, assertions: %{}, metadata: %{}]

  @type kind :: :prompt | :schema | :composer | :coherence
  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          request: map(),
          assertions: map(),
          metadata: map()
        }

  @doc "The four supported case kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Build a validated case from atom- or string-keyed attrs (or an existing
  `%Case{}`, which is re-validated). Opts: `:id_generator` — a zero-arity fun
  minting the id when attrs carry none (default `JidoClaw.Refs.mint("eval_")`).
  """
  @spec new(t() | keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs, opts \\ []) do
    with {:ok, attrs} <- normalize(attrs),
         {:ok, id} <- case_id(attrs, opts),
         {:ok, kind} <- cast_kind(attrs),
         {:ok, request} <- request(attrs),
         {:ok, assertions} <- optional_map(attrs, :assertions),
         {:ok, metadata} <- optional_map(attrs, :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         request: request,
         assertions: assertions,
         metadata: metadata
       }}
    end
  end

  @doc "Like `new/2` but raises `ArgumentError` on an invalid case."
  @spec new!(t() | keyword() | map(), keyword()) :: t()
  def new!(attrs, opts \\ []) do
    case new(attrs, opts) do
      {:ok, eval_case} -> eval_case
      {:error, reason} -> raise ArgumentError, "invalid eval case: #{inspect(reason)}"
    end
  end

  @doc """
  Accept a `%Case{}`, keyword list, or map as case input. A struct is
  re-validated through `new/2` — a plain defstruct can be hand-built invalid,
  so struct input must not skip validation.
  """
  @spec from_input(t() | keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_input(input, opts \\ []), do: new(input, opts)

  defp normalize(%__MODULE__{} = eval_case), do: {:ok, Map.from_struct(eval_case)}

  defp normalize(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      {:ok, Map.new(attrs)}
    else
      {:error, {:invalid_eval_case_input, attrs}}
    end
  end

  defp normalize(attrs) when is_map(attrs), do: {:ok, attrs}
  defp normalize(other), do: {:error, {:invalid_eval_case_input, other}}

  defp case_id(attrs, opts) do
    case fetch_key(attrs, :id) do
      {:ok, id} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, id} -> {:error, {:invalid_eval_case_id, id}}
      :error -> {:ok, generate_id(opts)}
    end
  end

  defp generate_id(opts) do
    case Keyword.get(opts, :id_generator) do
      nil -> JidoClaw.Refs.mint("eval_")
      generator when is_function(generator, 0) -> generator.()
    end
  end

  defp cast_kind(attrs) do
    case fetch_key(attrs, :kind) do
      {:ok, kind} -> kind_value(kind)
      :error -> {:error, {:invalid_eval_kind, nil}}
    end
  end

  # Exact per-value string mapping — user input must never mint atoms.
  defp kind_value(kind) when kind in @kinds, do: {:ok, kind}
  defp kind_value("prompt"), do: {:ok, :prompt}
  defp kind_value("schema"), do: {:ok, :schema}
  defp kind_value("composer"), do: {:ok, :composer}
  defp kind_value("coherence"), do: {:ok, :coherence}
  defp kind_value(other), do: {:error, {:invalid_eval_kind, other}}

  defp request(attrs) do
    case fetch_key(attrs, :request) do
      {:ok, request} when is_map(request) -> {:ok, request}
      {:ok, other} -> {:error, {:invalid_eval_request, other}}
      :error -> {:error, {:invalid_eval_request, :missing}}
    end
  end

  defp optional_map(attrs, key) do
    case fetch_key(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, other} -> {:error, {:invalid_eval_case_field, key, other}}
      :error -> {:ok, %{}}
    end
  end

  defp fetch_key(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end
end
