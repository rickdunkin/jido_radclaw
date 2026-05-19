defmodule JidoClawTest.ErrorNormalizeUnitTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Error
  alias JidoClaw.Error.Normalize

  describe "tool_error/2" do
    test "passes through first-party errors unchanged" do
      existing = Error.validation_error("already normalized")
      assert Normalize.tool_error(existing) == existing
    end

    test "timeout tuples produce an ExecutionError with phase :timeout" do
      assert %Error.ExecutionError{phase: :timeout, details: %{reason: :timeout, timeout: 250}} =
               Normalize.tool_error({:timeout, 250})
    end

    test "bare :timeout reads timeout from context" do
      assert %Error.ExecutionError{phase: :timeout, details: %{timeout: 100}} =
               Normalize.tool_error(:timeout, timeout: 100)
    end

    test "binary reasons default to ExecutionError when no field context" do
      assert %Error.ExecutionError{phase: :tool, details: %{cause: "boom"}} =
               Normalize.tool_error("boom")
    end

    test "binary reasons with a :field context produce a ValidationError" do
      assert %Error.ValidationError{field: :path, value: "/x"} =
               Normalize.tool_error("bad path", field: :path, value: "/x")
    end

    test "{:not_found, kind, value} routes to not_found/3" do
      err = Normalize.tool_error({:not_found, :tool, "edit"})
      assert %Error.ValidationError{field: :tool, value: "edit"} = err
      assert err.message == "Tool 'edit' not found."
    end

    test "atoms and unknown shapes wrap as ExecutionError" do
      assert %Error.ExecutionError{phase: :tool, details: %{cause: :boom}} =
               Normalize.tool_error(:boom)
    end
  end

  describe "forge_error/2" do
    test "timeout tuples produce ExecutionError phase :timeout" do
      assert %Error.ExecutionError{phase: :timeout, details: %{reason: :timeout, timeout: 5}} =
               Normalize.forge_error({:timeout, 5})
    end

    test "unknown reasons default to forge ExecutionError" do
      assert %Error.ExecutionError{phase: :forge, details: %{cause: :provision_died}} =
               Normalize.forge_error(:provision_died)
    end
  end

  describe "conversation_error/2" do
    test ":session_uuid_unset becomes ExecutionError" do
      assert %Error.ExecutionError{phase: :conversation, details: %{reason: :session_uuid_unset}} =
               Normalize.conversation_error(:session_uuid_unset)
    end

    test "{:not_found, kind, value} routes to not_found/3" do
      err = Normalize.conversation_error({:not_found, :session, "abc"})
      assert %Error.ValidationError{field: :session, value: "abc"} = err
    end
  end

  describe "reasoning_error/2" do
    test "binary with field context becomes ValidationError" do
      assert %Error.ValidationError{field: :strategy} =
               Normalize.reasoning_error("bad strategy", field: :strategy)
    end

    test "binary without field context becomes ExecutionError" do
      assert %Error.ExecutionError{phase: :reasoning} =
               Normalize.reasoning_error("upstream blew up")
    end
  end

  describe "session_error/2" do
    test "bare :not_found uses session_id from context" do
      err = Normalize.session_error(:not_found, session_id: "sess-1")
      assert %Error.ValidationError{field: :session, value: "sess-1"} = err
    end

    test "timeout tuple becomes ExecutionError phase :timeout" do
      assert %Error.ExecutionError{phase: :timeout, details: %{timeout: 99}} =
               Normalize.session_error({:timeout, 99})
    end
  end

  describe "context allow-list" do
    test "details only carry whitelisted keys plus the extras passed in" do
      err =
        Normalize.tool_error("boom",
          operation: :tool,
          session_id: "s1",
          tenant_id: "t1",
          some_unknown_key: "should be dropped"
        )

      assert %Error.ExecutionError{details: details} = err
      assert details[:session_id] == "s1"
      assert details[:tenant_id] == "t1"
      refute Map.has_key?(details, :some_unknown_key)
    end
  end
end
