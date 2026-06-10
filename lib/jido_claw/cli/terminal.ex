defmodule JidoClaw.CLI.Terminal do
  @moduledoc """
  Terminal-probing helpers shared across CLI surfaces.

  `:io.columns/0` returns the column count for the current group leader,
  which is the right answer when stdout is a TTY but may be wrong inside
  IEx or under redirected streams. We fall back to `tput cols`, then to
  a hard-coded 120-column default.
  """

  alias JidoClaw.Security.Redaction.Env

  @default_cols 120

  @doc """
  Return the terminal width in columns, falling back to `#{@default_cols}`
  when no probe succeeds.
  """
  @spec terminal_cols() :: pos_integer()
  def terminal_cols do
    case :io.columns() do
      {:ok, cols} ->
        cols

      _ ->
        case System.cmd("tput", ["cols"], stderr_to_stdout: true, env: Env.scrubbed_cmd_env()) do
          {output, 0} ->
            case Integer.parse(String.trim(output)) do
              {cols, _} -> cols
              :error -> @default_cols
            end

          _ ->
            @default_cols
        end
    end
  end
end
