defmodule JidoClaw.Forge.Runner do
  @type sandbox :: struct()
  @type config :: map()
  @type state :: map()
  @type opts :: keyword()
  @type input :: term()
  @type chunk :: binary()
  @type stream :: term()
  @type events :: list()

  @type iteration_result :: %{
          status: :continue | :done | :needs_input | :blocked | :error,
          output: term(),
          summary: String.t() | nil,
          question: String.t() | nil,
          error: term() | nil,
          metadata: map()
        }

  @callback init(sandbox(), config()) :: :ok | {:error, term()}
  @callback run_iteration(sandbox(), state(), opts()) ::
              {:ok, iteration_result()} | {:error, term()}
  @callback apply_input(sandbox(), input(), state()) :: :ok | {:error, term()}
  @callback handle_output(chunk(), stream(), state()) :: {:ok, events(), state()}
  @callback terminate(sandbox(), term()) :: :ok

  @optional_callbacks [handle_output: 3, terminate: 2]

  def continue(output), do: %{status: :continue, output: output, summary: nil, question: nil, error: nil, metadata: %{}}
  def done(output), do: %{status: :done, output: output, summary: nil, question: nil, error: nil, metadata: %{}}
  def needs_input(question, output \\ nil), do: %{status: :needs_input, output: output, summary: nil, question: question, error: nil, metadata: %{}}
  def blocked(output), do: %{status: :blocked, output: output, summary: nil, question: nil, error: nil, metadata: %{}}
  def error(reason, output \\ nil), do: %{status: :error, output: output, summary: nil, question: nil, error: reason, metadata: %{}}
end
