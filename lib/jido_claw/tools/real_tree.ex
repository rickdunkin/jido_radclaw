defmodule JidoClaw.Tools.RealTree do
  @moduledoc """
  Shared `Resolver` opts for the read-only real-tree tools (AR-8b-2 F3):
  `read_real_file` / `search_real_code` / `list_real_directory`.

  A sketch worker runs jailed to `<real>/.prototypes/<uuid>/` (`sandbox:
  :prototype` or `:docker`); these tools let it be *informed* by the real
  project tree without being able to *mutate* it (there is deliberately no
  write/edit counterpart). `resolver_opts/1`:

    * fails **closed** unless `tool_context[:sandbox]` is `:prototype` or
      `:docker` — the tools are inert on any non-sketch surface (the main
      agent, a normal worker),
    * derives `<real>` via `JidoClaw.VFS.Sandbox.real_root/1` (which re-validates
      the `.prototypes/<uuid>/` root, rejecting lexical/symlink escapes), and
    * jails reads with `project_dir: real_dir` + `local_only: true` (remote
      schemes forbidden — local real tree only) + `workspace_id: nil` (no VFS
      workspace mount; reads resolve straight against the real base).

  ## Known limitation

  These tools can read sensitive files in the real tree (e.g. `.env`), bounded
  by: no write counterpart (mutation is structurally impossible — every write
  still lands in the `.prototypes/<id>/` sandbox), no network egress (remote
  schemes forbidden here, writes jailed to the sandbox), and the
  `JidoClaw.Tools.OutputRedaction` pipeline redacting secrets in tool output.
  Path-filtering the real tree is a reasonable future hardening; out of scope.
  """

  alias JidoClaw.VFS.Sandbox

  @doc """
  Derive read-only `Resolver` opts jailed to the real project base, or
  `{:error, reason}` when the context is not a valid sketch sandbox.
  """
  @spec resolver_opts(map() | nil) :: {:ok, keyword()} | {:error, term()}
  def resolver_opts(tool_context) when is_map(tool_context) do
    case Map.get(tool_context, :sandbox) do
      sandbox when sandbox in [:prototype, :docker] ->
        case Sandbox.real_root(Map.get(tool_context, :project_dir)) do
          {:ok, real_dir} ->
            {:ok, [project_dir: real_dir, local_only: true, workspace_id: nil]}

          # inspect/1, not raw interpolation: real_root/1 is specced term(), so a
          # tuple reason would raise under `#{...}`.
          {:error, reason} ->
            {:error,
             "real-tree scope invalid (#{inspect(reason)}): the sketch sandbox project_dir is not a validated .prototypes/<uuid>/ root"}
        end

      _ ->
        {:error,
         "real-tree tools require a sketch sandbox (sandbox: :prototype or :docker) context — refusing to read the real tree"}
    end
  end

  def resolver_opts(_),
    do:
      {:error,
       "real-tree tools require a sketch sandbox (sandbox: :prototype or :docker) context — refusing to read the real tree"}
end
