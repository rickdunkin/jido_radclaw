defmodule JidoClaw.Memory.Consolidator.Staging do
  @moduledoc """
  In-memory buffer of staged proposals for a single consolidator run.

  Each `propose_*` MCP tool dispatches to the RunServer which appends
  to this buffer. `commit_proposals` triggers the publish step which
  reads the buffer and writes to Postgres in a single transaction.

  Block proposals enforce `char_limit` here (returning structured
  `:char_limit_exceeded` info so the model can adapt) — every other
  proposal type is validated at publish time.
  """

  defstruct fact_adds: [],
            fact_updates: [],
            fact_deletes: [],
            block_updates: [],
            link_creates: [],
            cluster_defers: []

  @type t :: %__MODULE__{
          fact_adds: list(map()),
          fact_updates: list(map()),
          fact_deletes: list(map()),
          block_updates: list(map()),
          link_creates: list(map()),
          cluster_defers: list(map())
        }

  @doc "Empty staging buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Append a fact-add proposal."
  @spec add(t(), atom(), map()) :: {:ok, t()}
  def add(%__MODULE__{} = staging, :fact_add, args) do
    {:ok, %{staging | fact_adds: staging.fact_adds ++ [args]}}
  end

  def add(%__MODULE__{} = staging, :fact_update, args) do
    {:ok, %{staging | fact_updates: staging.fact_updates ++ [args]}}
  end

  def add(%__MODULE__{} = staging, :fact_delete, args) do
    {:ok, %{staging | fact_deletes: staging.fact_deletes ++ [args]}}
  end

  def add(%__MODULE__{} = staging, :link_create, args) do
    {:ok, %{staging | link_creates: staging.link_creates ++ [args]}}
  end

  def add(%__MODULE__{} = staging, :cluster_defer, args) do
    {:ok, %{staging | cluster_defers: staging.cluster_defers ++ [args]}}
  end

  @doc """
  Append a block-update proposal, enforcing `char_limit` if one was
  supplied. Returns either `{:ok, staging}` or
  `{:char_limit_exceeded, current_size, char_limit}` so the caller
  can surface a structured "soft" error to the model.
  """
  @spec add_block_update(t(), map()) ::
          {:ok, t()} | {:char_limit_exceeded, non_neg_integer(), pos_integer()}
  def add_block_update(%__MODULE__{} = staging, %{new_content: content} = args) do
    char_limit = Map.get(args, :char_limit, 2000)
    size = byte_size(content)

    if size > char_limit do
      {:char_limit_exceeded, size, char_limit}
    else
      {:ok, %{staging | block_updates: staging.block_updates ++ [args]}}
    end
  end

  @doc "Total number of staged proposals across every type."
  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{} = s) do
    length(s.fact_adds) + length(s.fact_updates) + length(s.fact_deletes) +
      length(s.block_updates) + length(s.link_creates) + length(s.cluster_defers)
  end
end
