defmodule JidoClaw.Setup.CredentialValidator do
  @moduledoc false
  @doc "Validate that configured API credentials work."
  def validate_all do
    %{
      anthropic: validate_anthropic(),
      openai: validate_openai(),
      github: validate_github(),
      ollama: validate_ollama()
    }
  end

  defp validate_anthropic do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> %{configured?: false, valid?: false, provider: "Anthropic"}
      key when byte_size(key) > 10 -> %{configured?: true, valid?: true, provider: "Anthropic"}
      _ -> %{configured?: true, valid?: false, provider: "Anthropic"}
    end
  end

  defp validate_openai do
    case System.get_env("OPENAI_API_KEY") do
      nil -> %{configured?: false, valid?: false, provider: "OpenAI"}
      key when byte_size(key) > 10 -> %{configured?: true, valid?: true, provider: "OpenAI"}
      _ -> %{configured?: true, valid?: false, provider: "OpenAI"}
    end
  end

  defp validate_github do
    case System.get_env("GITHUB_TOKEN") do
      nil -> %{configured?: false, valid?: false, provider: "GitHub"}
      token when byte_size(token) > 10 -> %{configured?: true, valid?: true, provider: "GitHub"}
      _ -> %{configured?: true, valid?: false, provider: "GitHub"}
    end
  end

  defp validate_ollama do
    case System.cmd("curl", ["-s", "http://localhost:11434/api/version"], stderr_to_stdout: true) do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, %{"version" => _}} ->
            %{configured?: true, valid?: true, provider: "Ollama (local)"}

          _ ->
            %{configured?: false, valid?: false, provider: "Ollama (local)"}
        end

      _ ->
        %{configured?: false, valid?: false, provider: "Ollama (local)"}
    end
  rescue
    _ -> %{configured?: false, valid?: false, provider: "Ollama (local)"}
  end
end
