defmodule JidoClaw.CLI.Setup do
  @moduledoc """
  First-time setup wizard. Walks users through provider selection,
  API key configuration, and model choice.
  """

  alias JidoClaw.Config

  @config_dir ".jido"
  @config_file "config.yaml"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Returns true if setup should be triggered (no config or no provider set)."
  def needed?(project_dir) do
    path = config_path(project_dir)

    cond do
      Application.get_env(:jido_claw, :force_setup, false) ->
        true

      not File.exists?(path) ->
        true

      true ->
        case YamlElixir.read_from_file(path) do
          {:ok, config} when is_map(config) -> not Map.has_key?(config, "provider")
          _ -> true
        end
    end
  end

  @doc "Run the interactive setup wizard. Returns the loaded config map."
  def run(project_dir) do
    print_welcome()

    # Step 1: Pick provider
    {provider_key, provider_name} = pick_provider()

    # Step 2: API key (LLM provider)
    api_key_env = configure_api_key(provider_key, provider_name)

    # Step 3: Voyage credential — required regardless of LLM provider.
    # The boot guard enforces this on subsequent app starts. Capturing
    # it here writes the value to `.env` so re-invocations boot
    # cleanly. Exits with non-zero status when the user declines and
    # no key is already set.
    prompt_voyage_key(project_dir)

    # Step 4: Pick model
    model = pick_model(provider_key)

    # Step 5: Workspace policies. The embedding policy is derived
    # from the (now guaranteed) Voyage key — always `:default`. The
    # consolidation policy keeps its explicit Y/N prompt.
    consolidation_policy = pick_consolidation_policy()

    # Step 6: Build config
    config_map =
      build_config(provider_key, model, api_key_env)
      |> Map.put("embedding_policy", "default")
      |> Map.put("consolidation_policy", Atom.to_string(consolidation_policy))

    # Step 7: Test connection
    loaded = Config.deep_merge(Config.load(project_dir), config_map)
    test_connection(loaded, provider_name)

    # Step 8: Save
    write_config(project_dir, config_map)

    IO.puts("\n  \e[32m✓\e[0m  Configuration saved to #{config_path(project_dir)}")
    IO.puts("  \e[2m   Run /setup anytime to reconfigure.\e[0m\n")

    Config.load(project_dir)
  end

  defp pick_consolidation_policy do
    IO.puts("")

    IO.puts(
      "  \e[1mAllow JidoClaw to send transcripts/memory facts to a frontier consolidator? \e[0m"
    )

    IO.puts("  \e[2m   [y]es  [N]o (default disabled)\e[0m")
    IO.puts("")

    case prompt_input("  Consolidation policy [y/N]") do
      v when v in ["", "n", "N", "no"] -> :disabled
      v when v in ["y", "Y", "yes"] -> :default
      _ -> :disabled
    end
  end

  # Capture the Voyage credential. Strict contract: if neither shell
  # env nor user input supplies the key, exit non-zero. The boot guard
  # in `JidoClaw.Embeddings.BootGuard` enforces presence on subsequent
  # app starts.
  defp prompt_voyage_key(project_dir) do
    case System.get_env("VOYAGE_API_KEY") do
      v when is_binary(v) and v != "" ->
        IO.puts("  \e[32m✓\e[0m  Found VOYAGE_API_KEY in environment\n")
        :ok

      _ ->
        IO.puts("")
        IO.puts("  \e[1mVoyage API Key required\e[0m")
        IO.puts("  \e[2mEmbedding/retrieval and memory require Voyage.\e[0m")
        IO.puts("  \e[2m  Set VOYAGE_API_KEY in shell env or paste below.\e[0m")
        IO.puts("")

        case prompt_input("  Paste your Voyage API key (or press Enter to abort)") do
          "" ->
            IO.puts(
              "  \e[31m✗\e[0m  VOYAGE_API_KEY is required. Either provide it now or " <>
                "set it in shell env / .env and re-run `mix jidoclaw --setup`. " <>
                "To run jido_claw without embeddings, set " <>
                "`config :jido_claw, :embeddings_strict_boot, false` in your config."
            )

            System.halt(1)

          key ->
            persist_env_var(project_dir, "VOYAGE_API_KEY", key)
            System.put_env("VOYAGE_API_KEY", key)
            IO.puts("  \e[32m✓\e[0m  VOYAGE_API_KEY persisted to .env and current session\n")
            :ok
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  defp print_welcome do
    IO.puts("")
    IO.puts("  \e[1m\e[36m─── JidoClaw Setup ───\e[0m")
    IO.puts("  \e[2mLet's configure your AI agent platform.\e[0m")
    IO.puts("")
  end

  defp pick_provider do
    providers = Config.available_providers()

    IO.puts("  \e[1mChoose your LLM provider:\e[0m\n")

    providers
    |> Enum.with_index(1)
    |> Enum.each(fn {{_key, name, desc}, idx} ->
      IO.puts("    \e[36m#{idx}.\e[0m #{name} \e[2m— #{desc}\e[0m")
    end)

    IO.puts("")
    choice = prompt_choice("  Provider", 1..length(providers), 1)
    {key, name, _desc} = Enum.at(providers, choice - 1)
    IO.puts("  \e[32m✓\e[0m  #{name}\n")
    {key, name}
  end

  defp configure_api_key("ollama", _name) do
    IO.puts("  \e[2mNo API key needed for local Ollama.\e[0m")
    IO.puts("  \e[2mMake sure Ollama is running: ollama serve\e[0m\n")
    "OLLAMA_API_KEY"
  end

  defp configure_api_key(provider_key, provider_name) do
    env_var = api_key_env_for(provider_key)
    existing = System.get_env(env_var)

    if existing && existing != "" do
      IO.puts("  \e[32m✓\e[0m  Found #{env_var} in environment\n")
      env_var
    else
      IO.puts("  \e[1mAPI Key required for #{provider_name}\e[0m")
      IO.puts("  \e[2mSet the #{env_var} environment variable:\e[0m")
      IO.puts("")
      IO.puts("    \e[33mexport #{env_var}=\"your-key-here\"\e[0m")
      IO.puts("")

      key = prompt_input("  Paste your API key (or press Enter to set later)")

      if key != "" do
        System.put_env(env_var, key)
        IO.puts("  \e[32m✓\e[0m  Key set for this session")

        IO.puts(
          "  \e[2m   Add export #{env_var}=... to your shell profile for persistence.\e[0m\n"
        )
      else
        IO.puts("  \e[33m⚠\e[0m  No key set. You'll need to set #{env_var} before use.\n")
      end

      env_var
    end
  end

  defp pick_model(provider_key) do
    models = Config.default_models_for_provider(provider_key)

    if models == [] do
      prompt_input("  Enter model string (e.g., provider:model-name)")
    else
      IO.puts("  \e[1mChoose your default model:\e[0m\n")

      models
      |> Enum.with_index(1)
      |> Enum.each(fn {model, idx} ->
        # Show just the model part after provider:
        display =
          case String.split(model, ":", parts: 2) do
            [_, name] -> name
            _ -> model
          end

        desc = Config.model_description(model)
        desc_part = if desc != "", do: " \e[2m— #{desc}\e[0m", else: ""
        IO.puts("    \e[36m#{idx}.\e[0m #{display}#{desc_part}")
      end)

      IO.puts("")
      choice = prompt_choice("  Model", 1..length(models), 1)
      model = Enum.at(models, choice - 1)

      display =
        case String.split(model, ":", parts: 2) do
          [_, name] -> name
          _ -> model
        end

      IO.puts("  \e[32m✓\e[0m  #{display}\n")
      model
    end
  end

  defp build_config(provider_key, model, _api_key_env) do
    # Normalize provider key (ollama_cloud -> ollama)
    actual_provider = if provider_key == "ollama_cloud", do: "ollama", else: provider_key

    base = %{
      "provider" => actual_provider,
      "model" => model,
      "max_iterations" => 25,
      "timeout" => 120_000
    }

    case provider_key do
      "ollama" ->
        base

      "ollama_cloud" ->
        put_in(base, ["providers"], %{
          "ollama" => %{"base_url" => "https://ollama.com"}
        })

      _ ->
        base
    end
  end

  defp test_connection(config, provider_name) do
    IO.write("  Testing connection to #{provider_name}...")

    case Config.check_provider(config) do
      :ok ->
        IO.puts(" \e[32m✓\e[0m")

      {:error, :unauthorized} ->
        IO.puts(" \e[31m✗\e[0m")
        IO.puts("  \e[31mAPI key invalid or missing.\e[0m")
        IO.puts("  \e[2mYou can fix this later and re-run /setup.\e[0m")

      {:error, :unreachable} ->
        IO.puts(" \e[33m⚠\e[0m")
        IO.puts("  \e[33mProvider not reachable. Check your connection.\e[0m")
        IO.puts("  \e[2mYou can continue anyway and re-run /setup later.\e[0m")
    end
  end

  # ---------------------------------------------------------------------------
  # Config persistence
  # ---------------------------------------------------------------------------

  @doc "Write configuration map to .jido/config.yaml"
  def write_config(project_dir, config_map) do
    dir = Path.join(project_dir, @config_dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, @config_file)

    yaml = map_to_yaml(config_map)
    File.write!(path, yaml)
  end

  @doc """
  Persist `KEY=value` to `<project_dir>/.env`. Updates an existing
  line in place (preserving order, comments, and blank lines) or
  appends a new one. Atomic: writes via `<.env>.tmp` + rename.
  """
  def persist_env_var(project_dir, key, value)
      when is_binary(project_dir) and is_binary(key) and is_binary(value) do
    env_path = Path.join(project_dir, ".env")

    existing =
      case File.read(env_path) do
        {:ok, content} -> content
        _ -> ""
      end

    new_content = upsert_env_line(existing, key, value)

    tmp = env_path <> ".tmp"
    File.write!(tmp, new_content)
    File.rename!(tmp, env_path)
    :ok
  end

  defp upsert_env_line(content, key, value) do
    lines = String.split(content, "\n")
    prefix = key <> "="
    serialized = key <> "=" <> serialize_env_value(value)

    {updated, found?} =
      Enum.map_reduce(lines, false, fn line, found ->
        if not found and matches_key?(line, prefix) do
          {serialized, true}
        else
          {line, found}
        end
      end)

    cond do
      found? ->
        Enum.join(updated, "\n")

      content == "" ->
        serialized <> "\n"

      String.ends_with?(content, "\n") ->
        content <> serialized <> "\n"

      true ->
        content <> "\n" <> serialized <> "\n"
    end
  end

  defp matches_key?(line, prefix) do
    trimmed = String.trim_leading(line)
    String.starts_with?(trimmed, prefix) and not String.starts_with?(trimmed, "#")
  end

  defp serialize_env_value(value) do
    if Regex.match?(~r/[\s"'#]/, value) do
      "\"" <> String.replace(value, "\"", "\\\"") <> "\""
    else
      value
    end
  end

  defp config_path(project_dir) do
    Path.join([project_dir, @config_dir, @config_file])
  end

  # Simple YAML serializer for flat/nested string maps
  defp map_to_yaml(map, indent \\ 0) do
    pad = String.duplicate("  ", indent)

    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("\n", fn {key, value} ->
      cond do
        is_map(value) ->
          "#{pad}#{key}:\n#{map_to_yaml(value, indent + 1)}"

        is_integer(value) ->
          "#{pad}#{key}: #{value}"

        is_binary(value) ->
          if String.contains?(value, ":") do
            "#{pad}#{key}: \"#{value}\""
          else
            "#{pad}#{key}: #{value}"
          end

        true ->
          "#{pad}#{key}: #{inspect(value)}"
      end
    end)
    |> then(&(&1 <> "\n"))
  end

  # ---------------------------------------------------------------------------
  # IO helpers
  # ---------------------------------------------------------------------------

  defp prompt_choice(label, range, default) do
    raw = IO.gets("#{label} [#{default}]: ")
    input = if is_binary(raw), do: String.trim(raw), else: ""

    case Integer.parse(input) do
      {n, ""} when is_integer(n) ->
        if n in range do
          n
        else
          IO.puts("  \e[31mInvalid choice. Try again.\e[0m")
          prompt_choice(label, range, default)
        end

      _ when input == "" ->
        default

      _ ->
        IO.puts("  \e[31mInvalid choice. Try again.\e[0m")
        prompt_choice(label, range, default)
    end
  end

  defp prompt_input(label) do
    raw = IO.gets("#{label}: ")
    if is_binary(raw), do: String.trim(raw), else: ""
  end

  defp api_key_env_for("ollama"), do: "OLLAMA_API_KEY"
  defp api_key_env_for("ollama_cloud"), do: "OLLAMA_API_KEY"
  defp api_key_env_for("anthropic"), do: "ANTHROPIC_API_KEY"
  defp api_key_env_for("openai"), do: "OPENAI_API_KEY"
  defp api_key_env_for("google"), do: "GOOGLE_API_KEY"
  defp api_key_env_for("groq"), do: "GROQ_API_KEY"
  defp api_key_env_for("xai"), do: "XAI_API_KEY"
  defp api_key_env_for("openrouter"), do: "OPENROUTER_API_KEY"
  defp api_key_env_for(_), do: "API_KEY"
end
