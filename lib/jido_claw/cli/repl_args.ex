defmodule JidoClaw.CLI.ReplArgs do
  @moduledoc """
  Strict argument parsing for the REPL entry points (`mix jidoclaw` and the
  `jido` escript catch-alls).

  Pure — no IO, no `System.halt`. The entry files own printing the usage
  message and exiting 2, mirroring the `run` subcommand's exit contract
  (`JidoClaw.CLI.RunCommand`). Before this, a bad flag (`--bogus`), a
  valueless or empty `--resume` (`--resume`, `--resume=`, `--resume ""`), or
  a `--resume <uuid> --continue` conflict silently booted a fresh/default
  REPL while the user believed they had requested history.

  Positional-dir semantics are deliberately unchanged: the first non-flag
  positional is a directory candidate via
  `JidoClaw.Startup.resolve_project_dir_from_argv/1`, which still falls back
  to cwd for a non-directory arg.
  """

  alias JidoClaw.Startup

  @doc """
  Parse REPL argv into `{:ok, %{project_dir, resume, continue}}` or
  `{:usage, message}`.

  Usage errors: any unknown flag or a bare valueless `--resume` (both land
  in `OptionParser`'s invalid list); an empty/blank resume value —
  `--resume=` and `--resume ""` parse as `resume: ""` with NO invalid
  entries, so they need their own branch; and the `--resume <uuid>
  --continue` conflict (previously resolved silently in `--resume`'s
  favor).
  """
  @spec parse([String.t()]) ::
          {:ok, %{project_dir: String.t(), resume: String.t() | nil, continue: boolean()}}
          | {:usage, String.t()}
  def parse(args) when is_list(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [resume: :string, continue: :boolean])

    resume = Keyword.get(opts, :resume)
    continue = Keyword.get(opts, :continue, false)

    cond do
      invalid != [] ->
        flags = Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)
        {:usage, "invalid option(s): #{flags}"}

      is_binary(resume) and String.trim(resume) == "" ->
        {:usage, "--resume requires a session uuid"}

      is_binary(resume) and continue ->
        {:usage, "--resume and --continue are mutually exclusive"}

      true ->
        # Positionals only — resolve_project_dir_from_argv takes the first
        # non-flag arg and does not skip flag VALUES, so feeding it raw argv
        # would inspect `--resume`'s uuid as a directory candidate.
        {:ok,
         %{
           project_dir: Startup.resolve_project_dir_from_argv(positional),
           resume: resume,
           continue: continue
         }}
    end
  end
end
