defmodule JidoClawTest.ErrorFormatTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Error
  alias JidoClaw.Error.Internal.UnknownError

  test "validation_error/2 sets message and defaults" do
    err = Error.validation_error("bad input", field: :foo, value: 42)

    assert %Error.ValidationError{message: "bad input", field: :foo, value: 42} = err
    assert JidoClaw.format_error(err) == "bad input"
  end

  test "config_error/2 sets message and defaults" do
    err = Error.config_error("Bad config.", details: %{code: :bad})

    assert %Error.ConfigError{message: "Bad config.", details: %{code: :bad}} = err
    assert JidoClaw.format_error(err) == "Bad config."
  end

  test "execution_error/2 sets message and phase" do
    err = Error.execution_error("Bad run.", phase: :unit)

    assert %Error.ExecutionError{message: "Bad run.", phase: :unit} = err
    assert JidoClaw.format_error(err) == "Bad run."
  end

  test "not_found/3 builds a ValidationError with single-quoted binary identifier" do
    err = Error.not_found(:agent, "abc")

    assert %Error.ValidationError{message: "Agent 'abc' not found.", field: :agent, value: "abc"} =
             err

    assert err.details[:reason] == :not_found
    assert err.details[:kind] == :agent
  end

  test "not_found/3 inspects non-binary identifiers" do
    err = Error.not_found(:tool, :read_file)
    assert err.message == "Tool :read_file not found."
  end

  test "invalid_argument/3 builds a ValidationError on the named field" do
    err = Error.invalid_argument(:cron, "x x x x")

    assert %Error.ValidationError{field: :cron, value: "x x x x"} = err
    assert err.message =~ "Invalid value for"
  end

  test "timeout/3 builds an ExecutionError with phase :timeout" do
    err = Error.timeout(:agent_completion, 60_000)

    assert %Error.ExecutionError{phase: :timeout} = err
    assert err.message =~ "timed out"
    assert err.details[:operation] == :agent_completion
    assert err.details[:timeout] == 60_000
  end

  test "missing_required/2 builds a ValidationError" do
    err = Error.missing_required(:actor)

    assert %Error.ValidationError{field: :actor} = err
    assert err.message == "Missing required value for `actor`."
    assert err.details[:reason] == :missing_required
  end

  test "format/1 returns a plain string for a binary input" do
    assert JidoClaw.format_error("oops") == "oops"
  end

  test "format/1 inspects unstructured inputs" do
    assert JidoClaw.format_error({:unhandled, :shape}) == "{:unhandled, :shape}"
  end

  test "format/1 returns the message for a map with :message" do
    assert JidoClaw.format_error(%{message: "from map"}) == "from map"
  end

  test "format/1 falls back to inspect for Internal.UnknownError" do
    assert JidoClaw.format_error(UnknownError.exception(error: nil)) ==
             "Unknown JidoClaw error"

    assert JidoClaw.format_error(UnknownError.exception(error: :boom)) ==
             ":boom"
  end

  test "format/1 renders a class container with multiple errors in stable order" do
    error =
      Error.to_class([
        Error.execution_error("Workflow step failed."),
        Error.validation_error("Input is invalid.")
      ])

    assert JidoClaw.format_error(error) ==
             "Multiple JidoClaw errors:\n- Input is invalid.\n- Workflow step failed."
  end

  test "format/1 flattens nested class containers down to the leaf message" do
    nested =
      Error.to_class([
        Error.to_class([
          Error.validation_error("Nested input.")
        ])
      ])

    assert JidoClaw.format_error(nested) == "Nested input."
  end

  test "format/1 returns a JidoClaw fallback message for an empty class" do
    empty = %Error.Invalid{errors: []}
    assert JidoClaw.format_error(empty) == "JidoClaw operation failed."
  end
end
