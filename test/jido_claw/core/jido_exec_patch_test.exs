defmodule JidoClaw.Core.JidoExecPatchTest do
  @moduledoc """
  PORT-PD1-2-EXEC drift + fidelity guards for BOTH forked packages:

    * package pins (mix.lock version + outer checksum) for jido_action AND
      jido_mcp — the forks delegate at runtime to sibling dep modules, so a
      collaborator-only dep change must also fail loud;
    * source anchors (the exec generator's compile-time sha gate constant,
      the runtime fork's `runtime.ex` sha);
    * the runtime-fork parity reconstruction (committed file == upstream +
      the enumerated transformations, format-normalized);
    * the fork's marking semantics (no-opt parity, with-opt marking, the
      canonical-envelope stamp condition, retry-gate neutrality);
    * raise-path stacktrace byte fidelity (the generator's reason for
      existing);
    * the compiler stage's incremental-build ownership (path-parameterized,
      NEVER against the live build's BEAM — partitions share one build dir);
    * the Repo POOL_SIZE seam, the license artifacts, the pre-boot
      `--third-party-licenses` CLI route, and the checked
      `start_app_or_halt!/0` failure arms.
  """

  # async: false — the incremental-build rows compile stub Jido.Exec BEAMs
  # into the VM (restored via DependencyPatches.ensure_loaded!/0), and the
  # CLI rows mutate global app env + (mcp branch) the default logger handler.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Jido.Action.Error, as: JidoActionError
  alias Jido.MCP.Server.Runtime
  alias JidoClaw.CLI.Main
  alias JidoClaw.Core.DependencyPatches
  alias JidoClaw.Core.JidoExecPatch
  alias JidoClaw.Core.ThirdPartyLicenses
  alias JidoClaw.MCPServer.ErrorBoundary

  @project_root Path.expand("../../..", __DIR__)

  # ── Pinned dep coordinates (re-port procedure: PORT-PD1-2-EXEC.md) ───────
  @jido_action_version "2.3.1"
  @jido_action_outer_checksum "bf186bef7068da63267b1d6a45e6905a729aeedc2d4d0c735835911e346032c4"
  @jido_mcp_version "1.1.0"
  @jido_mcp_outer_checksum "20c7aea003990e2e641483b24f829c91ae60d93f5b5376a7eb24fd1118ff1dc0"
  @jido_mcp_runtime_sha256 "b360554be943b3b9d02eb4c62d6579449aa70aca27c8668392876c0899b86941"

  @exec_opts_base [log_level: :emergency, timeout: 0, max_retries: 0]

  # ── Scripted actions ──────────────────────────────────────────────────────

  defmodule EnvelopeErrorTool do
    @moduledoc false
    use Jido.Action,
      name: "exec_patch_envelope_tool",
      description: "Test-only canonical-envelope error producer.",
      schema: []

    @impl Jido.Action
    def run(_params, _context) do
      {:error, %{code: :unknown_skill, message: "no such skill", details: %{retry: false}}}
    end
  end

  defmodule NonEnvelopeErrorTool do
    @moduledoc false
    use Jido.Action,
      name: "exec_patch_non_envelope_tool",
      description: "Test-only non-envelope map error producer.",
      schema: []

    @impl Jido.Action
    def run(_params, _context), do: {:error, %{foo: 1, message: "not an envelope"}}
  end

  # NON-exception struct whose fields extract to the colliding
  # %{code:, details:} details shape — the stamp-condition negative.
  defmodule CollidingStruct do
    @moduledoc false
    defstruct [:message, :code, :details]
  end

  defmodule CollidingStructTool do
    @moduledoc false
    use Jido.Action,
      name: "exec_patch_colliding_tool",
      description: "Test-only colliding-struct error producer.",
      schema: []

    alias JidoClaw.Core.JidoExecPatchTest.CollidingStruct

    @impl Jido.Action
    def run(_params, _context) do
      {:error, %CollidingStruct{message: "boom", code: :unknown_skill, details: %{}}}
    end
  end

  defmodule RaisingTool do
    @moduledoc false
    use Jido.Action,
      name: "exec_patch_raising_tool",
      description: "Test-only raiser for the stacktrace-fidelity rows.",
      schema: []

    @impl Jido.Action
    def run(_params, _context), do: raise("exec patch boom")
  end

  # ── Package drift guards ──────────────────────────────────────────────────

  defp lock_entry(app) do
    # with_diagnostics: evaluating mix.lock otherwise PRINTS one benign
    # quoted-keyword warning per lock entry.
    {lock, _diagnostics} =
      Code.with_diagnostics(fn ->
        {lock, _bindings} = Code.eval_file(Path.join(@project_root, "mix.lock"))
        lock
      end)

    Map.fetch!(lock, app)
  end

  test "jido_action stays pinned at #{@jido_action_version} with the locked outer checksum" do
    assert {:hex, :jido_action, @jido_action_version, _inner, _managers, _deps, "hexpm", outer} =
             lock_entry(:jido_action)

    assert outer == @jido_action_outer_checksum,
           "jido_action moved — re-port the Jido.Exec fork per " <>
             "docs/exploration/pms/pad/PORT-PD1-2-EXEC.md, then update these pins"
  end

  test "jido_mcp stays pinned at #{@jido_mcp_version} with the locked outer checksum" do
    assert {:hex, :jido_mcp, @jido_mcp_version, _inner, _managers, _deps, "hexpm", outer} =
             lock_entry(:jido_mcp)

    assert outer == @jido_mcp_outer_checksum,
           "jido_mcp moved — re-port lib/jido_claw/core/jido_mcp_runtime_patch.ex per " <>
             "docs/exploration/pms/pad/PORT-PD1-2-EXEC.md, then update these pins " <>
             "(the ~> 1.0 requirement permits bumps the committed fork would go stale on)"
  end

  # ── Source anchors ────────────────────────────────────────────────────────

  defp file_sha256(relative_path) do
    Base.encode16(
      :crypto.hash(:sha256, File.read!(Path.join(@project_root, relative_path))),
      case: :lower
    )
  end

  test "the exec generator's compile-time gate pin exists and matches the current dep source" do
    assert JidoExecPatch.pinned_upstream_sha256() ==
             file_sha256("deps/jido_action/lib/jido_action/exec.ex")
  end

  test "the runtime fork's upstream source anchor holds" do
    assert file_sha256("deps/jido_mcp/lib/jido_mcp/server/runtime.ex") ==
             @jido_mcp_runtime_sha256,
           "jido_mcp's runtime.ex moved — re-verify every copied clause of " <>
             "lib/jido_claw/core/jido_mcp_runtime_patch.ex against the new source, " <>
             "then update this anchor (PORT-PD1-2-EXEC.md)"
  end

  # ── Runtime-fork parity reconstruction ────────────────────────────────────
  # The committed fork must equal upstream + EXACTLY these transformations —
  # an accidental edit anywhere else in the ~300-line copy (authorization,
  # resource/prompt handling, rescue conversion) fails this row while the
  # targeted provenance tests stay green.

  @runtime_fork_header """
  # Patch for jido_mcp — Jido.MCP.Server.Runtime
  #
  # Verbatim port of upstream jido_mcp's server runtime
  # (deps/jido_mcp/lib/jido_mcp/server/runtime.ex) with TWO surgical changes
  # layered in:
  #   1. The two `{:error, ...}` arms of `handle_tool_call/5` route through
  #      `JidoClaw.MCPServer.ErrorBoundary.error_response(reason, server_module,
  #      token)` instead of the flat `Response.tool() |> Response.error(inspect(reason))`.
  #      For the PUBLIC server (JidoClaw.MCPServer) the boundary emits the
  #      additive dual-content shape — content[0] the byte-identical legacy
  #      inspect text, content[1] the canonical registry-enforced JSON envelope
  #      (pad PD1-2, served-surface v1.3). Every OTHER server riding this
  #      runtime (memory consolidator, Forge deposit server) keeps the
  #      byte-identical legacy single-item arm inside the boundary.
  #   2. Wrap-provenance threading: `handle_tool_call/5` mints a per-call
  #      token via `ErrorBoundary.mint_wrap_token(server_module)` (a ref for
  #      the PUBLIC server only — unconditional minting would put marker keys
  #      into the consolidator/deposit servers' byte-pinned legacy arms; nil
  #      everywhere else), passes it to the forked `Jido.Exec.run/4` as
  #      `ErrorBoundary.exec_opts(token)` so exec's map-wrap arms can stamp a
  #      canonical envelope's wrap, and threads the same token to the boundary
  #      as the tier-1 witness (detached on exact ref identity there). Policy
  #      lives in the boundary; this patch just threads. Port provenance:
  #      docs/exploration/pms/pad/PORT-PD1-2-EXEC.md.
  #
  # Everything else — registration, resource/prompt handling, the outer
  # rescue/catch protocol-error conversion, response/prompt helpers — is
  # ported verbatim so the patch stays behavior-equivalent for all non-error
  # paths.
  #
  # Strict compile relies on `elixirc_options: [ignore_module_conflict: true]`
  # in mix.exs to suppress the "redefining module" warning this intentionally
  # triggers; boot-time force-load + release BEAM relocation are driven by
  # `JidoClaw.Core.DependencyPatches.patched_modules/0`. Remove once jido_mcp
  # offers an error-rendering seam (e.g. a per-server error formatter callback)
  # that lets the boundary hook in without redefining the runtime.
  """

  @runtime_fork_disable_block """
    # Verbatim upstream port: the bare rescues, explicit try blocks, apply/2,
    # and single-function pipes below are jido_mcp's own idioms, kept
    # byte-equivalent so the patch diff stays exactly the header, the
    # ErrorBoundary alias, the token mint + exec-opts threading, and the two
    # error arms (the parity test reconstructs this file from upstream by
    # those transformations alone).
    # reach:disable-for-this-file bare_rescue
    # credo:disable-for-this-file Credo.Check.Refactor.Apply
    # credo:disable-for-this-file Credo.Check.Readability.PreferImplicitTry
    # credo:disable-for-this-file Credo.Check.Readability.SinglePipe
  """

  @upstream_exec_call """
             {:ok, module} <- find_tool(tool_modules, name) do
          case Jido.Exec.run(module, arguments, build_action_context(frame)) do
  """

  @patched_exec_call """
             {:ok, module} <- find_tool(tool_modules, name) do
          # PATCH change 2: per-call wrap-provenance token (public server →
          # ref; every other server → nil, opts stay []).
          token = ErrorBoundary.mint_wrap_token(server_module)

          case Jido.Exec.run(
                 module,
                 arguments,
                 build_action_context(frame),
                 ErrorBoundary.exec_opts(token)
               ) do
  """

  @upstream_error_arms """
            {:error, reason} ->
              {:reply, Response.tool() |> Response.error(inspect(reason)), frame}

            {:error, reason, _directives} ->
              {:reply, Response.tool() |> Response.error(inspect(reason)), frame}
  """

  @patched_error_arms """
            # PATCH change 1: error arms route through the served-MCP error
            # boundary (public server → dual-content structured shape; other
            # servers → byte-identical legacy arm).
            {:error, reason} ->
              {:reply, ErrorBoundary.error_response(reason, server_module, token), frame}

            {:error, reason, _directives} ->
              {:reply, ErrorBoundary.error_response(reason, server_module, token), frame}
  """

  defp replace_once!(source, old, new) do
    case String.split(source, old) do
      [prefix, suffix] ->
        prefix <> new <> suffix

      parts ->
        flunk(
          "parity transformation matched #{length(parts) - 1} times (expected exactly 1):\n#{old}"
        )
    end
  end

  defp format!(source), do: IO.iodata_to_binary(Code.format_string!(source))

  test "the committed runtime fork IS upstream + the enumerated transformations (format-normalized)" do
    upstream =
      File.read!(Path.join(@project_root, "deps/jido_mcp/lib/jido_mcp/server/runtime.ex"))

    committed =
      File.read!(Path.join(@project_root, "lib/jido_claw/core/jido_mcp_runtime_patch.ex"))

    expected =
      (@runtime_fork_header <> upstream)
      |> replace_once!(
        "defmodule Jido.MCP.Server.Runtime do\n",
        "defmodule Jido.MCP.Server.Runtime do\n" <> @runtime_fork_disable_block
      )
      |> replace_once!(
        "  alias Jido.Action.Schema\n",
        "  alias Jido.Action.Schema\n  alias JidoClaw.MCPServer.ErrorBoundary\n"
      )
      |> replace_once!(@upstream_exec_call, @patched_exec_call)
      |> replace_once!(@upstream_error_arms, @patched_error_arms)

    assert format!(expected) == format!(committed),
           "the committed runtime fork drifted from upstream + the enumerated " <>
             "transformations — either revert the accidental edit or add the new " <>
             "transformation HERE deliberately (and to the fork's header inventory)"
  end

  # ── Fork marking semantics ────────────────────────────────────────────────

  test "the forked Jido.Exec is the loaded module (build marker exported, pins current)" do
    assert {:module, Jido.Exec} = Code.ensure_loaded(Jido.Exec)
    assert function_exported?(Jido.Exec, :__jido_claw_patch_info__, 0)

    info = Jido.Exec.__jido_claw_patch_info__()
    assert info[:upstream_sha256] == JidoExecPatch.pinned_upstream_sha256()
    assert info[:patch_revision] == JidoExecPatch.patch_revision()
  end

  test "mint_wrap_token is public-server-only; exec_opts pins the opt literal" do
    assert is_reference(ErrorBoundary.mint_wrap_token(JidoClaw.MCPServer))
    assert ErrorBoundary.mint_wrap_token(JidoClaw.Memory.Consolidator.MCPServer) == nil
    assert ErrorBoundary.mint_wrap_token(:not_a_server) == nil

    token = make_ref()
    assert ErrorBoundary.exec_opts(token) == [jido_claw_wrap_provenance: token]
    assert ErrorBoundary.exec_opts(nil) == []
  end

  test "no-opt parity: an envelope wrap carries NO marker key (every non-served caller)" do
    assert {:error, wrapped} = Jido.Exec.run(EnvelopeErrorTool, %{}, %{}, @exec_opts_base)

    assert wrapped.details.code == :unknown_skill
    refute Map.has_key?(wrapped.details, :__jido_claw_exec_wrapped__)
  end

  test "with-opt marking: the wrap carries EXACTLY the minted ref under the marker key" do
    token = make_ref()
    opts = @exec_opts_base ++ ErrorBoundary.exec_opts(token)

    assert {:error, wrapped} = Jido.Exec.run(EnvelopeErrorTool, %{}, %{}, opts)
    assert wrapped.details[:__jido_claw_exec_wrapped__] === token
  end

  test "stamp-condition negatives: non-envelope maps and colliding structs never mark, even with the opt" do
    token = make_ref()
    opts = @exec_opts_base ++ ErrorBoundary.exec_opts(token)

    assert {:error, non_envelope} = Jido.Exec.run(NonEnvelopeErrorTool, %{}, %{}, opts)
    refute Map.has_key?(non_envelope.details, :__jido_claw_exec_wrapped__)

    assert {:error, colliding} = Jido.Exec.run(CollidingStructTool, %{}, %{}, opts)
    # The struct clause extracted the colliding %{code:, details:} shape...
    assert colliding.details.code == :unknown_skill
    assert Map.has_key?(colliding.details, :details)
    # ...but the pre-wrap term was no envelope: the witness attests
    # envelopes only.
    refute Map.has_key?(colliding.details, :__jido_claw_exec_wrapped__)
  end

  test "an Instruction-borne junk value under the opt key never marks (is_reference guard)" do
    instruction = %Jido.Instruction{
      action: EnvelopeErrorTool,
      params: %{},
      context: %{},
      opts: [{:jido_claw_wrap_provenance, "junk-not-a-ref"} | @exec_opts_base]
    }

    assert {:error, wrapped} = Jido.Exec.run(instruction)
    refute Map.has_key?(wrapped.details, :__jido_claw_exec_wrapped__)
  end

  test "retry-gate neutrality: the marker is inert to retryable?/1's hint walk" do
    token = make_ref()

    for hint_details <- [%{retry: false}, %{}] do
      unmarked = JidoActionError.execution_error("m", %{code: :x, details: hint_details})

      marked =
        JidoActionError.execution_error("m", %{
          code: :x,
          details: hint_details,
          __jido_claw_exec_wrapped__: token
        })

      assert JidoActionError.retryable?(marked) == JidoActionError.retryable?(unmarked),
             "marked and unmarked wraps must classify identically (hint #{inspect(hint_details)})"
    end
  end

  # ── Raise-path stacktrace byte fidelity ───────────────────────────────────

  test "no-opt raise path: Jido.Exec frames carry the UPSTREAM file string and lines" do
    assert {:error, err} = Jido.Exec.run(RaisingTool, %{}, %{}, @exec_opts_base)

    exec_frames = for {Jido.Exec, _f, _a, location} <- err.details.stacktrace, do: location
    assert exec_frames != [], "expected Jido.Exec frames in the embedded stacktrace"

    for location <- exec_frames do
      assert Keyword.get(location, :file) == ~c"lib/jido_action/exec.ex"
      assert is_integer(Keyword.get(location, :line))
    end
  end

  test "runtime path: content[0] for a raising tool renders the upstream path, never the generator's" do
    capture_log(fn ->
      assert {:reply, response, _frame} =
               Runtime.handle_tool_call(
                 [RaisingTool],
                 "exec_patch_raising_tool",
                 %{},
                 %Frame{},
                 JidoClaw.MCPServer
               )

      out = Response.to_protocol(response)
      assert %{"text" => legacy} = hd(out["content"])

      assert legacy =~ "lib/jido_action/exec.ex"
      # The generator's own file must never appear in a frame (".ex" suffix:
      # the RaisingTool's own frame legitimately carries THIS test file's
      # jido_exec_patch_test.exs name).
      refute legacy =~ "jido_exec_patch.ex"
    end)
  end

  # ── Incremental-build ownership (path-parameterized; NEVER the live BEAM) ─
  # precommit runs four partitions against ONE shared build dir — mutating
  # the suite's active Elixir.Jido.Exec.beam could hand another partition the
  # upstream copy, and a failed row would leave the shared build corrupted.

  defp fixture_source_path do
    Path.join(@project_root, JidoExecPatch.upstream_source_path())
  end

  # Compile a stub Jido.Exec carrying only the persisted marker (attribute
  # staleness variants), then IMMEDIATELY restore the real fork into the VM.
  defp stub_exec_beam(info) do
    source = """
    defmodule Jido.Exec do
      @moduledoc false
      Module.register_attribute(__MODULE__, :jido_claw_patch_info, persist: true)
      @jido_claw_patch_info #{inspect(info)}
      def __jido_claw_patch_info__, do: @jido_claw_patch_info
    end
    """

    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      [{Jido.Exec, binary}] = Code.compile_string(source, "jido_exec_stub.exs")
      binary
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
      # Restore the real fork (and the other patched modules) into the VM.
      DependencyPatches.ensure_loaded!()
    end
  end

  @tag :tmp_dir
  test "an upstream BEAM at the target regenerates; a current one verifies", %{tmp_dir: tmp} do
    target = Path.join(tmp, "Elixir.Jido.Exec.beam")
    upstream_beam = Application.app_dir(:jido_action, "ebin/Elixir.Jido.Exec.beam")
    File.cp!(upstream_beam, target)

    refute JidoExecPatch.patched_beam_current?(target)
    # The empty diagnostics list is a canary: the pinned fork compiles
    # warning-free today, and the captured list is what the compiler task
    # threads into the strict gate — a non-empty list here means the fork
    # itself started warning.
    assert {:generated, []} = JidoExecPatch.verify_or_regenerate!(fixture_source_path(), target)
    assert JidoExecPatch.patched_beam_current?(target)
    assert :current = JidoExecPatch.verify_or_regenerate!(fixture_source_path(), target)
  end

  @tag :tmp_dir
  test "a stale upstream-sha marker regenerates", %{tmp_dir: tmp} do
    target = Path.join(tmp, "Elixir.Jido.Exec.beam")

    File.write!(
      target,
      stub_exec_beam(
        upstream_sha256: "stale-upstream",
        patch_revision: JidoExecPatch.patch_revision()
      )
    )

    refute JidoExecPatch.patched_beam_current?(target)
    assert {:generated, []} = JidoExecPatch.verify_or_regenerate!(fixture_source_path(), target)
    assert JidoExecPatch.patched_beam_current?(target)
  end

  @tag :tmp_dir
  test "a stale PATCH revision regenerates even at the pinned jido_action version", %{
    tmp_dir: tmp
  } do
    # Hunk/helper edits at an unchanged jido_action version must never be
    # served from an old BEAM — the upstream sha alone would pass here.
    target = Path.join(tmp, "Elixir.Jido.Exec.beam")

    File.write!(
      target,
      stub_exec_beam(
        upstream_sha256: JidoExecPatch.pinned_upstream_sha256(),
        patch_revision: "stale-patch-revision"
      )
    )

    refute JidoExecPatch.patched_beam_current?(target)
    assert {:generated, []} = JidoExecPatch.verify_or_regenerate!(fixture_source_path(), target)
    assert JidoExecPatch.patched_beam_current?(target)
  end

  @tag :tmp_dir
  test "a missing target regenerates; generation refuses drifted source", %{tmp_dir: tmp} do
    target = Path.join(tmp, "Elixir.Jido.Exec.beam")
    assert {:generated, []} = JidoExecPatch.verify_or_regenerate!(fixture_source_path(), target)

    drifted = Path.join(tmp, "exec_drifted.ex")
    File.write!(drifted, File.read!(fixture_source_path()) <> "\n# drift\n")

    assert_raise RuntimeError, ~r/refusing to patch drifted source/, fn ->
      JidoExecPatch.generate!(drifted, Path.join(tmp, "other.beam"))
    end
  end

  # Red path for the diagnostics plumbing: an implementation that DISCARDS
  # the captured list (returning [] regardless) would pass every row above,
  # because the pinned fork compiles warning-free — this synthetic warning
  # proves capture through the same seam the real fork compile uses.
  test "compile_with_diagnostics captures the compiled module's own warnings" do
    # Static fixture name — no runtime atom creation; the seam sets
    # ignore_module_conflict and this VM compiles it exactly once.
    mod = __MODULE__.SyntheticWarningFixture

    source = """
    defmodule #{inspect(mod)} do
      @moduledoc false
      def f do
        unused = 1
        :ok
      end
    end
    """

    {compiled, diagnostics} =
      JidoExecPatch.compile_with_diagnostics(source, "jido_exec_patch_synthetic_warning.exs")

    assert [{^mod, binary}] = compiled
    assert is_binary(binary)
    assert [%{severity: :warning, message: message}] = diagnostics
    assert message =~ ~s(variable "unused" is unused)
  end

  # ── Repo POOL_SIZE seam ───────────────────────────────────────────────────

  test "Repo.init/2 parses a raw POOL_SIZE string and keeps the super-injected fields" do
    for context <- [:runtime, :supervisor] do
      assert {:ok, config} = JidoClaw.Repo.init(context, pool_size: "7", url: "ecto://unused")

      assert config[:pool_size] == 7, "#{context}: the raw string must parse"

      # The super-injected AshPostgres configuration must SURVIVE — an
      # outright override (not chaining super/2) would silently discard it.
      assert config[:installed_extensions] == JidoClaw.Repo.installed_extensions()
      assert Keyword.has_key?(config, :migrations_path)
      assert Keyword.has_key?(config, :default_prefix)
    end
  end

  test "Repo.init/2 leaves integer/absent pool_size alone and raises clearly on junk" do
    assert {:ok, config} = JidoClaw.Repo.init(:runtime, pool_size: 12)
    assert config[:pool_size] == 12

    assert {:ok, config} = JidoClaw.Repo.init(:runtime, [])
    refute Keyword.has_key?(config, :pool_size)

    for junk <- ["abc", "0", "-3", "7.5"] do
      assert_raise ArgumentError, ~r/POOL_SIZE must be a positive integer/, fn ->
        JidoClaw.Repo.init(:runtime, pool_size: junk)
      end
    end
  end

  # ── License artifacts (Apache-2.0 §4(a)/(b)) ─────────────────────────────

  defp priv_path(relative), do: Path.join(to_string(:code.priv_dir(:jido_claw)), relative)

  test "the committed license file is byte-equal to the dep's LICENSE (upstream is the truth)" do
    assert File.read!(priv_path("licenses/jido_action-APACHE-2.0.txt")) ==
             File.read!(Path.join(@project_root, "deps/jido_action/LICENSE"))
  end

  test "the NOTICE file names the modified Jido.Exec behavior and points at the license" do
    notice = File.read!(priv_path("licenses/jido_action-NOTICE.txt"))

    assert notice =~ "jido_action 2.3.1"
    assert notice =~ "Jido.Exec"
    assert notice =~ "maybe_mark_wrap/3"
    assert notice =~ "canonical_envelope?/1"
    assert notice =~ "jido_action-APACHE-2.0.txt"
  end

  test "the embedded escript copies are byte-equal to the priv files (chain to upstream bytes)" do
    assert ThirdPartyLicenses.jido_action_license() ==
             File.read!(priv_path("licenses/jido_action-APACHE-2.0.txt"))

    assert ThirdPartyLicenses.jido_action_notice() ==
             File.read!(priv_path("licenses/jido_action-NOTICE.txt"))
  end

  # ── CLI: pre-boot license route + checked startup ────────────────────────

  @cli_env_keys [
    :cli_app_starter,
    :cli_halter,
    :project_dir,
    :serve_mode,
    :mode,
    :skip_discord,
    :first_run_setup_pending,
    :force_setup
  ]

  defp snapshot_cli_env do
    Map.new(@cli_env_keys, fn key -> {key, Application.fetch_env(:jido_claw, key)} end)
  end

  defp restore_cli_env(snapshot) do
    Enum.each(snapshot, fn
      {key, {:ok, value}} -> Application.put_env(:jido_claw, key, value)
      {key, :error} -> Application.delete_env(:jido_claw, key)
    end)
  end

  test "--third-party-licenses prints the NOTICE then the byte-identical license, without booting" do
    snapshot = snapshot_cli_env()

    Application.put_env(:jido_claw, :cli_app_starter, fn ->
      raise "the license flag must never boot the application"
    end)

    try do
      output =
        capture_io(fn ->
          assert :ok = Main.main(["--third-party-licenses"])
        end)

      assert output ==
               ThirdPartyLicenses.jido_action_notice() <>
                 "\n" <> ThirdPartyLicenses.jido_action_license()
    after
      restore_cli_env(snapshot)
    end
  end

  test "each booting branch terminates on start failure with exit 2 + stderr — never falls through" do
    # A fall-through would start the REPL, run setup, or park the MCP branch
    # on a dead server; the throwing halter proves halt!/1 fired FIRST.
    for {label, argv} <- [{"setup", ["--setup"]}, {"repl", []}, {"mcp", ["--mcp"]}] do
      snapshot = snapshot_cli_env()
      {:ok, saved_handler} = :logger.get_handler_config(:default)

      Application.put_env(:jido_claw, :cli_app_starter, fn -> {:error, {:boom, label}} end)
      Application.put_env(:jido_claw, :cli_halter, fn code -> throw({:halted, code}) end)

      try do
        stderr =
          capture_io(:stderr, fn ->
            assert catch_throw(Main.main(argv)) == {:halted, 2},
                   "#{label}: must halt with the documented config-error code"
          end)

        assert stderr =~ "JidoClaw failed to start", label
        assert stderr =~ "boom", label
      after
        restore_cli_env(snapshot)
        # The mcp branch redirects the default logger handler to stderr
        # before starting — restore the saved handler for the rest of the
        # suite (harmless no-op for the other branches).
        _ = :logger.remove_handler(:default)
        :ok = :logger.add_handler(:default, saved_handler.module, Map.drop(saved_handler, [:id]))
      end
    end
  end

  test "a RETURNING halter still cannot fall through (the unconditional raise fires)" do
    snapshot = snapshot_cli_env()
    Application.put_env(:jido_claw, :cli_app_starter, fn -> {:error, :nope} end)
    Application.put_env(:jido_claw, :cli_halter, fn _code -> :returned_instead_of_halting end)

    try do
      stderr =
        capture_io(:stderr, fn ->
          assert_raise RuntimeError, ~r/halt seam returned/, fn ->
            Main.start_app_or_halt!()
          end
        end)

      assert stderr =~ "JidoClaw failed to start"
    after
      restore_cli_env(snapshot)
    end
  end

  # ── Escript config pin (permanent — the artifact probe can't guard later) ─

  test "the escript stays app: nil with the CLI main module (bare-binary license guarantee)" do
    escript = JidoClaw.MixProject.project()[:escript]

    assert escript[:main_module] == JidoClaw.CLI.Main
    # Keyword.fetch! distinguishes an explicit nil from a REMOVED key —
    # removing app: nil silently restores pre-main/1 application boot.
    assert Keyword.fetch!(escript, :app) == nil
  end

  test "compilers/0 keeps the release-patches compiler immediately before :app" do
    compilers = JidoClaw.MixProject.project()[:compilers]
    index = Enum.find_index(compilers, &(&1 == :jidoclaw_release_patches))

    # Removing or reordering the fork's only writer must fail a TEST, not
    # just the gate: before-:app is what lets compile.app's ebin scan pick
    # the generated BEAM into the :modules list.
    assert is_integer(index),
           ":jidoclaw_release_patches missing from compilers/0 — the generated " <>
             "Jido.Exec fork would never regenerate (mix.exs)"

    assert Enum.at(compilers, index + 1) == :app
  end
end
