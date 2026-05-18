defmodule JidoClaw.Security.Redaction.LogRedactor do
  @moduledoc false

  alias JidoClaw.Security.Redaction.Patterns

  @filter_id :jidoclaw_redact_secrets

  @spec install!() :: :ok
  def install! do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
      {:error, {:already_exists, @filter_id}} -> :ok
    end
  end

  @spec filter(:logger.log_event(), keyword()) :: :logger.log_event()
  def filter(%{msg: message} = event, _config) do
    %{event | msg: redact_message(message)}
  end

  @spec filter(Logger.message(), Logger.level(), Logger.metadata(), keyword()) ::
          Logger.message() | :stop
  def filter(message, _level, _metadata, _config) do
    redact_message(message)
  end

  defp redact_message(message) do
    case message do
      msg when is_binary(msg) -> Patterns.redact(msg)
      {:string, msg} -> {:string, Patterns.redact(IO.iodata_to_binary(msg))}
      msg when is_list(msg) -> Patterns.redact(IO.iodata_to_binary(msg))
      other -> other
    end
  end
end
