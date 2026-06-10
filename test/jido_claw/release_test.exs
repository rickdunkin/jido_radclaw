defmodule JidoClaw.ReleaseTest do
  use ExUnit.Case, async: false

  test "migrate is release-safe when no repos are configured" do
    original_repos = Application.get_env(:jido_claw, :ecto_repos)
    Application.put_env(:jido_claw, :ecto_repos, [])

    try do
      assert :ok = JidoClaw.Release.migrate()
    after
      restore_repos(original_repos)
    end
  end

  test "mix project declares a named Unix release" do
    releases = Keyword.fetch!(JidoClaw.MixProject.project(), :releases)
    release = Keyword.fetch!(releases, :jido_claw)

    assert Keyword.fetch!(release, :include_executables_for) == [:unix]

    runtime_tools_mode =
      release
      |> Keyword.fetch!(:applications)
      |> Keyword.fetch!(:runtime_tools)

    assert runtime_tools_mode == :permanent
  end

  test "release patch compiler runs before app metadata is generated" do
    compilers = Keyword.fetch!(JidoClaw.MixProject.project(), :compilers)

    assert Enum.find_index(compilers, &(&1 == :jidoclaw_release_patches)) <
             Enum.find_index(compilers, &(&1 == :app))
  end

  defp restore_repos(nil), do: Application.delete_env(:jido_claw, :ecto_repos)
  defp restore_repos(repos), do: Application.put_env(:jido_claw, :ecto_repos, repos)
end
