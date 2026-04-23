# Patch for jido_shell — Jido.Shell.Command.Registry
#
# The upstream registry hard-codes its built-in command map with no
# extensibility seam. JidoClaw needs to register additional commands
# (e.g. `jido status`) that are discoverable through the same `help`
# listing and dispatched by `Jido.Shell.CommandRunner` alongside the
# built-ins.
#
# This module redefines `Jido.Shell.Command.Registry` so `lookup/1`,
# `list/0`, and `commands/0` all union the built-ins with whatever is
# stored under `Application.get_env(:jido_shell, :extra_commands, %{})`.
# Built-ins win on name collision (see `commands/0`): the extras map is
# the first argument to `Map.merge/2` and the built-ins override it.
#
# Strict compile relies on `elixirc_options: [ignore_module_conflict: true]`
# declared in mix.exs to suppress the "redefining module" warning this
# intentionally triggers — see the comment there for the full patch
# inventory this flag covers.
#
# ## Usage
#
# Callers contributing commands at runtime (rather than through
# `config/config.exs`) must `Map.merge/2` with the existing value so
# other consumers' entries are preserved:
#
#     current = Application.get_env(:jido_shell, :extra_commands, %{})
#     Application.put_env(:jido_shell, :extra_commands, Map.merge(current, %{...}))
#
# ## Removal trigger
#
# Delete this file when `jido_shell` ships a release containing a
# compatible `:extra_commands` hook and we upgrade the dep. No
# call-site changes are needed: `config/config.exs` and the command
# modules can stay as-is.
defmodule Jido.Shell.Command.Registry do
  @moduledoc """
  Registry for looking up command modules by name.

  NOTE: This is a patched copy — see lib/jido_claw/core/jido_shell_registry_patch.ex
  header. The patch adds a `:extra_commands` extensibility hook to the
  otherwise hard-coded built-in map.
  """

  @built_ins %{
    "echo" => Jido.Shell.Command.Echo,
    "pwd" => Jido.Shell.Command.Pwd,
    "ls" => Jido.Shell.Command.Ls,
    "cat" => Jido.Shell.Command.Cat,
    "cd" => Jido.Shell.Command.Cd,
    "mkdir" => Jido.Shell.Command.Mkdir,
    "write" => Jido.Shell.Command.Write,
    "bash" => Jido.Shell.Command.Bash,
    "sleep" => Jido.Shell.Command.Sleep,
    "seq" => Jido.Shell.Command.Seq,
    "help" => Jido.Shell.Command.Help,
    "env" => Jido.Shell.Command.Env,
    "rm" => Jido.Shell.Command.Rm,
    "cp" => Jido.Shell.Command.Cp
  }

  @doc """
  Looks up a command module by name.

  Returns `{:ok, module}` or `{:error, :not_found}`.
  """
  @spec lookup(String.t()) :: {:ok, module()} | {:error, :not_found}
  def lookup(name) do
    case commands()[name] do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  @doc """
  Returns a list of all available command names.
  """
  @spec list() :: [String.t()]
  def list do
    Map.keys(commands())
  end

  @doc """
  Returns the full command registry map, unioning built-ins with any
  commands registered under `:extra_commands`. Built-ins take precedence
  on name collision.
  """
  @spec commands() :: %{String.t() => module()}
  def commands do
    extras = Application.get_env(:jido_shell, :extra_commands, %{})
    Map.merge(extras, @built_ins)
  end

  @doc """
  Returns the `:extra_commands` config map with any names shadowed by
  built-ins removed. Built-ins always win in `commands/0`; callers that
  reason about "which commands are actually extension-backed" should use
  this helper rather than reading `:extra_commands` directly.
  """
  @spec extra_commands() :: %{String.t() => module()}
  def extra_commands do
    :jido_shell
    |> Application.get_env(:extra_commands, %{})
    |> Map.drop(Map.keys(@built_ins))
  end
end
