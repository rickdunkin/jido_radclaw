defmodule JidoClawTest.ErrorToolsWireFormatTest do
  @moduledoc """
  Contract gate for the agent-facing wire format produced by
  `JidoClaw.Tools.Error.normalize/1` over `%JidoClaw.Error.*{}` inputs.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Error
  alias JidoClaw.Error.Internal.UnknownError
  alias JidoClaw.Tools.Error, as: Wire

  describe "leaf constructors produce stable wire shapes" do
    test "validation_error" do
      err = Error.validation_error("bad", field: :path, value: "/x")
      wire = Wire.normalize(err)

      assert wire.code == :validation_error
      assert wire.message == "bad"
      assert wire.details.field == :path
      assert wire.details.value == "/x"
    end

    test "config_error" do
      err = Error.config_error("Bad config.", field: :provider, value: :unknown)
      wire = Wire.normalize(err)

      assert wire.code == :config_error
      assert wire.message == "Bad config."
      assert wire.details.field == :provider
      assert wire.details.value == :unknown
    end

    test "execution_error keeps phase in details, NOT in code" do
      err = Error.execution_error("Boom", phase: :read, details: %{path: "/x"})
      wire = Wire.normalize(err)

      assert wire.code == :execution_error
      assert wire.message == "Boom"
      assert wire.details.phase == :read
      assert wire.details.path == "/x"
    end

    test "not_found produces single-quoted binary identifier" do
      err = Error.not_found(:agent, "abc")
      wire = Wire.normalize(err)

      assert wire.code == :validation_error
      assert wire.message == "Agent 'abc' not found."
      assert wire.details.field == :agent
      assert wire.details.value == "abc"
      assert wire.details.kind == :agent
      assert wire.details.reason == :not_found
    end

    test "invalid_argument" do
      err = Error.invalid_argument(:cron, "bad")
      wire = Wire.normalize(err)

      assert wire.code == :validation_error
      assert wire.message =~ "Invalid value for"
      assert wire.details.field == :cron
      assert wire.details.value == "bad"
    end

    test "timeout" do
      err = Error.timeout(:agent_completion, 5_000)
      wire = Wire.normalize(err)

      assert wire.code == :execution_error
      assert wire.details.phase == :timeout
      assert wire.details.operation == :agent_completion
      assert wire.details.timeout == 5_000
    end

    test "missing_required" do
      err = Error.missing_required(:actor)
      wire = Wire.normalize(err)

      assert wire.code == :validation_error
      assert wire.message == "Missing required value for `actor`."
      assert wire.details.field == :actor
    end

    test "Internal.UnknownError" do
      err = UnknownError.exception(error: :boom)
      wire = Wire.normalize(err)

      assert wire.code == :unknown_error
      assert wire.message == ":boom"
      assert wire.details.error == :boom
    end
  end

  describe "class containers" do
    test "Invalid container maps to :validation_error code" do
      class =
        Error.to_class([
          Error.validation_error("Input is invalid."),
          Error.validation_error("Another bad input.")
        ])

      wire = Wire.normalize(class)

      assert wire.code == :validation_error
      assert wire.message =~ "Multiple JidoClaw errors"
      assert wire.details.class == :invalid
      assert is_list(wire.details.errors)
      assert length(wire.details.errors) == 2

      assert Enum.all?(wire.details.errors, fn child ->
               child.code == :validation_error and is_binary(child.message)
             end)
    end

    test "Execution container maps to :execution_error" do
      class =
        Error.to_class([
          Error.execution_error("step 1 failed"),
          Error.execution_error("step 2 failed")
        ])

      wire = Wire.normalize(class)
      assert wire.code == :execution_error
      assert wire.details.class == :execution
    end
  end

  describe "details sanitization" do
    test "nested exception structs are replaced with %{module, message}" do
      cause = %File.Error{path: "/x", reason: :enoent, action: "read"}

      err =
        Error.execution_error("Boom",
          phase: :load,
          details: %{cause: cause, operation: :load_file}
        )

      wire = Wire.normalize(err)

      assert wire.details.phase == :load
      assert wire.details.operation == :load_file
      assert %{module: "File.Error", message: msg} = wire.details.cause
      assert is_binary(msg)
    end

    test "very long strings are truncated" do
      huge = String.duplicate("x", 3_000)
      err = Error.validation_error("ok", details: %{blob: huge})
      wire = Wire.normalize(err)

      assert is_binary(wire.details.blob)
      assert String.ends_with?(wire.details.blob, "... (truncated)")
      assert byte_size(wire.details.blob) < byte_size(huge)
    end

    test "PIDs and refs in details are dropped, not leaked" do
      err =
        Error.validation_error("ok",
          details: %{worker: self(), token: make_ref(), kept: :ok}
        )

      wire = Wire.normalize(err)

      refute Map.has_key?(wire.details, :worker)
      refute Map.has_key?(wire.details, :token)
      assert wire.details.kept == :ok
    end

    test "oversized details map stays a map with a truncated summary" do
      huge =
        Map.new(1..200, fn i -> {:"k#{i}", String.duplicate("x", 100)} end)
        |> Map.put(:phase, :load)

      err = Error.execution_error("ok", phase: :load, details: huge)
      wire = Wire.normalize(err)

      assert is_map(wire.details)
      assert wire.details.truncated == true
      assert wire.details.description =~ "map with"
      assert wire.details.kept[:phase] == :load
    end

    test "multi-byte strings are truncated at a valid UTF-8 boundary" do
      huge = String.duplicate("€", 1_000)

      err = Error.validation_error("ok", details: %{blob: huge})
      wire = Wire.normalize(err)

      assert is_binary(wire.details.blob)
      assert String.valid?(wire.details.blob)
      assert String.ends_with?(wire.details.blob, "... (truncated)")
    end

    test "stacktrace-shaped lists are dropped" do
      stack = [
        {Mod, :fun, 0, [file: ~c"f.ex", line: 1]},
        {Mod, :fun2, 1, [file: ~c"f.ex", line: 2]}
      ]

      err = Error.execution_error("Boom", details: %{stacktrace: stack})
      wire = Wire.normalize(err)

      assert wire.details.stacktrace == "[stacktrace dropped]"
    end
  end

  describe "legacy fallbacks still work" do
    test "raw string flows through with :tool_error code" do
      wire = Wire.normalize("oops")
      assert wire == %{code: :tool_error, message: "oops", details: %{}}
    end

    test "tagged tuple uses the tag atom as code" do
      wire = Wire.normalize({:bad_thing, :context})
      assert wire.code == :bad_thing
      assert wire.message == "bad thing"
    end
  end
end
