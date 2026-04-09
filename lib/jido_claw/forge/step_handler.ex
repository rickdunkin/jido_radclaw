defmodule JidoClaw.Forge.StepHandler do
  @callback execute(sandbox :: struct(), args :: map(), opts :: keyword()) ::
              {:ok, map()} | {:needs_input, String.t()} | {:error, term()}
end
