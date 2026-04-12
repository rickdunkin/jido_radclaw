defmodule JidoClaw.Forge.Runners.Custom do
  @behaviour JidoClaw.Forge.Runner

  @impl true
  def init(client, config) do
    init_fn = Map.get(config, :init_fn)
    if init_fn, do: init_fn.(client, config), else: :ok
  end

  @impl true
  def run_iteration(client, state, opts) do
    run_fn = Map.get(state, :run_fn)

    if run_fn do
      run_fn.(client, state, opts)
    else
      {:ok, JidoClaw.Forge.Runner.error("no run_fn configured")}
    end
  end

  @impl true
  def apply_input(client, input, state) do
    input_fn = Map.get(state, :input_fn)
    if input_fn, do: input_fn.(client, input, state), else: :ok
  end
end
