defmodule JidoClaw.Test.StubBrowserAdapter do
  @moduledoc """
  Scriptable `Jido.Browser.Adapter` for `browse_web` tests. No real
  browser: each call answers from the scenario map in
  `Application.get_env(:jido_claw, :stub_browser_scenario)`, set
  per-test (async: false modules only).

  Scenario keys:

    * `:nav_url` — what `navigate/3` reports as `"url"` metadata
      (string-keyed, the AgentBrowser shape). Defaults to echoing the
      requested URL, like Vibium and the Web CLI.
    * `:on_navigate` — zero-arity fun run at the top of `navigate/3`
      when set. Lets a test change the world between the
      pre-navigation check and the post-navigation re-check — the
      deterministic stand-in for a DNS rebind.
    * `:get_url` — what `command(session, :get_url, _)` returns:
      `{:ok, meta}` (meta may be atom- or string-keyed) or
      `{:error, reason}`. Unset defaults to an error so the caller
      falls back to navigate metadata.
    * `:content` — `extract_content/2` result. Unset raises, so a test
      expecting a destination denial fails loudly if content is ever
      read past the gate.

  `start_session/1` returns a raw `%Session{}` per the behaviour
  contract — `Jido.Browser.start_session/1` wraps it in `{:ok, _}`.
  """

  @behaviour Jido.Browser.Adapter

  alias Jido.Browser.Session

  @impl Jido.Browser.Adapter
  def start_session(opts) do
    %Session{
      id: "stub-browser-#{System.unique_integer([:positive])}",
      adapter: __MODULE__,
      started_at: DateTime.utc_now(),
      opts: Map.new(opts)
    }
  end

  @impl Jido.Browser.Adapter
  def end_session(_session), do: :ok

  @impl Jido.Browser.Adapter
  def navigate(session, url, _opts) do
    run_on_navigate(scenario()[:on_navigate])
    {:ok, session, %{"url" => scenario()[:nav_url] || url}}
  end

  @impl Jido.Browser.Adapter
  def command(session, :get_url, _opts) do
    case scenario()[:get_url] do
      {:ok, meta} -> {:ok, session, meta}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :get_url_not_scripted}
    end
  end

  def command(_session, action, _opts), do: {:error, {:unsupported_command, action}}

  @impl Jido.Browser.Adapter
  def extract_content(session, _opts) do
    case scenario()[:content] do
      nil ->
        raise "extract_content called without a scripted result — " <>
                "the destination gate should have denied this browse"

      content ->
        {:ok, session, %{content: content, format: :markdown}}
    end
  end

  @impl Jido.Browser.Adapter
  def click(_session, _selector, _opts), do: {:error, :not_supported}

  @impl Jido.Browser.Adapter
  def type(_session, _selector, _text, _opts), do: {:error, :not_supported}

  @impl Jido.Browser.Adapter
  def screenshot(_session, _opts), do: {:error, :not_supported}

  @impl Jido.Browser.Adapter
  def evaluate(_session, _script, _opts), do: {:error, :not_supported}

  defp run_on_navigate(fun) when is_function(fun, 0), do: fun.()
  defp run_on_navigate(nil), do: :ok

  defp scenario do
    Application.get_env(:jido_claw, :stub_browser_scenario, %{})
  end
end
