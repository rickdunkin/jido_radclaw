defmodule JidoClaw.Core.AnubisToolsHandlerPatchTest do
  # async: true — drives Anubis.Server.Handlers.Tools.handle_call/3 directly
  # against hand-built request maps and Frame values. No shared state.
  use ExUnit.Case, async: true

  alias Anubis.MCP.Error
  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Context
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers.Tools, as: ToolsHandler
  alias Anubis.Server.Response

  # Stub server module — Anubis.Server.Handlers.get_server_tools/2 calls
  # `module.__components__(:tool)` and merges that with `Frame.get_tools/1`.
  # We seed tools through the frame, so __components__ returns []. The
  # handler-less Tool path dispatches to `server.handle_tool_call/3`, which
  # we capture by sending to the test pid pulled from frame.assigns.
  defmodule StubServer do
    @moduledoc false

    @spec __components__(atom()) :: []
    def __components__(:tool), do: []
    def __components__(_), do: []

    @spec handle_tool_call(String.t(), map(), Frame.t()) :: {:reply, Response.t(), Frame.t()}
    def handle_tool_call(name, params, frame) do
      send(Map.fetch!(frame.assigns, :test_pid), {:called, name, params})
      {:reply, %Response{type: :tool, content: [], isError: false}, frame}
    end
  end

  defp seed_frame(tools, opts \\ []) do
    context =
      case Keyword.get(opts, :scopes) do
        nil -> %Context{}
        scopes -> %Context{auth: %{scopes: scopes}}
      end

    %Frame{
      tools: Map.new(tools, &{&1.name, &1}),
      assigns: %{test_pid: self()},
      task_id: Keyword.get(opts, :task_id),
      context: context,
      pagination_limit: Keyword.get(opts, :pagination_limit)
    }
  end

  describe "Peri rescue surgical fix" do
    test "rescues a validate_input crash and dispatches with the unvalidated params" do
      # Mimics jido_mcp's JSON-Schema-shaped descriptor: validate_input
      # raises when given the incoming arguments. Upstream 1.5.0 would
      # propagate. The patch must rescue and pass the params through.
      raising_validate = fn _params -> raise "Peri exploded on JSON Schema" end

      tool = %Tool{
        name: "raising_tool",
        task_support: :optional,
        validate_input: raising_validate
      }

      frame = seed_frame([tool])

      request = %{
        "params" => %{
          "name" => "raising_tool",
          "arguments" => %{"path" => "/tmp"}
        }
      }

      # Should not raise — patch's `rescue _ -> {:ok, params}` clause owns it.
      assert {:reply, _payload, ^frame} =
               ToolsHandler.handle_call(request, frame, StubServer)

      # The handler-less Tool branch atomizes known keys before dispatch,
      # so :path arrives as an atom. The point of this case is that
      # dispatch happened at all — Peri did not abort it.
      assert_received {:called, "raising_tool", %{path: "/tmp"}}
    end
  end

  describe "atomize_known_keys surgical fix" do
    test "atomizes string keys that already exist as atoms and leaves unknown keys as strings" do
      # Make sure :path and :recursive exist in the atom table before the
      # request runs. Referencing them in source guarantees this.
      _existing_atoms = {:path, :recursive}

      # Use a passthrough validate_input so the params reach forward_to
      # unmodified (the `validate_input: nil` default would short-circuit
      # to %{}).
      tool = %Tool{
        name: "atom_tool",
        task_support: :optional,
        validate_input: fn params -> {:ok, params} end
      }

      frame = seed_frame([tool])

      request = %{
        "params" => %{
          "name" => "atom_tool",
          "arguments" => %{
            "path" => "/tmp",
            "recursive" => true,
            "unknown_key_anubis_patch_test_only" => "v"
          }
        }
      }

      assert {:reply, _payload, _frame} =
               ToolsHandler.handle_call(request, frame, StubServer)

      assert_received {:called, "atom_tool", received_params}

      assert received_params[:path] == "/tmp"
      assert received_params[:recursive] == true
      # Unknown key survives as a string — safe_to_existing_atom/1 returns
      # :error for atoms that don't exist, so the string passes through.
      assert received_params["unknown_key_anubis_patch_test_only"] == "v"
    end
  end

  describe "check_task_policy/3 (re-port of 1.5.0 upstream)" do
    test "task_support: :required without Frame.task_id returns :method_not_found" do
      tool = %Tool{
        name: "required_tool",
        task_support: :required,
        validate_input: fn params -> {:ok, params} end
      }

      frame = seed_frame([tool], task_id: nil)

      request = %{
        "params" => %{
          "name" => "required_tool",
          "arguments" => %{}
        }
      }

      assert {:error, %Error{} = error, ^frame} =
               ToolsHandler.handle_call(request, frame, StubServer)

      assert error.code == -32_601
      assert error.reason == :method_not_found
      assert error.data.message =~ ~s(taskSupport == "required")

      # No dispatch happened.
      refute_received {:called, _, _}
    end

    test "task_support: :forbidden with params.task returns :method_not_found" do
      # Assert the default explicitly — Tool struct's task_support default
      # is :forbidden, but we want this case to be intent-clear.
      assert %Tool{}.task_support == :forbidden

      tool = %Tool{
        name: "forbidden_tool",
        task_support: :forbidden,
        validate_input: fn params -> {:ok, params} end
      }

      frame = seed_frame([tool])

      request = %{
        "params" => %{
          "name" => "forbidden_tool",
          "arguments" => %{},
          "task" => %{"id" => "task-123"}
        }
      }

      assert {:error, %Error{} = error, ^frame} =
               ToolsHandler.handle_call(request, frame, StubServer)

      assert error.code == -32_601
      assert error.reason == :method_not_found
      assert error.data.message =~ ~s(taskSupport == "forbidden")

      refute_received {:called, _, _}
    end
  end

  describe "check_scopes/2 in handle_call/3 (ported from 1.6.0 OAuth 2.1)" do
    test "tool with non-empty scopes and frame missing scopes returns insufficient_scope" do
      tool = %Tool{
        name: "scoped_tool",
        task_support: :optional,
        scopes: ["admin"],
        validate_input: fn params -> {:ok, params} end
      }

      # Default frame: %Context{auth: nil} — Frame.scopes/1 returns [].
      frame = seed_frame([tool])

      request = %{
        "params" => %{
          "name" => "scoped_tool",
          "arguments" => %{}
        }
      }

      assert {:error, %Error{} = error, ^frame} =
               ToolsHandler.handle_call(request, frame, StubServer)

      assert error.reason == :execution_error
      assert error.message == "insufficient_scope"
      assert %{required: ["admin"], granted: []} = error.data

      # Scope check happens before validate_params/forward_to.
      refute_received {:called, _, _}
    end

    test "tool with non-empty scopes and frame holding all required scopes dispatches" do
      tool = %Tool{
        name: "scoped_tool",
        task_support: :optional,
        scopes: ["admin"],
        validate_input: fn params -> {:ok, params} end
      }

      frame = seed_frame([tool], scopes: ["admin"])

      request = %{
        "params" => %{
          "name" => "scoped_tool",
          "arguments" => %{}
        }
      }

      assert {:reply, _payload, _frame} =
               ToolsHandler.handle_call(request, frame, StubServer)

      # check_scopes → check_task_policy → validate → forward all passed.
      assert_received {:called, "scoped_tool", _}
    end
  end

  describe "visible?/2 in handle_list/3 (ported from 1.6.0 OAuth 2.1)" do
    test "filters tools the frame lacks scopes for" do
      public_tool = %Tool{name: "public_tool", scopes: []}
      admin_tool = %Tool{name: "admin_tool", scopes: ["admin"]}

      frame = seed_frame([public_tool, admin_tool])

      assert {:reply, %{"tools" => tools}, ^frame} =
               ToolsHandler.handle_list(%{}, frame, StubServer)

      assert Enum.map(tools, & &1.name) == ["public_tool"]
    end

    test "returns all tools when frame has every required scope" do
      public_tool = %Tool{name: "public_tool", scopes: []}
      admin_tool = %Tool{name: "admin_tool", scopes: ["admin"]}

      frame = seed_frame([public_tool, admin_tool], scopes: ["admin"])

      assert {:reply, %{"tools" => tools}, ^frame} =
               ToolsHandler.handle_list(%{}, frame, StubServer)

      # get_server_tools sorts alphabetically.
      assert Enum.map(tools, & &1.name) == ["admin_tool", "public_tool"]
    end

    test "filter runs before pagination so hidden tools don't eat the limit slot" do
      # Handlers.get_server_tools/2 sorts tools alphabetically, so
      # "a_admin_tool" precedes "z_public_tool". If pagination ran before
      # the visibility filter, the limit-1 cut would take "a_admin_tool"
      # and the filter would then strip it, leaving an empty result.
      admin_tool = %Tool{name: "a_admin_tool", scopes: ["admin"]}
      public_tool = %Tool{name: "z_public_tool", scopes: []}

      frame = seed_frame([admin_tool, public_tool], pagination_limit: 1)

      assert {:reply, %{"tools" => tools}, ^frame} =
               ToolsHandler.handle_list(%{}, frame, StubServer)

      assert Enum.map(tools, & &1.name) == ["z_public_tool"]
    end
  end
end
