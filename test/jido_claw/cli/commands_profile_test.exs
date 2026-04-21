defmodule JidoClaw.CLI.CommandsProfileTest do
  # async: false — ProfileManager is a named singleton; these tests
  # exercise it via the Commands handlers using ExUnit.CaptureIO.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JidoClaw.CLI.Commands
  alias JidoClaw.Shell.ProfileManager

  defp base_state do
    # Minimal REPL-shaped state the /profile handlers touch:
    # session_id (used as workspace_id), profile (updated on switch),
    # strategy + cwd + config kept for struct parity.
    %{
      session_id: "commands-profile-test-#{System.unique_integer([:positive])}",
      profile: "default",
      strategy: "auto",
      cwd: File.cwd!(),
      config: %{},
      model: "test:model"
    }
  end

  describe "/profile (bare)" do
    test "prints the current active profile" do
      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/profile", base_state())
        end)

      assert output =~ "Active Profile"
      assert output =~ "default"
    end
  end

  describe "/profile current" do
    test "prints the active profile heading" do
      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/profile current", base_state())
        end)

      assert output =~ "Active Profile"
      assert output =~ "default"
    end
  end

  describe "/profile list" do
    test "lists 'default' pinned first with key count" do
      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/profile list", base_state())
        end)

      assert output =~ "Environment Profiles"
      assert output =~ "default"
      # Either "← active" (when current == default) or plain; either way
      # the label should be the pinned default entry.
      assert output =~ "keys"
    end
  end

  describe "/profile switch <name>" do
    test "unknown profile prints error + available names; state unchanged" do
      state = base_state()

      output =
        capture_io(fn ->
          {:ok, new_state} = Commands.handle("/profile switch totally-made-up", state)
          assert new_state.profile == state.profile
        end)

      assert output =~ "Unknown profile"
      assert output =~ "totally-made-up"
      assert output =~ "Available"
    end

    test "switching to the current profile (short-circuit) succeeds" do
      state = base_state()

      output =
        capture_io(fn ->
          {:ok, new_state} = Commands.handle("/profile switch default", state)
          assert new_state.profile == "default"
        end)

      assert output =~ "Switched to profile"
      assert output =~ "default"
    end
  end

  describe "/profile (malformed)" do
    test "bogus sub-command prints usage" do
      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/profile garbage garbage garbage", base_state())
        end)

      assert output =~ "Usage:"
      assert output =~ "/profile"
    end
  end

  # Fix 2: /profile current shows the merged default+overlay env, not
  # just the active profile's raw overrides. A profile that only
  # overrides keys already in `default` used to render "No variables
  # in this profile"; the fix uses ProfileManager.active_env/1 which
  # returns the composed map.
  describe "/profile current — inherited defaults" do
    setup do
      # Install fixture profiles on the supervised singleton. The
      # session_manager_profile_test.exs suite uses the same seam.
      :ok =
        ProfileManager.replace_profiles_for_test(%{
          "default" => %{"BASE" => "v"},
          "staging" => %{"STAGING_KEY" => "s"}
        })

      on_exit(fn ->
        :ok = ProfileManager.replace_profiles_for_test(%{})
        :ok = ProfileManager.clear_active_for_test()
      end)

      :ok
    end

    test "after switching to staging, /profile current shows both BASE (inherited) and STAGING_KEY" do
      state = base_state()
      {:ok, post_switch} = Commands.handle("/profile switch staging", state)

      output =
        capture_io(fn ->
          {:ok, _} = Commands.handle("/profile current", post_switch)
        end)

      assert output =~ "Active Profile"
      assert output =~ "staging"
      assert output =~ "BASE"
      assert output =~ "STAGING_KEY"
    end
  end
end
