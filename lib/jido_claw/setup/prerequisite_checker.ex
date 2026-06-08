defmodule JidoClaw.Setup.PrerequisiteChecker do
  @moduledoc false
  @doc "Check all prerequisites and return a map of results."
  def check_all do
    %{
      elixir: check_elixir(),
      postgresql: check_postgresql(),
      git: check_git(),
      ollama: check_ollama(),
      node: check_node()
    }
  end

  def all_required_met? do
    results = check_all()
    results.elixir.ok? and results.postgresql.ok? and results.git.ok?
  end

  defp check_elixir do
    version = System.version()
    %{ok?: Version.match?(version, ">= 1.17.0"), version: version, name: "Elixir"}
  end

  defp check_postgresql do
    case System.cmd("psql", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        version = Regex.run(~r/\d+\.\d+/, output) |> List.first() || "unknown"
        %{ok?: true, version: version, name: "PostgreSQL"}

      _ ->
        %{ok?: false, version: nil, name: "PostgreSQL"}
    end
  rescue
    _ in [ErlangError] ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      %{ok?: false, version: nil, name: "PostgreSQL"}
  end

  defp check_git do
    case System.cmd("git", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        version = Regex.run(~r/\d+\.\d+\.\d+/, output) |> List.first() || "unknown"
        %{ok?: true, version: version, name: "Git"}

      _ ->
        %{ok?: false, version: nil, name: "Git"}
    end
  rescue
    _ in [ErlangError] ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      %{ok?: false, version: nil, name: "Git"}
  end

  defp check_ollama do
    case System.cmd("ollama", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        version = Regex.run(~r/\d+\.\d+\.\d+/, output) |> List.first() || "unknown"
        %{ok?: true, version: version, name: "Ollama"}

      _ ->
        %{ok?: false, version: nil, name: "Ollama"}
    end
  rescue
    _ in [ErlangError] ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      %{ok?: false, version: nil, name: "Ollama (optional)"}
  end

  defp check_node do
    case System.cmd("node", ["--version"], stderr_to_stdout: true) do
      {"v" <> version, 0} ->
        %{ok?: true, version: String.trim(version), name: "Node.js"}

      _ ->
        %{ok?: false, version: nil, name: "Node.js (optional)"}
    end
  rescue
    _ in [ErlangError] ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      %{ok?: false, version: nil, name: "Node.js (optional)"}
  end
end
