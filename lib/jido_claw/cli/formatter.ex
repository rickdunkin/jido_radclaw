defmodule JidoClaw.CLI.Formatter do
  @moduledoc """
  Output formatting: ANSI colors, tool panels, diff rendering.
  """

  alias JidoClaw.CLI.Branding

  def print_answer(answer) when is_binary(answer) do
    cleaned = strip_think_tags(answer)
    IO.puts("")
    IO.puts(cleaned)
    IO.puts("")
  end

  def print_answer(answer) do
    IO.puts("")
    IO.puts(inspect(answer))
    IO.puts("")
  end

  def print_error(message) do
    IO.puts("\n  \e[31m✗\e[0m #{message}\n")
  end

  def print_tool_call(name, args) when is_map(args) do
    args_str =
      args
      |> Enum.map(fn {k, v} ->
        v_display = truncate_value(v)
        "\e[2m#{k}=\e[0m#{v_display}"
      end)
      |> Enum.join(" ")

    IO.puts("  \e[33m⟳\e[0m \e[1m#{name}\e[0m #{args_str}")
  end

  def print_tool_result(name, _result) do
    IO.puts("  \e[32m✓\e[0m \e[2m#{name}\e[0m")
  end

  def render_diff(diff_text) when is_binary(diff_text) do
    diff_text
    |> String.split("\n")
    |> Enum.map(fn
      "+" <> rest -> "  \e[32m+ #{rest}\e[0m"
      "-" <> rest -> "  \e[31m- #{rest}\e[0m"
      "@@" <> rest -> "  \e[36m@@ #{rest}\e[0m"
      line -> "  \e[2m  #{line}\e[0m"
    end)
    |> Enum.join("\n")
  end

  # -- Thinking Spinner (runs in a separate process) --

  def start_spinner do
    parent = self()

    pid =
      spawn_link(fn ->
        spinner_loop(parent, 0)
      end)

    pid
  end

  def stop_spinner(pid) do
    send(pid, :stop)
    # Clear the spinner line
    IO.write("\e[2K\r")
  end

  defp spinner_loop(parent, tick) do
    receive do
      :stop -> :ok
    after
      150 ->
        frame = Branding.spinner_frame(tick)
        IO.write("\e[2K\r#{frame}")
        spinner_loop(parent, tick + 1)
    end
  end

  # -- Private --

  defp truncate_value(v) when is_binary(v) do
    if String.length(v) > 80 do
      "\e[2m\"#{String.slice(v, 0, 77)}...\"\e[0m"
    else
      "\e[2m\"#{v}\"\e[0m"
    end
  end

  defp truncate_value(v), do: "\e[2m#{inspect(v, limit: 3)}\e[0m"

  defp strip_think_tags(text) do
    # Remove <think>...</think> blocks from models that use thinking tags (qwen3, etc)
    Regex.replace(~r/<think>[\s\S]*?<\/think>\s*/m, text, "")
  end
end
