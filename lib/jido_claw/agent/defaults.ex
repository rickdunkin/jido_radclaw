defmodule JidoClaw.Agent.Defaults do
  @moduledoc """
  `use JidoClaw.Agent.Defaults` is a thin wrapper around
  `use Jido.AI.Agent` that injects the `Recorder` plugin.

  Used by the main `JidoClaw.Agent` and the seven specialized agent
  workers (Coder, Reviewer, Researcher, Refactorer, Verifier,
  TestRunner, DocsWriter). The Recorder plugin bridges the agent's
  `ai.*` mailbox signals onto `JidoClaw.SignalBus` so the
  `Conversations.Recorder` GenServer can persist tool activity into
  Postgres.

  All `Jido.AI.Agent` options pass through unchanged. Per-site
  `:plugins` lists are appended to the base plugins, so existing
  plugin configurations are preserved.

  ## Why a macro

  Without this layer, every `use Jido.AI.Agent` site would need an
  explicit `plugins: [JidoClaw.AgentServerPlugin.Recorder, ...]`
  entry. Adding a new agent worker without that line silently drops
  its tool activity from the persistence layer. The macro makes the
  Recorder plugin opt-out by editing one place — and the §G
  acceptance test ("Recorder plugin coverage CI gate") asserts every
  agent declaration site routes through this wrapper.
  """

  defmacro __using__(opts) do
    base_plugins = [JidoClaw.AgentServerPlugin.Recorder]
    opts = Keyword.update(opts, :plugins, base_plugins, &(base_plugins ++ &1))

    quote do
      use Jido.AI.Agent, unquote(opts)
    end
  end
end
