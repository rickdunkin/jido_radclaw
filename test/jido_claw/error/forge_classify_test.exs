defmodule JidoClawTest.ErrorForgeClassifyTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Forge.Error, as: Forge

  describe "legacy Splode-shaped leaves still classify" do
    test "ProvisionError → :terminal" do
      err = Forge.ProvisionError.exception(message: "no sandbox", session_id: "s1")
      assert Forge.classify(err) == {:provision_failed, :terminal}
    end

    test "BootstrapError → :terminal" do
      err = Forge.BootstrapError.exception(message: "bootstrap broke")
      assert Forge.classify(err) == {:bootstrap_failed, :terminal}
    end

    test "ExecSessionError with :rate_limited → :retry" do
      err = Forge.ExecSessionError.exception(reason: :rate_limited)
      assert Forge.classify(err) == {:exec_failed, :retry}
    end

    test "ExecSessionError with other reason → :checkpoint_restore" do
      err = Forge.ExecSessionError.exception(reason: :boom)
      assert Forge.classify(err) == {:exec_failed, :checkpoint_restore}
    end

    test "TimeoutError → :retry" do
      err = Forge.TimeoutError.exception(timeout_ms: 5_000)
      assert Forge.classify(err) == {:timeout, :retry}
    end

    test "SandboxError → :checkpoint_restore" do
      err = Forge.SandboxError.exception(operation: :checkpoint)
      assert Forge.classify(err) == {:exec_failed, :checkpoint_restore}
    end
  end

  describe "JidoClaw.Error.ExecutionError dispatch" do
    test "phase :provision → :terminal" do
      err = JidoClaw.Error.execution_error("p", phase: :provision)
      assert Forge.classify(err) == {:provision_failed, :terminal}
    end

    test "phase :bootstrap → :terminal" do
      err = JidoClaw.Error.execution_error("b", phase: :bootstrap)
      assert Forge.classify(err) == {:bootstrap_failed, :terminal}
    end

    test "phase :timeout → :retry" do
      err = JidoClaw.Error.execution_error("t", phase: :timeout)
      assert Forge.classify(err) == {:timeout, :retry}
    end

    test "anything else → :unknown/:terminal" do
      assert Forge.classify(:nope) == {:unknown, :terminal}
      assert Forge.classify(JidoClaw.Error.validation_error("nope")) == {:unknown, :terminal}
    end
  end

  test "Forge leaves are Splode-registered as :execution class" do
    leaves = [
      Forge.ProvisionError,
      Forge.BootstrapError,
      Forge.ExecSessionError,
      Forge.TimeoutError,
      Forge.SandboxError
    ]

    for mod <- leaves do
      err = mod.exception([])
      assert err.class == :execution, "#{inspect(mod)} should be class :execution"
      assert mod.splode_error?()
      refute mod.error_class?()
    end
  end
end
