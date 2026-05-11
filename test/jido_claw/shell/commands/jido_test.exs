defmodule JidoClaw.Shell.Commands.JidoTest do
  # async: false — mutates the global :jido_claw app env via
  # :jido_claw_mcp_default_scope so the shell command resolves the
  # seeded (tenant_id, workspace_id) instead of the cwd workspace.
  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Shell.Commands.Jido

  describe "solutions find" do
    test "returns the solution row when one matches the signature under the resolved scope" do
      tenant_id = unique_tenant_id()
      workspace = workspace_fixture(tenant_id, embedding_policy: :disabled)

      fingerprint =
        :crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}")
        |> Base.encode16(case: :lower)

      _solution =
        solution_fixture(tenant_id, workspace.id, "the solution body",
          problem_signature: fingerprint,
          sharing: :local
        )

      prior = Application.get_env(:jido_claw, :jido_claw_mcp_default_scope)

      Application.put_env(:jido_claw, :jido_claw_mcp_default_scope, %{
        tenant_id: tenant_id,
        workspace_uuid: workspace.id
      })

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:jido_claw, :jido_claw_mcp_default_scope)
          val -> Application.put_env(:jido_claw, :jido_claw_mcp_default_scope, val)
        end
      end)

      test_pid = self()
      emit = fn msg -> send(test_pid, msg) end

      assert {:ok, nil} =
               Jido.run(nil, %{args: ["solutions", "find", fingerprint]}, emit)

      lines = drain_output()

      assert Enum.any?(lines, &String.contains?(&1, "signature   #{fingerprint}")),
             "expected presenter signature line in output; got: #{inspect(lines)}"

      refute Enum.any?(lines, &String.contains?(&1, "No solution with that signature.")),
             "did not expect not-found line; got: #{inspect(lines)}"
    end
  end

  defp drain_output(acc \\ []) do
    receive do
      {:output, line} -> drain_output([line | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end
end
