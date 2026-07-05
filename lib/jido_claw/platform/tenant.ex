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

  @spec new(keyword()) :: t()
  def new(attrs) do
    %__MODULE__{
      id: attrs[:id] || generate_id(),
      name: attrs[:name] || "default",
      status: :active,
      config: attrs[:config] || %{},
      created_at: DateTime.utc_now()
    }
  end

  @doc false
  @spec generate_id() :: String.t()
  def generate_id do
    "tenant_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
