defmodule JidoClaw.Test.RecordingDockerBackend do
  @moduledoc """
  Docker-backend double for the executor docker-dispatch tests: a full
  `Sandbox.Behaviour` that DELEGATES to `JidoClaw.Test.StubSandbox` but first
  reports the flattened create spec to the pid armed in
  `:recording_docker_backend_notify` — the executor builds the `sandbox_spec`
  internally and the Harness holds the client, so the spec that actually
  reaches the backend (mounts, workdir, allow_network, post-normalization) is
  otherwise unobservable from a test.
  """

  @behaviour JidoClaw.Forge.Sandbox.Behaviour

  alias JidoClaw.Test.StubSandbox

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def create(spec) do
    case Application.get_env(:jido_claw, :recording_docker_backend_notify) do
      pid when is_pid(pid) -> send(pid, {:docker_backend_create, spec})
      _not_armed -> :ok
    end

    StubSandbox.create(spec)
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  defdelegate exec(client, command, opts), to: StubSandbox

  @impl JidoClaw.Forge.Sandbox.Behaviour
  defdelegate exec_argv(client, command, args, opts), to: StubSandbox

  @impl JidoClaw.Forge.Sandbox.Behaviour
  defdelegate run(client, executable, args, opts), to: StubSandbox

  @impl JidoClaw.Forge.Sandbox.Behaviour
  defdelegate spawn(client, command, args, opts), to: StubSandbox

  @impl JidoClaw.Forge.Sandbox.Behaviour
  defdelegate write_file(client, path, content), to: StubSandbox

  @impl JidoClaw.Forge.Sandbox.Behaviour
  defdelegate read_file(client, path), to: StubSandbox

  @impl JidoClaw.Forge.Sandbox.Behaviour
  defdelegate inject_env(client, env), to: StubSandbox

  # NOTE: only `create/1` is reachable through this module — the `Sandbox`
  # facade dispatches every post-create call by the CLIENT STRUCT's module
  # (`impl_for/1`), and create returns a `%StubSandbox{}`. The teardown pin
  # therefore lives on `StubSandbox.destroy/2` (`:stub_sandbox_destroy_notify`),
  # not here.
  @impl JidoClaw.Forge.Sandbox.Behaviour
  defdelegate destroy(client, sandbox_id), to: StubSandbox

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def impl_module, do: __MODULE__
end
