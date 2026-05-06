defmodule JidoClaw.Memory.Consolidator.TestSupport.PromptCapture do
  @moduledoc """
  Test-only Forge runner that records the `runner_config.prompt` it was
  initialised with so a test can assert the consolidator's
  `Prompt.build/1` output reached the harness without standing up a
  real CLI process.

  Captured prompts land in a per-test Agent registered as
  `__MODULE__.Store`. Tests start the Agent in `setup`, drive a
  consolidator run with `runner_module: __MODULE__`, and read the last
  captured prompt with `last_prompt/0`.
  """

  @behaviour JidoClaw.Forge.Runner

  alias JidoClaw.Forge.Runner

  @doc "Start the Agent that holds the most recently captured prompt."
  def start_link do
    Agent.start_link(fn -> nil end, name: __MODULE__.Store)
  end

  @doc "Return the most recently captured prompt, or `nil`."
  def last_prompt, do: Agent.get(__MODULE__.Store, & &1)

  @impl true
  def init(_client, config) do
    Agent.update(__MODULE__.Store, fn _ -> Map.get(config, :prompt) end)
    {:ok, %{prompt: Map.get(config, :prompt, "")}}
  end

  @impl true
  def run_iteration(_client, _state, _opts), do: {:ok, Runner.done("")}

  @impl true
  def apply_input(_client, _input, _state), do: :ok
end
