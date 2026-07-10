defmodule JidoClaw.Setup.CredentialValidator do
  @moduledoc false
  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Setup.CredentialCheck

  @doc "Validate that configured API credentials work."
  @spec validate_all() :: %{
          anthropic: CredentialCheck.t(),
          openai: CredentialCheck.t(),
          github: CredentialCheck.t(),
          ollama: CredentialCheck.t()
        }
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
      nil ->
        %CredentialCheck{configured?: false, valid?: false, provider: "Anthropic"}

      key when byte_size(key) > 10 ->
        %CredentialCheck{configured?: true, valid?: true, provider: "Anthropic"}

      _ ->
        %CredentialCheck{configured?: true, valid?: false, provider: "Anthropic"}
    end
  end

  defp validate_openai do
    case System.get_env("OPENAI_API_KEY") do
      nil ->
        %CredentialCheck{configured?: false, valid?: false, provider: "OpenAI"}

      key when byte_size(key) > 10 ->
        %CredentialCheck{configured?: true, valid?: true, provider: "OpenAI"}

      _ ->
        %CredentialCheck{configured?: true, valid?: false, provider: "OpenAI"}
    end
  end

  defp validate_github do
    case System.get_env("GITHUB_TOKEN") do
      nil ->
        %CredentialCheck{configured?: false, valid?: false, provider: "GitHub"}

      token when byte_size(token) > 10 ->
        %CredentialCheck{configured?: true, valid?: true, provider: "GitHub"}

      _ ->
        %CredentialCheck{configured?: true, valid?: false, provider: "GitHub"}
    end
  end

  defp validate_ollama do
    case System.cmd(
           "curl",
           [
             "--silent",
             "--show-error",
             "--connect-timeout",
             "1",
             "--max-time",
             "2",
             "http://localhost:11434/api/version"
           ],
           stderr_to_stdout: true,
           env: Env.scrubbed_cmd_env()
         ) do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, %{"version" => _}} ->
            %CredentialCheck{configured?: true, valid?: true, provider: "Ollama (local)"}

          _ ->
            %CredentialCheck{configured?: false, valid?: false, provider: "Ollama (local)"}
        end

      _ ->
        %CredentialCheck{configured?: false, valid?: false, provider: "Ollama (local)"}
    end
  rescue
    _ in [ErlangError] ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      %CredentialCheck{configured?: false, valid?: false, provider: "Ollama (local)"}
  end
end
