defmodule JidoClaw.Core.JidoShellRegistryPatchTest do
  # async: false — :extra_commands is a global application env and we
  # mutate it in the name-collision test.
  use ExUnit.Case, async: false

  alias Jido.Shell.Command.Registry

  describe "lookup/1" do
    test "returns a built-in command unchanged" do
      assert {:ok, Jido.Shell.Command.Ls} = Registry.lookup("ls")
      assert {:ok, Jido.Shell.Command.Help} = Registry.lookup("help")
    end

    test "returns an extension command registered via :extra_commands" do
      assert {:ok, JidoClaw.Shell.Commands.Jido} = Registry.lookup("jido")
    end

    test "returns :not_found for an unknown name" do
      assert {:error, :not_found} = Registry.lookup("definitely-not-a-command")
    end
  end

  describe "list/0" do
    test "contains both built-ins and extension commands (set membership)" do
      names = MapSet.new(Registry.list())

      # Registry.list/0 wraps Map.keys/1, which has no ordering guarantee —
      # test membership rather than order.
      assert MapSet.member?(names, "ls")
      assert MapSet.member?(names, "help")
      assert MapSet.member?(names, "jido")
    end
  end

  describe "name collision" do
    setup do
      previous = Application.get_env(:jido_shell, :extra_commands)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:jido_shell, :extra_commands)
          value -> Application.put_env(:jido_shell, :extra_commands, value)
        end
      end)

      :ok
    end

    test "built-ins win over an :extra_commands entry of the same name" do
      # Override: try to shadow the built-in `ls` with a fake module name.
      # The patch must keep the built-in authoritative.
      Application.put_env(
        :jido_shell,
        :extra_commands,
        %{
          "ls" => __MODULE__.FakeCommand,
          "jido" => JidoClaw.Shell.Commands.Jido
        }
      )

      assert {:ok, Jido.Shell.Command.Ls} = Registry.lookup("ls")
      assert {:ok, JidoClaw.Shell.Commands.Jido} = Registry.lookup("jido")
    end

    test "extra_commands/0 drops names shadowed by built-ins but keeps unshadowed extras" do
      Application.put_env(
        :jido_shell,
        :extra_commands,
        %{
          "ls" => __MODULE__.FakeCommand,
          "jido" => JidoClaw.Shell.Commands.Jido
        }
      )

      extras = Registry.extra_commands()

      refute Map.has_key?(extras, "ls")
      assert Map.fetch!(extras, "jido") == JidoClaw.Shell.Commands.Jido
      assert {:ok, Jido.Shell.Command.Ls} = Registry.lookup("ls")
    end
  end

  defmodule FakeCommand do
    @moduledoc false
    @behaviour Jido.Shell.Command

    @impl true
    def name, do: "ls"
    @impl true
    def summary, do: "fake"
    @impl true
    def schema, do: Zoi.map(%{args: Zoi.array(Zoi.string()) |> Zoi.default([])})
    @impl true
    def run(_state, _args, emit) do
      emit.({:output, "fake\n"})
      {:ok, nil}
    end
  end
end
