defmodule JidoClawTest.ErrorForeignInteropTest do
  @moduledoc """
  Policy gate for the Normalize boundary — the only enforced conversion point.

  These tests deliberately pin the behavior of `Normalize.*_error/2` and not
  `JidoClaw.Error.to_class/1` on raw foreign leaves: `to_class/1` is an
  aggregator that may pass leaves with `splode: nil` through without
  wrapping them, and that behavior is Splode-internal (may shift with
  versions). The Normalize layer is what callers must use.
  """
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden, as: AshForbidden
  alias Ash.Error.Framework, as: AshFramework
  alias Jido.AI.Error.API.Request, as: AIRequestError
  alias JidoClaw.Error
  alias JidoClaw.Error.Normalize

  describe "Ash interop" do
    test "Ash.Error.Invalid container → JidoClaw ValidationError via Normalize" do
      ash = Ash.Error.Invalid.exception(errors: [])
      assert %Error.ValidationError{} = Normalize.tool_error(ash)
    end

    test "Ash.Error.Forbidden → JidoClaw ExecutionError (not a validation error)" do
      forbidden = AshForbidden.exception(errors: [])
      assert %Error.ExecutionError{} = Normalize.tool_error(forbidden)
    end

    test "Ash.Error.Framework → JidoClaw ExecutionError" do
      framework = AshFramework.exception(errors: [])
      assert %Error.ExecutionError{} = Normalize.tool_error(framework)
    end

    test "Ash.Error.Unknown → JidoClaw Internal.UnknownError" do
      unknown = Ash.Error.Unknown.exception(errors: [])
      assert %Error.Internal.UnknownError{} = Normalize.tool_error(unknown)
    end

    test "Ash.Error.Invalid class container survives JidoClaw.Error.to_class/1 (merge_with guarantee)" do
      ash = Ash.Error.Invalid.exception(errors: [])
      assert %Ash.Error.Invalid{} = Error.to_class(ash)
    end
  end

  describe "Jido interop" do
    test "Jido.Error.ValidationError → JidoClaw ValidationError" do
      jido = Jido.Error.validation_error("bad", field: :foo)
      err = Normalize.tool_error(jido)
      assert %Error.ValidationError{} = err
    end

    test "Jido.Error.ExecutionError → JidoClaw ExecutionError" do
      jido = Jido.Error.execution_error("ran out", phase: :run)
      assert %Error.ExecutionError{} = Normalize.tool_error(jido)
    end

    test "Jido.Error.TimeoutError → JidoClaw ExecutionError phase :timeout" do
      jido = Jido.Error.timeout_error("timed out", timeout: 5_000)
      err = Normalize.tool_error(jido)
      assert %Error.ExecutionError{phase: :timeout} = err
    end

    test "Jido.Error.InternalError → JidoClaw Internal.UnknownError" do
      jido = Jido.Error.internal_error("internal boom")
      assert %Error.Internal.UnknownError{} = Normalize.tool_error(jido)
    end
  end

  describe "Jido.AI interop" do
    test "Jido.AI.Error.Validation.Invalid → JidoClaw ValidationError" do
      ai = Jido.AI.Error.Validation.Invalid.exception(message: "bad input", field: :prompt)
      assert %Error.ValidationError{} = Normalize.tool_error(ai)
    end

    test "Jido.AI.Error.API.Request → JidoClaw ExecutionError" do
      ai = AIRequestError.exception(message: "upstream 500")
      assert %Error.ExecutionError{} = Normalize.tool_error(ai)
    end

    test "Jido.AI.Error.Unknown → JidoClaw Internal.UnknownError" do
      ai = Jido.AI.Error.Unknown.exception(error: :boom)
      assert %Error.Internal.UnknownError{} = Normalize.tool_error(ai)
    end
  end

  describe "first-party passthrough" do
    test "Normalize is idempotent on JidoClaw errors" do
      err = Error.validation_error("x")
      assert ^err = Normalize.tool_error(err)
    end

    test "ConfigError passthrough" do
      err = Error.config_error("y")
      assert ^err = Normalize.tool_error(err)
    end

    test "ExecutionError passthrough" do
      err = Error.execution_error("z", phase: :forge)
      assert ^err = Normalize.forge_error(err)
    end
  end

  describe "generic exception fallback" do
    test "RuntimeError → JidoClaw ExecutionError" do
      err = RuntimeError.exception("boom")
      assert %Error.ExecutionError{} = Normalize.tool_error(err)
    end

    test "File.Error → JidoClaw ExecutionError" do
      err = %File.Error{path: "/x", reason: :enoent, action: "read"}
      assert %Error.ExecutionError{} = Normalize.tool_error(err)
    end
  end
end
