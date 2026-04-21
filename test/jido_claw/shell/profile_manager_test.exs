defmodule JidoClaw.Shell.ProfileManagerTest do
  # async: false — ProfileManager is a named singleton in the app tree. We
  # hand-roll a test instance under a different name via GenServer.start_link/2
  # (see start_manager/1) so we don't compete with the supervised copy, but
  # SessionManager itself is still the singleton and this test exercises its
  # update_env/3 no-op path, so parallel tests would still race.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Shell.ProfileManager

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_profile_manager_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, ".jido"))

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp}
  end

  defp write_config(tmp, yaml) do
    File.write!(Path.join([tmp, ".jido", "config.yaml"]), yaml)
  end

  # The application-supervised ProfileManager is registered under
  # JidoClaw.Shell.ProfileManager. Tests start their own instance by
  # hand-rolling start_link with no name, then poke it directly via
  # GenServer.call/2 — mirrors strategy_store_test.exs.
  defp start_manager(tmp) do
    {:ok, pid} =
      GenServer.start_link(ProfileManager, project_dir: tmp)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    pid
  end

  defp call(pid, msg), do: GenServer.call(pid, msg)

  describe "list/0" do
    test "always includes 'default' pinned first even without a YAML entry",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        staging:
          FOO: bar
      """)

      pid = start_manager(tmp)
      assert call(pid, :list) == ["default", "staging"]
    end

    test "sorts non-default names alphabetically after the pinned default",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        zeta:
          A: 1
        alpha:
          B: 2
        default:
          C: 3
      """)

      pid = start_manager(tmp)
      assert call(pid, :list) == ["default", "alpha", "zeta"]
    end
  end

  describe "get/1" do
    test "returns the empty map for 'default' when absent from profiles:",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        staging:
          FOO: bar
      """)

      pid = start_manager(tmp)
      assert call(pid, {:get, "default"}) == {:ok, %{}}
    end

    test "returns declared default", %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        default:
          BASE: "v"
      """)

      pid = start_manager(tmp)
      assert call(pid, {:get, "default"}) == {:ok, %{"BASE" => "v"}}
    end

    test "returns :not_found for unknown names", %{tmp: tmp} do
      write_config(tmp, "profiles: {}\n")
      pid = start_manager(tmp)
      assert call(pid, {:get, "bogus"}) == {:error, :not_found}
    end
  end

  describe "current/1" do
    test "defaults to 'default' when no switch has happened", %{tmp: tmp} do
      write_config(tmp, "profiles:\n  staging: {FOO: bar}\n")
      pid = start_manager(tmp)
      assert call(pid, {:current, "ws-1"}) == "default"
    end
  end

  describe "switch/2" do
    test "switching without live sessions: active map updates, no crash",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        default:
          BASE: "base"
        staging:
          STAGING_KEY: "s"
      """)

      pid = start_manager(tmp)
      ws = "ws-switch-#{System.unique_integer([:positive])}"

      assert {:ok, "staging"} = call(pid, {:switch, ws, "staging", "user_switch"})
      assert call(pid, {:current, ws}) == "staging"
    end

    test "active_env reflects the switch", %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        default:
          BASE: "base"
        staging:
          STAGING_KEY: "s"
      """)

      pid = start_manager(tmp)
      ws = "ws-active-env-#{System.unique_integer([:positive])}"

      assert call(pid, {:active_env, ws}) == %{"BASE" => "base"}
      assert {:ok, "staging"} = call(pid, {:switch, ws, "staging", "user_switch"})

      assert call(pid, {:active_env, ws}) == %{
               "BASE" => "base",
               "STAGING_KEY" => "s"
             }
    end

    test "unknown profile → {:error, :unknown_profile}; state unchanged",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        staging:
          FOO: bar
      """)

      pid = start_manager(tmp)
      ws = "ws-unknown-#{System.unique_integer([:positive])}"

      assert {:error, :unknown_profile} =
               call(pid, {:switch, ws, "prod", "user_switch"})

      assert call(pid, {:current, ws}) == "default"
    end

    test "switching to current active name short-circuits: no signal, no env writes",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        default:
          A: "a"
        staging:
          B: "b"
      """)

      pid = start_manager(tmp)
      ws = "ws-shortcircuit-#{System.unique_integer([:positive])}"

      assert {:ok, "default"} =
               call(pid, {:switch, ws, "default", "user_switch"})

      # Subscribe first, then attempt a no-op switch. The short-circuit
      # path must not emit a signal.
      {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.shell.profile_switched")
      on_exit(fn -> JidoClaw.SignalBus.unsubscribe(sub_id) end)

      assert {:ok, "default"} =
               call(pid, {:switch, ws, "default", "user_switch"})

      refute_receive {:signal, _}, 100
    end

    test "switch to 'default' when profiles.default is absent returns {:ok, 'default'}",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        staging:
          FOO: bar
      """)

      pid = start_manager(tmp)
      ws = "ws-no-default-#{System.unique_integer([:positive])}"

      # Start on staging, then fall back to the magic "default"
      assert {:ok, "staging"} = call(pid, {:switch, ws, "staging", "user_switch"})
      assert {:ok, "default"} = call(pid, {:switch, ws, "default", "user_switch"})
      assert call(pid, {:current, ws}) == "default"
    end

    test "emits jido_claw.shell.profile_switched on a successful switch",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        default:
          BASE: "b"
        staging:
          STAGING_KEY: "s"
      """)

      pid = start_manager(tmp)
      ws = "ws-signal-#{System.unique_integer([:positive])}"

      {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.shell.profile_switched")
      on_exit(fn -> JidoClaw.SignalBus.unsubscribe(sub_id) end)

      assert {:ok, "staging"} = call(pid, {:switch, ws, "staging", "user_switch"})

      assert_receive {:signal, %Jido.Signal{data: data}}, 1_000
      assert data.workspace_id == ws
      assert data.from == "default"
      assert data.to == "staging"
      assert data.reason == "user_switch"
      assert data.key_count == 2
    end
  end

  describe "reload/0" do
    test "removing the active profile falls back to 'default' with reason=profile_removed",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        default:
          BASE: "b"
        staging:
          STAGING_KEY: "s"
      """)

      pid = start_manager(tmp)
      ws = "ws-reload-#{System.unique_integer([:positive])}"

      assert {:ok, "staging"} = call(pid, {:switch, ws, "staging", "user_switch"})

      {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.shell.profile_switched")
      on_exit(fn -> JidoClaw.SignalBus.unsubscribe(sub_id) end)

      # Rewrite config to remove `staging`, then reload
      write_config(tmp, """
      profiles:
        default:
          BASE: "b"
      """)

      assert :ok = call(pid, :reload)

      assert_receive {:signal, %Jido.Signal{data: data}}, 1_000
      assert data.from == "staging"
      assert data.to == "default"
      assert data.reason == "profile_removed"

      assert call(pid, {:current, ws}) == "default"
    end

    test "no-op when nothing changed",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        default:
          A: "1"
      """)

      pid = start_manager(tmp)
      ws = "ws-reload-noop-#{System.unique_integer([:positive])}"

      # No switches — active_by_workspace is empty, so reload touches nothing.
      assert :ok = call(pid, :reload)
      assert call(pid, {:current, ws}) == "default"
    end
  end

  describe "profile YAML coercion" do
    test "integer values are coerced to strings",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        staging:
          PORT: 5432
      """)

      pid = start_manager(tmp)
      assert call(pid, {:get, "staging"}) == {:ok, %{"PORT" => "5432"}}
    end

    test "float values are rejected per-key (warn-and-skip)",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        staging:
          GOOD: "ok"
          BAD: 3.14
      """)

      pid = start_manager(tmp)
      assert call(pid, {:get, "staging"}) == {:ok, %{"GOOD" => "ok"}}
    end
  end

  # These guard the policy that rejected profile values never land in
  # logs. A config like `DATABASE_PASSWORD: [prod-secret]` must produce
  # a warning that names the type but not the bytes.
  describe "rejection logging — no raw values leaked" do
    test "non-mapping profile env logs type hint, not the offending term",
         %{tmp: tmp} do
      # `env` here is a list, not a map. We want the log to say
      # `list/1` — and crucially *not* the string payload inside it.
      write_config(tmp, """
      profiles:
        bogus:
          - leak-me-this-is-secret
      """)

      log =
        capture_log(fn ->
          _pid = start_manager(tmp)
          # Give handle_continue a moment to run.
          Process.sleep(50)
        end)

      assert log =~ "is not a mapping"
      refute log =~ "leak-me-this-is-secret"
    end

    test "non-string key logs type hint, not the offending term",
         %{tmp: tmp} do
      # A YAML sequence in the key position yields a list-keyed entry
      # (actually the parser typically fails earlier or coerces — we
      # rely on the boolean-key shape since YAML booleans parse as
      # non-string keys in the loaded map). Use the replace_profiles
      # seam for determinism: install a profile whose env map has a
      # tuple key (unrepresentable in YAML, but the coercion
      # pathway tolerates any map term and logs on it).
      write_config(tmp, "profiles: {}\n")
      pid = start_manager(tmp)

      log =
        capture_log(fn ->
          GenServer.call(
            pid,
            {:replace_profiles_for_test, %{"staging" => %{{:leak, :pair} => "value"}}}
          )

          # replace_profiles_for_test replaces profiles directly; it
          # doesn't re-run coerce_entry. To trigger the log path we
          # invoke coerce via a reload that routes through parse_profile.
          # Simpler: write a config with a non-string YAML key and
          # reload.
          write_config(tmp, """
          profiles:
            staging:
              ? - leak-me-as-key
              : "ok"
          """)

          :ok = GenServer.call(pid, :reload)
          Process.sleep(50)
        end)

      assert log =~ "Non-string key"
      refute log =~ "leak-me-as-key"
    end

    test "non-binary profile name logs type hint, not the offending term",
         %{tmp: tmp} do
      # A YAML sequence in the profile-name position parses as a
      # structured term (list of string). `parse_profile/3`'s
      # non-binary-name clause must scrub it to a type hint rather
      # than inspect/1 — the name itself could carry a secret.
      write_config(tmp, """
      profiles:
        ? - leak-me-as-profile-name
        :
          FOO: "ok"
      """)

      log =
        capture_log(fn ->
          _pid = start_manager(tmp)
          Process.sleep(50)
        end)

      assert log =~ "non-string name"
      refute log =~ "leak-me-as-profile-name"
    end

    test "non-string/non-integer value logs type hint, not the offending term",
         %{tmp: tmp} do
      write_config(tmp, """
      profiles:
        staging:
          GOOD: "ok"
          DATABASE_PASSWORD: [leak-me-please]
      """)

      log =
        capture_log(fn ->
          _pid = start_manager(tmp)
          Process.sleep(50)
        end)

      assert log =~ "Non-string value for staging.DATABASE_PASSWORD"
      assert log =~ "list/1"
      refute log =~ "leak-me-please"
    end
  end
end
