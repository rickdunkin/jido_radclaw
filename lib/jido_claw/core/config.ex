defmodule JidoClaw.Config do
  @moduledoc """
  Loads project-level configuration from .jido/config.yaml with defaults.
  Supports multiple LLM providers: Ollama (local/cloud), Anthropic, OpenAI, Google, Groq, xAI.
  """

  # Reachability/metadata reads with a default fallback — any raise from
  # `:httpc`, LLMDB, or YAML parsing collapses to `{:error, :unreachable}` /
  # `{:error, :llm_db_unavailable}` so a misconfigured provider never
  # crashes boot or the setup wizard.
  # reach:disable-for-this-file bare_rescue

  @providers %{
    "ollama" => %{
      "base_url" => "http://localhost:11434",
      "api_key_env" => "OLLAMA_API_KEY",
      "default_model" => "ollama:nemotron-3-super:cloud"
    },
    "anthropic" => %{
      "api_key_env" => "ANTHROPIC_API_KEY",
      "default_model" => "anthropic:claude-sonnet-4-20250514"
    },
    "openai" => %{
      "api_key_env" => "OPENAI_API_KEY",
      "default_model" => "openai:gpt-4.1"
    },
    "google" => %{
      "api_key_env" => "GOOGLE_API_KEY",
      "default_model" => "google:gemini-2.5-flash"
    },
    "groq" => %{
      "api_key_env" => "GROQ_API_KEY",
      "default_model" => "groq:llama-3.3-70b-versatile"
    },
    "xai" => %{
      "api_key_env" => "XAI_API_KEY",
      "default_model" => "xai:grok-3-mini"
    },
    "openrouter" => %{
      "base_url" => "https://openrouter.ai/api/v1",
      "api_key_env" => "OPENROUTER_API_KEY",
      "default_model" => "openrouter:anthropic/claude-sonnet-4"
    }
  }

  @strategy_descriptions %{
    "auto" => "Auto — history-aware selection (recommended default)",
    "react" => "Reason + Act loop — multi-step tasks with tool use",
    "cot" => "Chain of Thought — logical/mathematical step-by-step reasoning",
    "cod" => "Chain of Draft — concise reasoning with minimal tokens",
    "tot" => "Tree of Thoughts — branching exploration for complex planning",
    "got" => "Graph of Thoughts — non-linear concept-connected reasoning",
    "aot" => "Algorithm of Thoughts — algorithmic search with examples",
    "trm" => "Tiny Recursive Model — hierarchical recursive decomposition",
    "adaptive" => "Deprecated — alias for auto"
  }

  @defaults %{
    "provider" => "ollama",
    "model" => "ollama:nemotron-3-super:cloud",
    "strategy" => "auto",
    "max_iterations" => 25,
    "timeout" => 120_000,
    "providers" => @providers
  }

  @cloud_base_url "https://ollama.com"

  # ---------------------------------------------------------------------------
  # Loading
  # ---------------------------------------------------------------------------

  @spec load(String.t()) :: map()
  def load(project_dir \\ File.cwd!()) do
    config_path = Path.join([project_dir, ".jido", "config.yaml"])

    user_config =
      case YamlElixir.read_from_file(config_path) do
        {:ok, config} when is_map(config) -> config
        _ -> %{}
      end

    config = deep_merge(@defaults, user_config)

    # Ollama cloud auto-detection (backwards compat)
    case provider(config) do
      "ollama" ->
        case api_key(config) do
          nil ->
            config

          _key ->
            if get_in(user_config, ["providers", "ollama", "base_url"]) do
              config
            else
              put_in(config, ["providers", "ollama", "base_url"], @cloud_base_url)
            end
        end

      _ ->
        config
    end
  end

  # ---------------------------------------------------------------------------
  # Accessors
  # ---------------------------------------------------------------------------

  @spec provider(map()) :: String.t()
  def provider(config), do: Map.get(config, "provider", "ollama")
  @spec model(map()) :: String.t()
  def model(config), do: Map.get(config, "model", @defaults["model"])
  @spec strategy(map()) :: String.t()
  def strategy(config), do: Map.get(config, "strategy", @defaults["strategy"])
  @spec max_iterations(map()) :: integer()
  def max_iterations(config), do: Map.get(config, "max_iterations", @defaults["max_iterations"])
  @spec timeout(map()) :: integer()
  def timeout(config), do: Map.get(config, "timeout", @defaults["timeout"])

  @doc """
  Returns the raw `profiles:` map from config (name → env var map).

  Profile value coercion and validation happen in
  `JidoClaw.Shell.ProfileManager` — this accessor returns whatever is in
  the YAML so the manager can apply its own warn-and-skip logic.
  """
  @spec profiles(map()) :: map()
  def profiles(config) do
    case Map.get(config, "profiles") do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc """
  Returns the raw `servers:` list from config (list of per-server maps).

  Entry-level validation and coercion happen in
  `JidoClaw.Shell.ServerRegistry` — this accessor returns whatever is in
  the YAML so the registry can apply its own warn-and-skip logic.
  """
  @spec servers(map()) :: list()
  def servers(config) do
    case Map.get(config, "servers") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc """
  Returns the raw `mcp_servers:` list from config (external MCP server decls).

  Entry-level validation and translation happen in
  `JidoClaw.MCP.EndpointConfig.parse/1` — this accessor returns whatever is in
  the YAML so the parser can apply its own fail-closed warn-and-skip logic.
  Inert (`[]`) when absent. Not in `@defaults` — an unconfigured project boots
  with no external MCP tools.
  """
  @spec mcp_servers(map()) :: list()
  def mcp_servers(config) do
    case Map.get(config, "mcp_servers") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "Returns all available strategy names with descriptions."
  @spec strategy_descriptions() :: %{String.t() => String.t()}
  def strategy_descriptions, do: @strategy_descriptions

  @spec provider_config(map()) :: map()
  def provider_config(config) do
    prov = provider(config)
    get_in(config, ["providers", prov]) || Map.get(@providers, prov, %{})
  end

  @spec api_key_env(map()) :: String.t()
  def api_key_env(config) do
    pc = provider_config(config)
    Map.get(pc, "api_key_env", "OLLAMA_API_KEY")
  end

  @spec api_key(map()) :: String.t() | nil
  def api_key(config) do
    env_var = api_key_env(config)
    normalize_api_key(env_var, System.get_env(env_var))
  end

  # "ollama" is the placeholder key the Ollama provider ships with; treat it as
  # "no key" only for that provider's env var so a real "ollama" elsewhere stays.
  defp normalize_api_key(_env_var, nil), do: nil
  defp normalize_api_key(_env_var, ""), do: nil
  defp normalize_api_key("OLLAMA_API_KEY", "ollama"), do: nil
  defp normalize_api_key(_env_var, key), do: key

  @spec base_url(map()) :: String.t() | nil
  def base_url(config) do
    pc = provider_config(config)
    Map.get(pc, "base_url")
  end

  @doc "Returns the provider display name for boot sequence."
  @spec provider_label(map()) :: String.t()
  def provider_label(config) do
    prov = provider(config)

    case prov do
      "ollama" -> if cloud?(config), do: "ollama cloud", else: "ollama"
      other -> other
    end
  end

  @doc "Is this an Ollama Cloud connection?"
  @spec cloud?(map()) :: boolean()
  def cloud?(config) do
    provider(config) == "ollama" and
      get_in(config, ["providers", "ollama", "base_url"]) == @cloud_base_url
  end

  # Keep for backwards compat
  @spec ollama_base_url(map()) :: String.t()
  def ollama_base_url(config) do
    get_in(config, ["providers", "ollama", "base_url"]) || "http://localhost:11434"
  end

  # :httpc headers — both elements are charlists.
  @spec auth_headers(map()) :: [{charlist(), charlist()}]
  def auth_headers(config) do
    case api_key(config) do
      nil -> []
      key -> [{~c"Authorization", String.to_charlist("Bearer #{key}")}]
    end
  end

  # ---------------------------------------------------------------------------
  # Provider connectivity check
  # ---------------------------------------------------------------------------

  @doc "Check if the configured provider is reachable. Returns :ok | {:error, :unauthorized} | {:error, :unreachable}."
  @spec check_provider(map()) :: :ok | {:error, :unauthorized | :unreachable}
  def check_provider(config) do
    case provider(config) do
      "ollama" -> check_ollama(config)
      "anthropic" -> check_api_key(config, "https://api.anthropic.com/v1/messages")
      "openai" -> check_api_key(config, "https://api.openai.com/v1/models")
      "google" -> check_api_key(config, "https://generativelanguage.googleapis.com/v1beta/models")
      "groq" -> check_api_key(config, "https://api.groq.com/openai/v1/models")
      "xai" -> check_api_key(config, "https://api.x.ai/v1/models")
      "openrouter" -> check_api_key(config, "https://openrouter.ai/api/v1/models")
      _ -> {:error, :unreachable}
    end
  end

  @spec check_ollama(map()) :: :ok | {:error, :unauthorized | :unreachable}
  def check_ollama(config) do
    url = ollama_base_url(config) <> "/api/tags"
    headers = auth_headers(config)

    case :httpc.request(:get, {String.to_charlist(url), headers}, [{:timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      {:ok, {{_, 401, _}, _, _}} -> {:error, :unauthorized}
      _ -> {:error, :unreachable}
    end
  rescue
    _ -> {:error, :unreachable}
  end

  defp check_api_key(config, url) do
    case api_key(config) do
      nil ->
        {:error, :unauthorized}

      key ->
        headers = [{~c"Authorization", String.to_charlist("Bearer #{key}")}]

        case :httpc.request(:get, {String.to_charlist(url), headers}, [{:timeout, 5000}], []) do
          {:ok, {{_, code, _}, _, _}} when code in 200..299 -> :ok
          {:ok, {{_, 401, _}, _, _}} -> {:error, :unauthorized}
          {:ok, {{_, 403, _}, _, _}} -> {:error, :unauthorized}
          _ -> {:error, :unreachable}
        end
    end
  rescue
    _ -> {:error, :unreachable}
  end

  # ---------------------------------------------------------------------------
  # Available providers list (for setup wizard)
  # ---------------------------------------------------------------------------

  @spec available_providers() :: [{String.t(), String.t(), String.t()}]
  def available_providers do
    [
      {"ollama", "Ollama (local)", "Run models locally with Ollama"},
      {"ollama_cloud", "Ollama Cloud", "Nemotron 3 Super, Qwen3-Coder 480B, DeepSeek 671B"},
      {"anthropic", "Anthropic", "Claude 4.6 Opus, Sonnet 4, Haiku"},
      {"openai", "OpenAI", "GPT-4.1, o3, o4-mini models"},
      {"google", "Google Gemini", "Gemini 2.5 Flash/Pro models"},
      {"groq", "Groq", "Ultra-fast inference (Llama 3.3, DeepSeek)"},
      {"xai", "xAI", "Grok 3 and Grok 3 Mini"},
      {"openrouter", "OpenRouter", "Access 200+ models via unified API"}
    ]
  end

  @spec default_models_for_provider(String.t()) :: [String.t()]
  def default_models_for_provider(provider_key) do
    case provider_key do
      "ollama" ->
        [
          # 35B, 128K ctx
          "ollama:qwen3.5:35b",
          # 128K ctx, code-focused
          "ollama:qwen3-coder-next:latest",
          # 80B, 128K ctx
          "ollama:qwen3-next:80b",
          # 120B MoE (12B active), 256K ctx
          "ollama:nemotron-3-super:latest",
          # 24B, 128K ctx, code-focused
          "ollama:devstral-small-2:24b",
          # 30B MoE (3B active), 128K ctx
          "ollama:nemotron-cascade-2:30b",
          # 27B, 128K ctx
          "ollama:qwen3.5:27b",
          # 128K ctx
          "ollama:glm-4.7-flash:latest",
          # 32B, 128K ctx
          "ollama:qwen3:32b"
        ]

      "ollama_cloud" ->
        [
          # 120B MoE (12B active), 256K ctx — RECOMMENDED
          "ollama:nemotron-3-super:cloud",
          # 480B, 256K ctx — massive code model
          "ollama:qwen3-coder:480b",
          # 671B, 128K ctx
          "ollama:deepseek-v3.1:671b",
          # 72B, 128K ctx
          "ollama:qwen3.5:72b",
          # MoE, 1M ctx
          "ollama:llama4-maverick:latest",
          # 80B, 128K ctx
          "ollama:qwen3-next:80b",
          # 128K ctx
          "ollama:qwen3-coder-next:latest",
          # 128K ctx
          "ollama:kimi-k2.5:latest",
          # 30B MoE (3B active), 128K ctx
          "ollama:nemotron-cascade-2:30b"
        ]

      "anthropic" ->
        [
          # 200K ctx
          "anthropic:claude-sonnet-4-20250514",
          # 200K ctx
          "anthropic:claude-opus-4-6",
          # 200K ctx
          "anthropic:claude-haiku-4-5-20251001"
        ]

      "openai" ->
        [
          # 1M ctx
          "openai:gpt-4.1",
          # 1M ctx
          "openai:gpt-4.1-mini",
          # 200K ctx, reasoning
          "openai:o3",
          # 200K ctx, reasoning
          "openai:o4-mini",
          # 1M ctx
          "openai:gpt-4.1-nano"
        ]

      "google" ->
        [
          # 1M ctx
          "google:gemini-2.5-flash",
          # 1M ctx
          "google:gemini-2.5-pro",
          # 1M ctx
          "google:gemini-2.0-flash"
        ]

      "groq" ->
        [
          # 128K ctx
          "groq:llama-3.3-70b-versatile",
          # 128K ctx
          "groq:deepseek-r1-distill-llama-70b",
          # 128K ctx
          "groq:llama-4-scout-17b-16e-instruct"
        ]

      "xai" ->
        [
          # 131K ctx
          "xai:grok-3",
          # 131K ctx
          "xai:grok-3-mini"
        ]

      "openrouter" ->
        [
          # 200K ctx
          "openrouter:anthropic/claude-sonnet-4",
          # 200K ctx
          "openrouter:anthropic/claude-opus-4",
          # 1M ctx
          "openrouter:openai/gpt-4.1",
          # 1M ctx
          "openrouter:google/gemini-2.5-pro",
          # 128K ctx
          "openrouter:deepseek/deepseek-r1",
          # 1M ctx
          "openrouter:meta-llama/llama-4-maverick"
        ]

      _ ->
        []
    end
  end

  @model_descriptions %{
    # Ollama local
    "ollama:qwen3.5:35b" => "35B, 128K ctx",
    "ollama:qwen3-coder-next:latest" => "128K ctx, code-focused",
    "ollama:qwen3-next:80b" => "80B, 128K ctx",
    "ollama:nemotron-3-super:latest" => "120B MoE (12B active), 256K ctx",
    "ollama:devstral-small-2:24b" => "24B, 128K ctx, code-focused",
    "ollama:nemotron-cascade-2:30b" => "30B MoE (3B active), 128K ctx",
    "ollama:qwen3.5:27b" => "27B, 128K ctx",
    "ollama:glm-4.7-flash:latest" => "128K ctx, fast",
    "ollama:qwen3:32b" => "32B, 128K ctx",
    # Ollama cloud
    "ollama:nemotron-3-super:cloud" => "120B MoE (12B active), 256K ctx — RECOMMENDED",
    "ollama:qwen3-coder:480b" => "480B, 256K ctx — massive code model",
    "ollama:deepseek-v3.1:671b" => "671B, 128K ctx",
    "ollama:qwen3.5:72b" => "72B, 128K ctx",
    "ollama:llama4-maverick:latest" => "MoE, 1M ctx",
    "ollama:kimi-k2.5:latest" => "128K ctx",
    # Anthropic
    "anthropic:claude-sonnet-4-20250514" => "200K ctx",
    "anthropic:claude-opus-4-6" => "200K ctx, most capable",
    "anthropic:claude-haiku-4-5-20251001" => "200K ctx, fast",
    # OpenAI
    "openai:gpt-4.1" => "1M ctx",
    "openai:gpt-4.1-mini" => "1M ctx, efficient",
    "openai:o3" => "200K ctx, reasoning",
    "openai:o4-mini" => "200K ctx, reasoning",
    "openai:gpt-4.1-nano" => "1M ctx, lightweight",
    # Google
    "google:gemini-2.5-flash" => "1M ctx, fast",
    "google:gemini-2.5-pro" => "1M ctx",
    "google:gemini-2.0-flash" => "1M ctx",
    # Groq
    "groq:llama-3.3-70b-versatile" => "128K ctx, ultra-fast",
    "groq:deepseek-r1-distill-llama-70b" => "128K ctx, reasoning",
    "groq:llama-4-scout-17b-16e-instruct" => "128K ctx",
    # xAI
    "xai:grok-3" => "131K ctx",
    "xai:grok-3-mini" => "131K ctx",
    # OpenRouter
    "openrouter:anthropic/claude-sonnet-4" => "200K ctx",
    "openrouter:anthropic/claude-opus-4" => "200K ctx",
    "openrouter:openai/gpt-4.1" => "1M ctx",
    "openrouter:google/gemini-2.5-pro" => "1M ctx",
    "openrouter:deepseek/deepseek-r1" => "128K ctx",
    "openrouter:meta-llama/llama-4-maverick" => "1M ctx"
  }

  @doc "Returns a short description string for a model (context window, notes)."
  @spec model_description(String.t()) :: String.t()
  def model_description(model_string) do
    @model_descriptions[model_string] || ""
  end

  # ---------------------------------------------------------------------------
  # Model metadata via llm_db
  # ---------------------------------------------------------------------------

  @doc """
  Returns model metadata from llm_db for the configured model.

  The configured model uses "provider:model_id" format (e.g. "anthropic:claude-sonnet-4-20250514"),
  which maps directly to the llm_db model spec format.

  Returns `{:ok, %LLMDB.Model{}}` on success, or `{:error, reason}` when the model
  is not found in the catalog (e.g. Ollama local models, unknown providers).
  """
  @spec model_info(map()) :: {:ok, LLMDB.Model.t()} | {:error, term()}
  def model_info(config) do
    model_spec = model(config)
    LLMDB.model(model_spec)
  rescue
    _ -> {:error, :llm_db_unavailable}
  end

  @doc """
  Estimates session cost in USD given token count and model metadata.

  Uses the `cost.input` rate (per-million-token) from the model struct as a
  conservative approximation — most CLI usage is input-heavy and the output
  rate is typically unavailable without per-message breakdown.

  Returns `nil` when cost data is not available (local models, unknown models).
  """
  @spec estimated_cost(non_neg_integer(), LLMDB.Model.t() | nil) :: float() | nil
  def estimated_cost(_tokens, nil), do: nil

  def estimated_cost(tokens, %LLMDB.Model{cost: %{input: input_rate}})
      when is_number(input_rate) and input_rate > 0 do
    tokens / 1_000_000 * input_rate
  end

  def estimated_cost(_tokens, _model), do: nil

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @spec deep_merge(term(), term()) :: term()
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, lv, rv ->
      deep_merge(lv, rv)
    end)
  end

  def deep_merge(_left, right), do: right
end
