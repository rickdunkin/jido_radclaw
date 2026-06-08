defmodule JidoClaw.Setup.Wizard do
  @moduledoc false

  # Setup-wizard probes must never crash — they paint a status table for the
  # user; any DB/driver fault means "not connected".
  # reach:disable-for-this-file bare_rescue

  alias Ecto.Adapters.SQL
  alias JidoClaw.Setup.CredentialValidator
  alias JidoClaw.Setup.PrerequisiteChecker

  @doc "Run the full setup check and return overall status."
  def run do
    prerequisites = PrerequisiteChecker.check_all()
    credentials = CredentialValidator.validate_all()
    database = check_database()

    %{
      prerequisites: prerequisites,
      credentials: credentials,
      database: database,
      ready?: prerequisites_met?(prerequisites) and database.ok?,
      has_ai_provider?: has_provider?(credentials)
    }
  end

  def setup_needed? do
    not run().ready?
  end

  defp check_database do
    SQL.query!(JidoClaw.Repo, "SELECT 1")
    %{ok?: true, status: "connected"}
  rescue
    _ -> %{ok?: false, status: "not connected"}
  end

  defp prerequisites_met?(prereqs) do
    prereqs.elixir.ok? and prereqs.postgresql.ok? and prereqs.git.ok?
  end

  defp has_provider?(creds) do
    creds.anthropic.valid? or creds.openai.valid? or creds.ollama.valid?
  end
end
