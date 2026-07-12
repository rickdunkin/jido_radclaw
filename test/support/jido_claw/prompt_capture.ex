defmodule JidoClaw.Memory.Consolidator.TestSupport.PromptCapture do
  @moduledoc """
  Test-only Forge runner that records the full `runner_config` it was
  initialised with so a test can assert the consolidator's config build
  (`Prompt.build/1` output, the armed resume knob) reached the harness
  without standing up a real CLI process.

  Captured configs land in a per-test Agent registered as
  `__MODULE__.Store`. Tests start the Agent in `setup`, drive a
  consolidator run with `runner_module: __MODULE__`, and read the last
  captured config with `last_config/0` (or just the prompt with
  `last_prompt/0`).
  """

  @behaviour JidoClaw.Forge.Runner

  alias JidoClaw.Forge.Runner

  @doc "Start the Agent that holds the most recently captured config."
  @spec start_link() :: Agent.on_start()
  def start_link do
    Agent.start_link(fn -> nil end, name: __MODULE__.Store)
  end

  @doc "Return the most recently captured full runner config, or `nil`."
  @spec last_config() :: map() | nil
  def last_config, do: Agent.get(__MODULE__.Store, & &1)

  @doc "Return the most recently captured prompt, or `nil`."
  @spec last_prompt() :: String.t() | nil
  def last_prompt do
    case last_config() do
      nil -> nil
      config -> Map.get(config, :prompt)
    end
  end

  @impl Runner
  def init(_client, config) do
    Agent.update(__MODULE__.Store, fn _ -> config end)
    {:ok, %{prompt: Map.get(config, :prompt, "")}}
  end

  @impl Runner
  def run_iteration(_client, _state, _opts), do: {:ok, Runner.done("")}

  @impl Runner
  def apply_input(_client, _input, _state), do: :ok
end
