defmodule JidoClaw.Test.ScriptedDepositRunner do
  @moduledoc """
  Vendor-double Forge runner for the executor-seam PR-2 tests: a real
  `@behaviour JidoClaw.Forge.Runner` that resolves the deposit endpoint from
  the executor's client config (`runner_config.mcp_config_json` body for a
  docker plan, else the host-tmp `runner_config.mcp_config_path` file),
  initializes a `JidoClaw.MCP.LoopbackClient` session, and drives the scripted
  `submit_structured_output` calls — proving endpoint → plug → anubis → tool →
  registry → box end-to-end with zero vendor CLIs.

  The script comes from ITS OWN app-env key (`:scripted_deposit_runner`) — no
  test-only keys ride prod `runner_config`:

    * `:deposits` — list of `output` payloads; one `tools/call` each, in order
    * `:deposit_rounds` — a LIST of deposit lists consumed one per
      `run_iteration` via `:round_counter` (an `:atomics.new(1, [])` ref the
      test creates): session N gets `Enum.at(rounds, N - 1, [])` — the PR-3
      fresh-session two-round pin (each composer re-review wave is a NEW
      vendor session, so the rounds advance across sessions). Takes
      precedence over `:deposits` when present; the flat form stays for
      single-round tests.
    * `:notify` — pid receiving `{:scripted_deposit_runner, :init | :prompt |
      :config, term}` capture messages (PromptCapture, the consolidator
      precedent)
    * `:init_error` — make `init/2` return `{:error, term}` (drives the
      `{:runner_init_failed, _}` session-start failure path)
    * `:output` — the CLI-stdout stand-in returned as the iteration output
      (default `"scripted-vendor-output"`)
    * `:needs_input` — a question string: `run_iteration` returns
      `Runner.needs_input(question)` INSTEAD of depositing (the PR-4
      answer-loop scripting seam; flip the app env between attempts to
      script an ask-then-answer sequence)
  """

  @behaviour JidoClaw.Forge.Runner

  alias JidoClaw.Forge.Runner
  alias JidoClaw.MCP.LoopbackClient

  @impl JidoClaw.Forge.Runner
  def init(_client, config) do
    script = script()

    case Map.get(script, :init_error) do
      nil ->
        notify(script, {:scripted_deposit_runner, :config, config})
        {:ok, %{config: config}}

      reason ->
        {:error, reason}
    end
  end

  @impl JidoClaw.Forge.Runner
  def run_iteration(_client, state, _opts) do
    script = script()
    config = state.config
    notify(script, {:scripted_deposit_runner, :prompt, Map.get(config, :prompt)})

    case Map.get(script, :needs_input) do
      question when is_binary(question) ->
        {:ok, Runner.needs_input(question)}

      nil ->
        {:ok, deposit_result(script, config)}
    end
  end

  defp deposit_result(script, config) do
    with {:ok, url} <- read_server_url(config),
         {:ok, client} <- LoopbackClient.initialize(url),
         :ok <- send_deposits(client, round_deposits(script)) do
      Runner.done(Map.get(script, :output, "scripted-vendor-output"))
    else
      {:error, reason} ->
        Runner.error("scripted_deposit_runner_failed: #{inspect(reason)}")
    end
  end

  @impl JidoClaw.Forge.Runner
  def apply_input(_client, _input, _state), do: :ok

  defp script, do: Application.get_env(:jido_claw, :scripted_deposit_runner, %{})

  # `:deposit_rounds` advances one list per run_iteration (= per vendor
  # session) via the test-owned `:round_counter` atomics ref; exhausted rounds
  # serve `[]` (a deposit-less session — the loud infra-lane signal if a test
  # over-consumes). Absent ⇒ the flat `:deposits` form.
  defp round_deposits(script) do
    case Map.get(script, :deposit_rounds) do
      nil ->
        Map.get(script, :deposits, [])

      rounds when is_list(rounds) ->
        index = :atomics.add_get(Map.fetch!(script, :round_counter), 1, 1) - 1
        Enum.at(rounds, index, [])
    end
  end

  defp send_deposits(client, deposits) do
    Enum.reduce_while(deposits, :ok, fn output, _acc ->
      case LoopbackClient.call_tool(client, "submit_structured_output", %{"output" => output}) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:deposit_failed, reason}}}
      end
    end)
  end

  # Docker write build: a docker plan's `mcp_config_path` points INTO the VM
  # (no host file exists), so the runner prefers the in-VM config BODY
  # (`:mcp_config_json`) and parses it directly; a local plan still reads the
  # host-tmp file the executor wrote (the stronger local proof). The URL a
  # docker plan carries names `host.docker.internal` — mapped back to
  # `127.0.0.1` for this runner's HOST-side hermetic connection.
  defp read_server_url(config) do
    server = Map.get(config, :mcp_server_name, "jido_deposit")

    with {:ok, body} <- config_body(config),
         {:ok, %{"mcpServers" => servers}} <- Jason.decode(body),
         %{"url" => url} <- Map.get(servers, server, :missing) do
      {:ok, String.replace(url, "host.docker.internal", "127.0.0.1")}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_mcp_config}
    end
  end

  defp config_body(config) do
    case Map.get(config, :mcp_config_json) do
      json when is_binary(json) ->
        {:ok, json}

      nil ->
        case Map.get(config, :mcp_config_path) do
          path when is_binary(path) -> File.read(path)
          _missing -> {:error, :invalid_mcp_config}
        end
    end
  end

  defp notify(%{notify: pid}, msg) when is_pid(pid), do: send(pid, msg)
  defp notify(_script, _msg), do: :ok
end
