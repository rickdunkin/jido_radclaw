defmodule JidoClaw.Error.Normalize.Context do
  @moduledoc false

  alias JidoClaw.Error

  @type context :: keyword() | map()

  @allowed_keys [
    :operation,
    :tenant_id,
    :request_id,
    :session_id,
    :workspace_uuid,
    :agent_id,
    :run_id,
    :phase,
    :field,
    :value,
    :timeout
  ]

  @spec details(context(), map()) :: map()
  def details(context, attrs) do
    context
    |> to_map()
    |> Map.take(@allowed_keys)
    |> Map.merge(attrs)
    |> drop_nil_values()
  end

  @spec detail(context(), atom(), term()) :: term()
  def detail(context, key, default \\ nil)
  def detail(context, key, default) when is_map(context), do: Map.get(context, key, default)
  def detail(context, key, default) when is_list(context), do: Keyword.get(context, key, default)
  def detail(_context, _key, default), do: default

  @spec to_map(context() | term()) :: map()
  def to_map(context) when is_map(context), do: context
  def to_map(context) when is_list(context), do: Map.new(context)
  def to_map(_context), do: %{}

  @spec jido_claw_error?(Exception.t() | term()) :: boolean()
  def jido_claw_error?(%Error.ValidationError{}), do: true
  def jido_claw_error?(%Error.ConfigError{}), do: true
  def jido_claw_error?(%Error.ExecutionError{}), do: true
  def jido_claw_error?(%Error.Internal.UnknownError{}), do: true
  def jido_claw_error?(%Error.Invalid{}), do: true
  def jido_claw_error?(%Error.Config{}), do: true
  def jido_claw_error?(%Error.Execution{}), do: true
  def jido_claw_error?(%Error.Internal{}), do: true
  def jido_claw_error?(_error), do: false

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
