defmodule JidoClaw.Forge.Sandbox.Behaviour do
  @callback create(spec :: map()) :: {:ok, struct(), String.t()} | {:error, term()}
  @callback exec(client :: struct(), command :: String.t(), opts :: keyword()) ::
              {String.t(), integer()}
  @callback spawn(client :: struct(), command :: String.t(), args :: list(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback write_file(client :: struct(), path :: String.t(), content :: binary()) ::
              :ok | {:error, term()}
  @callback read_file(client :: struct(), path :: String.t()) ::
              {:ok, binary()} | {:error, term()}
  @callback inject_env(client :: struct(), env :: map()) :: :ok | {:error, term()}
  @callback run(
              client :: struct(),
              agent_type :: String.t(),
              args :: [String.t()],
              opts :: keyword()
            ) :: {String.t(), integer()}
  @callback destroy(client :: struct(), sandbox_id :: String.t()) :: :ok | {:error, term()}
  @callback impl_module() :: module()

  @optional_callbacks [impl_module: 0, run: 4]
end
