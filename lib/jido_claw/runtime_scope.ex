defmodule JidoClaw.RuntimeScope do
  @moduledoc false

  @spec require_tenant(map() | keyword(), [atom()]) ::
          {:ok, keyword()} | {:error, :tenant_required}
  def require_tenant(scope_or_opts, allowed_keys) do
    opts = normalize(scope_or_opts, allowed_keys)

    case Keyword.get(opts, :tenant_id) do
      tenant_id when is_binary(tenant_id) and tenant_id != "" -> {:ok, opts}
      _ -> {:error, :tenant_required}
    end
  end

  @spec normalize(map() | keyword(), [atom()]) :: keyword()
  def normalize(opts, _allowed_keys) when is_list(opts), do: opts

  def normalize(%{} = map, allowed_keys) do
    map
    |> Enum.filter(fn {key, value} -> key in allowed_keys and not is_nil(value) end)
    |> Enum.into([])
  end
end
