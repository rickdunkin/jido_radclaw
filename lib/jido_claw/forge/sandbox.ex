defmodule JidoClaw.Forge.Sandbox do
  @moduledoc false
  @spec create(map()) :: {:ok, struct(), String.t()} | {:error, term()}
  def create(spec) do
    impl().create(spec)
  end

  @spec exec(struct(), String.t(), keyword()) :: {String.t(), integer()}
  def exec(client, command, opts \\ []) do
    impl_for(client).exec(client, command, opts)
  end

  @spec exec_argv(struct(), String.t(), [String.t()], keyword()) ::
          {String.t(), integer() | :timeout}
  def exec_argv(client, command, args, opts \\ []) do
    impl_for(client).exec_argv(client, command, args, opts)
  end

  @spec spawn(struct(), String.t(), list(), keyword()) :: {:ok, term()} | {:error, term()}
  def spawn(client, command, args, opts \\ []) do
    impl_for(client).spawn(client, command, args, opts)
  end

  # `:timeout` in place of an exit code when the backend's :timeout opt
  # elapses (HostShell); Docker maps timeouts to exit code 124 instead.
  @spec run(struct(), String.t(), [String.t()], keyword()) :: {String.t(), integer() | :timeout}
  def run(client, agent_type, args, opts \\ []) do
    mod = impl_for(client)

    if function_exported?(mod, :run, 4) do
      mod.run(client, agent_type, args, opts)
    else
      # Fallback to exec for clients that don't implement run
      command = Enum.join([agent_type | args], " ")
      mod.exec(client, command, opts)
    end
  end

  @spec write_file(struct(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(client, path, content) do
    impl_for(client).write_file(client, path, content)
  end

  @spec read_file(struct(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(client, path) do
    impl_for(client).read_file(client, path)
  end

  @spec inject_env(struct(), map()) :: :ok | {:error, term()}
  def inject_env(client, env) do
    impl_for(client).inject_env(client, env)
  end

  @spec destroy(struct(), String.t()) :: :ok | {:error, term()}
  def destroy(client, sandbox_id) do
    impl_for(client).destroy(client, sandbox_id)
  end

  @spec impl_module() :: module()
  def impl_module, do: impl()

  @doc """
  Exit status backends report when `OsCmd` returns `:output_limit`:
  128 + SIGXFSZ ("file size limit exceeded"; 124 is taken by timeout).
  """
  @spec output_limit_exit_status() :: 153
  def output_limit_exit_status, do: 153

  defp impl do
    Application.get_env(:jido_claw, :forge_sandbox, JidoClaw.Forge.Runner.HostShell)
  end

  defp impl_for(client) do
    mod = client.__struct__
    if function_exported?(mod, :impl_module, 0), do: mod.impl_module(), else: mod
  end
end
