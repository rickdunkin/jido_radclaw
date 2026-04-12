defmodule JidoClaw.Tenant do
  @moduledoc "Tenant struct for multi-tenant isolation."

  @type status :: :active | :suspended | :terminating

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          status: status(),
          config: map(),
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :name,
    status: :active,
    config: %{},
    created_at: nil
  ]

  def new(attrs) do
    %__MODULE__{
      id: attrs[:id] || generate_id(),
      name: attrs[:name] || "default",
      status: :active,
      config: attrs[:config] || %{},
      created_at: DateTime.utc_now()
    }
  end

  defp generate_id do
    "tenant_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
