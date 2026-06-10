defmodule JidoClaw.Desktop.SidecarTest do
  @moduledoc """
  Coverage for `JidoClaw.Desktop.Sidecar.maybe_configure_endpoint/0` — the
  non-desktop no-op and the desktop endpoint merge (loopback bind on the
  selected port, `check_origin` re-pinned to that port).

  `async: false`: the sidecar reads desktop env vars and mutates the global
  endpoint Application env (both captured and restored around every test).
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias JidoClaw.Desktop.Sidecar

  @endpoint_key JidoClaw.Web.Endpoint
  @env_vars ~w(JIDOCLAW_DESKTOP JIDOCLAW_PORT BURRITO_TARGET)

  setup do
    live_env = Application.get_env(:jido_claw, @endpoint_key, [])
    live_vars = Map.new(@env_vars, &{&1, System.get_env(&1)})

    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Application.put_env(:jido_claw, @endpoint_key, live_env)

      Enum.each(live_vars, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{live_env: live_env}
  end

  test "without desktop env it is a no-op", %{live_env: live_env} do
    assert Sidecar.maybe_configure_endpoint() == :not_desktop
    assert Application.get_env(:jido_claw, @endpoint_key, []) == live_env
  end

  test "desktop mode binds loopback on the selected port and re-pins origins", %{
    live_env: live_env
  } do
    System.put_env("JIDOCLAW_DESKTOP", "true")
    System.put_env("JIDOCLAW_PORT", "4321")

    assert Sidecar.maybe_configure_endpoint() == {:ok, 4321}

    config = Application.get_env(:jido_claw, @endpoint_key, [])

    assert config[:http][:ip] == {127, 0, 0, 1}
    assert config[:http][:port] == 4321
    assert config[:server] == true

    # Origins must follow the sidecar port — the base origins are pinned to
    # the default gateway port and would 403 LiveView/WS upgrades on 4321.
    assert config[:check_origin] ==
             ["//localhost:4321", "//127.0.0.1:4321", "//[::1]:4321"]

    # Deep merge: unrelated :http keys survive the rebind.
    for {key, value} <- Keyword.get(live_env, :http, []), key not in [:ip, :port] do
      assert config[:http][key] == value
    end
  end
end
