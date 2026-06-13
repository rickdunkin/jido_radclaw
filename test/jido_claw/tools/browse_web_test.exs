defmodule JidoClaw.Tools.BrowseWebTest do
  # Sets the global :jido_browser adapter env, so cannot run async.
  use ExUnit.Case, async: false

  alias JidoClaw.Test.StubBrowserAdapter
  alias JidoClaw.Tools.BrowseWeb

  # Hermeticity: every allowed/requested URL below is a public IP literal —
  # the tool calls DestinationPolicy.check/1 with the DEFAULT resolver, so a
  # hostname would do live DNS.
  @public_url "http://8.8.8.8/"
  @blocked_redirect "http://127.0.0.1/admin"

  defp use_stub_adapter do
    original = Application.fetch_env(:jido_browser, :adapter)
    Application.put_env(:jido_browser, :adapter, StubBrowserAdapter)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:jido_browser, :adapter, value)
        :error -> Application.delete_env(:jido_browser, :adapter)
      end
    end)
  end

  defp set_scenario(scenario) do
    Application.put_env(:jido_claw, :stub_browser_scenario, scenario)
    on_exit(fn -> Application.delete_env(:jido_claw, :stub_browser_scenario) end)
  end

  # Overrides merge onto the current value — never wholesale-replace the
  # sublist, so unrelated policy keys keep their configured values.
  defp put_policy_env(overrides) do
    original = Application.fetch_env(:jido_claw, :destination_policy)
    current = Application.get_env(:jido_claw, :destination_policy, [])
    Application.put_env(:jido_claw, :destination_policy, Keyword.merge(current, overrides))

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:jido_claw, :destination_policy, value)
        :error -> Application.delete_env(:jido_claw, :destination_policy)
      end
    end)
  end

  describe "pre-navigation destination gate (no adapter needed)" do
    # Denial short-circuits before Jido.Browser.start_session/0, so no
    # adapter is configured here — a session attempt would error loudly.

    test "denies blocked address ranges with the public normalized error shape" do
      for url <- [
            "http://127.0.0.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/",
            "http://[::ffff:127.0.0.1]/"
          ] do
        assert {:error, %{message: msg}} = BrowseWeb.run(%{url: url}, %{})
        assert msg =~ "destination denied", "expected denial for #{url}: #{msg}"
        assert msg =~ "allowed_cidrs"
      end
    end

    test "denies browser-normalized literal forms (WHATWG host parity)" do
      # Both classify as the loopback literal — no DNS, so still hermetic.
      for url <- ["http://127.0.0.1./", "http://%31%32%37.0.0.1/"] do
        assert {:error, %{message: msg}} = BrowseWeb.run(%{url: url}, %{})
        assert msg =~ "destination denied", "expected denial for #{url}: #{msg}"
        assert msg =~ "allowed_cidrs"
      end
    end

    test "denies the backslash parser differential" do
      assert {:error, %{message: msg}} =
               BrowseWeb.run(%{url: "http://127.0.0.1\\@example.com/"}, %{})

      assert msg =~ "destination denied"
      assert msg =~ "backslash"
    end

    test "denies file:// URLs" do
      assert {:error, %{message: msg}} = BrowseWeb.run(%{url: "file:///etc/passwd"}, %{})
      assert msg =~ "destination denied"
      assert msg =~ "scheme"
    end
  end

  describe "post-navigation redirect gate (stub adapter)" do
    setup do
      use_stub_adapter()
      :ok
    end

    test "allows a public destination and returns content" do
      set_scenario(%{
        get_url: {:ok, %{url: @public_url}},
        content: "hello from the public internet"
      })

      assert {:ok, %{content: content}} = BrowseWeb.run(%{url: @public_url}, %{})
      assert content =~ "hello from the public internet"
    end

    test "denies when the live browser URL reveals a redirect (atom-keyed JS-fallback shape)" do
      # No :content scripted — the stub raises if extract_content is reached,
      # which would surface here as a non-redirect "browser error" message.
      set_scenario(%{get_url: {:ok, %{url: @blocked_redirect}}})

      assert {:error, %{message: msg}} = BrowseWeb.run(%{url: @public_url}, %{})
      assert msg =~ "redirect"
      assert msg =~ "allowed_cidrs"
    end

    test "denies when the live browser URL reveals a redirect (string-keyed command shape)" do
      # nav metadata stays public (stub default echoes the requested URL), so
      # only the live get_url link can catch this one.
      set_scenario(%{get_url: {:ok, %{"url" => @blocked_redirect}}})

      assert {:error, %{message: msg}} = BrowseWeb.run(%{url: @public_url}, %{})
      assert msg =~ "redirect"
    end

    test "falls back to navigate metadata when get_url is unsupported" do
      set_scenario(%{get_url: {:error, :unsupported}, nav_url: @blocked_redirect})

      assert {:error, %{message: msg}} = BrowseWeb.run(%{url: @public_url}, %{})
      assert msg =~ "redirect"
    end

    test "re-checks an unchanged final URL (DNS-rebind stand-in)" do
      # The pre-check passes through an allow hole; :on_navigate revokes it
      # before the post-navigation re-check, while the URL string never
      # changes (get_url unscripted -> nav metadata echoes the request).
      # Skipping the re-check on string equality would miss exactly this —
      # a DNS rebind never changes the URL string.
      put_policy_env(allowed_cidrs: ["127.0.0.0/8"])

      set_scenario(%{
        on_navigate: fn ->
          current = Application.get_env(:jido_claw, :destination_policy, [])

          Application.put_env(
            :jido_claw,
            :destination_policy,
            Keyword.put(current, :allowed_cidrs, [])
          )
        end
      })

      assert {:error, %{message: msg}} = BrowseWeb.run(%{url: "http://127.0.0.1/"}, %{})
      assert msg =~ "post-navigation re-check"
      refute msg =~ "redirect"
    end
  end
end
