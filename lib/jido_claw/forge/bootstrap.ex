defmodule JidoClaw.Forge.Bootstrap do
  require Logger

  @spec execute(struct(), list(map()), keyword()) :: :ok | {:error, map(), term()}
  def execute(client, steps, opts \\ []) do
    on_step = Keyword.get(opts, :on_step)
    sandbox = JidoClaw.Forge.Sandbox

    steps
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {step, index}, :ok ->
      if on_step, do: on_step.(step, index)

      case execute_step(sandbox, client, step) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, step, reason}}
      end
    end)
  end

  defp execute_step(sandbox, client, %{"type" => "exec", "command" => command}) do
    case sandbox.exec(client, command, []) do
      {_output, 0} -> :ok
      {output, code} -> {:error, "command exited with #{code}: #{String.slice(output, 0, 500)}"}
    end
  end

  defp execute_step(sandbox, client, %{"type" => "file", "path" => path, "content" => content}) do
    sandbox.write_file(client, path, content)
  end

  defp execute_step(_sandbox, _client, step) do
    {:error, {:unknown_step_type, step}}
  end
end
