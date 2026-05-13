defmodule JidoClaw.ProjectType do
  @moduledoc """
  Detect a project's primary language by sniffing well-known build files
  (`mix.exs`, `package.json`, `Cargo.toml`, etc.) in a directory.

  Returns a binary so callers can render the result directly into prompts
  and the project_info tool payload without an extra conversion.
  """

  @doc """
  Detect the project type for `dir`. Returns `"unknown"` if no signature
  build file is present.
  """
  @spec detect(Path.t()) :: String.t()
  def detect(dir) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> "elixir"
      File.exists?(Path.join(dir, "package.json")) -> "node"
      File.exists?(Path.join(dir, "Cargo.toml")) -> "rust"
      File.exists?(Path.join(dir, "go.mod")) -> "go"
      File.exists?(Path.join(dir, "pyproject.toml")) -> "python"
      true -> "unknown"
    end
  end
end
