defmodule JidoClaw.Tools.SearchWebTest.StubBackend do
  @moduledoc false
  # Records the outbound params it received to a test pid taken from app env
  # (process-agnostic: a direct run/2 runs in the test process, but
  # Jido.Exec.run/4 may run the action in a task), then returns a scripted
  # result (`:search_web_stub_result`) or a benign empty default.
  @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def run(params, _context) do
    if pid = Application.get_env(:jido_claw, :search_web_test_pid) do
      send(pid, {:backend_received, params})
    end

    Application.get_env(
      :jido_claw,
      :search_web_stub_result,
      {:ok, %{query: params.query, results: [], count: 0}}
    )
  end
end

defmodule JidoClaw.Tools.SearchWebTest do
  # Mutates global app env (:search_web_backend / :search_web_test_pid /
  # :search_web_stub_result, :jido_browser :brave_api_key) and the
  # BRAVE_SEARCH_API_KEY env var, so it cannot run async.
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.SearchWeb
  alias JidoClaw.Tools.SearchWebTest.StubBackend

  # sk-ant-<24 chars> — matches Patterns @ "sk-ant-[a-zA-Z0-9_-]{20,}". Not an
  # email (there is no email pattern); a real secret-shaped token instead.
  @secret "sk-ant-aaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    # Snapshot every global this file mutates so on_exit restores the host's
    # original state exactly (delete if it was unset).
    backend = Application.fetch_env(:jido_claw, :search_web_backend)
    test_pid = Application.fetch_env(:jido_claw, :search_web_test_pid)
    stub_result = Application.fetch_env(:jido_claw, :search_web_stub_result)
    brave_key = Application.fetch_env(:jido_browser, :brave_api_key)
    env_key = System.get_env("BRAVE_SEARCH_API_KEY")

    # Default for most tests: the recording stub, delivering to this process.
    Application.put_env(:jido_claw, :search_web_backend, StubBackend)
    Application.put_env(:jido_claw, :search_web_test_pid, self())

    on_exit(fn ->
      restore(:jido_claw, :search_web_backend, backend)
      restore(:jido_claw, :search_web_test_pid, test_pid)
      restore(:jido_claw, :search_web_stub_result, stub_result)
      restore(:jido_browser, :brave_api_key, brave_key)

      case env_key do
        nil -> System.delete_env("BRAVE_SEARCH_API_KEY")
        val -> System.put_env("BRAVE_SEARCH_API_KEY", val)
      end
    end)

    :ok
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  describe "delegation through the shared wrapper" do
    test "returns the ranked-results shape" do
      Application.put_env(
        :jido_claw,
        :search_web_stub_result,
        {:ok,
         %{
           query: "elixir genserver",
           results: [
             %{
               rank: 1,
               title: "GenServer — Elixir",
               url: "https://hexdocs.pm/elixir/GenServer.html",
               snippet:
                 "A behaviour module for implementing the server of a client-server relation.",
               age: nil
             }
           ],
           count: 1
         }}
      )

      assert {:ok, %{query: query, results: results, count: 1}} =
               SearchWeb.run(%{query: "elixir genserver"}, %{})

      assert query == "elixir genserver"
      assert [%{rank: 1, url: "https://hexdocs.pm/elixir/GenServer.html"}] = results
    end

    test "normalizes a backend error into the agent-facing wire shape" do
      Application.put_env(
        :jido_claw,
        :search_web_stub_result,
        {:error, "Brave Search API: rate limit exceeded"}
      )

      assert {:error, %{message: msg}} = SearchWeb.run(%{query: "anything"}, %{})
      assert msg =~ "rate limit"
    end
  end

  describe "outbound leakage hygiene" do
    test "scrubs secrets out of the query before it leaves the platform" do
      query = "find docs #{@secret} please"

      assert {:ok, _} = SearchWeb.run(%{query: query}, %{})

      # Direct run/2 runs in the test process, so the stub's send lands here.
      assert_received {:backend_received, %{query: scrubbed}}
      assert scrubbed =~ "[REDACTED:ANTHROPIC_KEY]"
      refute scrubbed =~ @secret
    end
  end

  describe "inbound result redaction (external results are untrusted)" do
    test "redacts secrets nested inside a result snippet" do
      Application.put_env(
        :jido_claw,
        :search_web_stub_result,
        {:ok,
         %{
           query: "leak",
           results: [
             %{
               rank: 1,
               title: "t",
               url: "https://example.com",
               snippet: "leaked token #{@secret} in the body",
               age: nil
             }
           ],
           count: 1
         }}
      )

      assert {:ok, %{results: [%{snippet: snippet}]}} = SearchWeb.run(%{query: "leak"}, %{})
      assert snippet =~ "[REDACTED:ANTHROPIC_KEY]"
      refute snippet =~ @secret
    end
  end

  describe "ships key-ready (no Brave key configured)" do
    test "returns a clean error instead of hitting the network" do
      # Use the real backend and clear both key sources; get_api_key/0
      # short-circuits before any Req.get, so this is hermetic even if a
      # dev/CI exports the key.
      Application.delete_env(:jido_claw, :search_web_backend)
      Application.delete_env(:jido_browser, :brave_api_key)
      System.delete_env("BRAVE_SEARCH_API_KEY")

      assert {:error, %{message: msg}} = SearchWeb.run(%{query: "elixir"}, %{})
      assert msg =~ "API key"
    end
  end

  describe "full Jido.Exec path (param + output schema validation)" do
    test "validates required query, fills defaults, and validates output" do
      # Exercises the schema validation that a direct run/2 bypasses. The
      # action may run in a task, so assert on the returned value, not on a
      # received message.
      assert {:ok, %{count: count}} =
               Jido.Exec.run(SearchWeb, %{query: "elixir"}, %{}, log_level: :error)

      assert count == 0
    end
  end
end
