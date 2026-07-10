defmodule JidoClaw.Skills.Steps.ForgeExecutorTest do
  @moduledoc """
  Item 7 (camus C1-1): the AgentRunner→Forge bridge, driven against REAL
  in-memory Forge sessions (persistence disabled — the `ready_start_test`
  hermetic pattern; `sandbox: :local` → HostShell per-run tmp dirs). Direct
  `ForgeExecutor.run/6` calls, so no correlation/transcript rows — the shared
  AgentRunner envelope is covered in `agent_runner_test.exs`.

  PR-2: the vendor arm runs hermetically against the SCRIPTED deposit runner
  (`JidoClaw.Test.ScriptedDepositRunner`, armed via `:executor_vendor_runners`)
  — a real `Forge.Runner` that drives `LoopbackClient` against the per-step
  scoped endpoint, proving endpoint → plug → anubis → tool → registry → box
  with zero vendor CLIs.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias JidoClaw.Forge
  alias JidoClaw.Skills.Steps.ForgeExecutor
  alias JidoClaw.Workflows.StepResult

  @coder JidoClaw.Agent.Workers.Coder
  @deposit_registry JidoClaw.Skills.Steps.ForgeExecutor.DepositRegistry

  setup do
    prev = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev)
      Application.delete_env(:jido_claw, :executor_fake_outputs)
    end)

    %{pre_sessions: Forge.list_sessions()}
  end

  defp fake_template, do: %{module: @coder, executor: {:forge, :fake}, executor_config: %{}}

  defp shell_template(command),
    do: %{module: @coder, executor: {:forge, :shell}, executor_config: %{command: command}}

  defp coder_fixture(summary) do
    %{
      "summary" => summary,
      "status" => "completed",
      "files_changed" => ["lib/thing.ex"],
      "notes" => "n/a",
      "artifacts" => %{}
    }
  end

  # The session registry deregisters ASYNC after a harness stop (loudest on
  # the session-start-failure path under full-suite load), so drain briefly —
  # the deposit-registry `wait_until` precedent — rather than racing the
  # reaper with a single snapshot. A genuinely leaked session still fails.
  defp assert_no_leaked_sessions(%{pre_sessions: pre}) do
    assert wait_until(fn -> Forge.list_sessions() -- pre == [] end),
           "expected every bridge session torn down, got: #{inspect(Forge.list_sessions() -- pre)}"
  end

  describe "{:forge, :fake} through a real session" do
    test "serves the armed fixture, schema-validated, and tears the session down", ctx do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        "coder" => coder_fixture("Implemented the thing.")
      })

      assert {:ok, %StepResult{} = result} =
               ForgeExecutor.run("coder", fake_template(), "do it", "step-1", %{})

      # Validated against the Coder's real coder_result schema: atom keys,
      # atom status enum — the live worker shape, not the raw fixture.
      assert result.typed_output.summary == "Implemented the thing."
      assert result.typed_output.status == :completed
      assert result.result == "Implemented the thing."
      assert result.name == "step-1"
      assert result.template == "coder"

      assert_no_leaked_sessions(ctx)
    end

    test "an invalid fixture yields typed_output nil (result still built) — never a fabricated shape",
         ctx do
      # Missing the required status/files_changed/notes → Zoi rejects it, and
      # the run still completes with the live-faithful validation-failed shape.
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        "coder" => %{"summary" => "did stuff"}
      })

      assert {:ok, %StepResult{} = result} =
               ForgeExecutor.run("coder", fake_template(), "do it", "step-1", %{})

      assert result.typed_output == nil
      assert result.result == "did stuff"

      assert_no_leaked_sessions(ctx)
    end

    test "a missing fixture fails closed BEFORE any session starts", ctx do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{})

      assert {:error, msg} = ForgeExecutor.run("coder", fake_template(), "do it", "s", %{})
      assert msg =~ "no fake output armed for 'coder'"
      assert msg =~ ":executor_fake_outputs"

      assert_no_leaked_sessions(ctx)
    end
  end

  describe "fixture resolution ({:stage, _, _} > {:fragment, _, _} > plain)" do
    test "an exact stage key beats a matching fragment and the plain key" do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:stage, "coder", "s1"} => coder_fixture("stage fixture"),
        {:fragment, "coder", "frag"} => coder_fixture("fragment fixture"),
        "coder" => coder_fixture("plain fixture")
      })

      assert {:ok, %StepResult{result: "stage fixture"}} =
               ForgeExecutor.run("coder", fake_template(), "task with frag", "s1", %{})
    end

    test "a single matching fragment serves when no stage key matches" do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:stage, "coder", "s1"} => coder_fixture("stage fixture"),
        {:fragment, "coder", "frag"} => coder_fixture("fragment fixture"),
        "coder" => coder_fixture("plain fixture")
      })

      assert {:ok, %StepResult{result: "fragment fixture"}} =
               ForgeExecutor.run("coder", fake_template(), "task with frag", "s2", %{})
    end

    test "zero fragment matches fail closed — no arbitrary pick, no plain fallback, no session",
         ctx do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:fragment, "coder", "frag-a"} => coder_fixture("a"),
        "coder" => coder_fixture("plain fixture")
      })

      assert {:error, msg} =
               ForgeExecutor.run("coder", fake_template(), "task without markers", "s", %{})

      assert msg =~ "exactly one {:fragment"
      assert_no_leaked_sessions(ctx)
    end

    test "several fragment matches fail closed too", ctx do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:fragment, "coder", "frag-a"} => coder_fixture("a"),
        {:fragment, "coder", "frag-b"} => coder_fixture("b")
      })

      assert {:error, msg} =
               ForgeExecutor.run("coder", fake_template(), "task frag-a and frag-b", "s", %{})

      assert msg =~ "exactly one {:fragment"
      assert_no_leaked_sessions(ctx)
    end

    test "tuple keys disable the plain fallback for an unkeyed sibling stage", ctx do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:stage, "coder", "s1"} => coder_fixture("stage fixture"),
        "coder" => coder_fixture("plain fixture")
      })

      assert {:error, msg} =
               ForgeExecutor.run("coder", fake_template(), "no fragments here", "s2", %{})

      assert msg =~ "tuple keys for 'coder' disable the plain"
      assert_no_leaked_sessions(ctx)
    end

    test "a template with no tuple keys uses the plain key; other templates' tuple keys don't interfere" do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:stage, "reviewer", "r1"} => coder_fixture("reviewer stage"),
        "coder" => coder_fixture("plain fixture")
      })

      assert {:ok, %StepResult{result: "plain fixture"}} =
               ForgeExecutor.run("coder", fake_template(), "any task", "s1", %{})
    end
  end

  # ---------------------------------------------------------------------------
  # PR-2 vendor arm — hermetic E2E through the scripted deposit runner.
  # ---------------------------------------------------------------------------

  describe "{:forge, :codex} vendor arm through the scripted deposit runner" do
    setup do
      Application.put_env(:jido_claw, :executor_vendor_runners, %{
        codex: JidoClaw.Test.ScriptedDepositRunner
      })

      on_exit(fn ->
        Application.delete_env(:jido_claw, :executor_vendor_runners)
        Application.delete_env(:jido_claw, :scripted_deposit_runner)
      end)

      project_dir = make_tmpdir!("vendor_repo")
      on_exit(fn -> File.rm_rf(project_dir) end)

      {:links, links} = Process.info(self(), :links)

      %{
        project_dir: project_dir,
        context: %{project_dir: project_dir},
        pre_links: links,
        pre_cfg_count: deposit_cfg_count()
      }
    end

    test "a valid deposit lands typed_output AND the typed result projection (P3a)", ctx do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{
        deposits: [coder_fixture("Vendor implemented the thing.")],
        output: "raw-cli-stream-json",
        notify: self()
      })

      assert {:ok, %StepResult{} = result} =
               ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

      # Single-channel: typed comes from the BOX (schema-validated, atom keys),
      # and the transcript text is the typed projection, never raw stream-json.
      assert result.typed_output.summary == "Vendor implemented the thing."
      assert result.typed_output.status == :completed
      assert result.result == "Vendor implemented the thing."
      refute result.result =~ "raw-cli-stream-json"
      assert result.name == "v-step"

      # Prompt assembly (deposit instruction last, workspace note present).
      assert_receive {:scripted_deposit_runner, :prompt, prompt}
      assert prompt =~ "do it"
      assert prompt =~ "repository at #{ctx.project_dir}"
      assert prompt =~ "submit_structured_output"
      assert prompt =~ ~s("summary")

      # Read-only local vendor posture + repo workspace on the runner config.
      assert_receive {:scripted_deposit_runner, :config, config}
      assert config.access == :read_only
      assert config.config_sync == :auth_only
      assert config.mcp_server_name == "jido_deposit"
      assert config.allowed_mcp_tools == ["mcp__jido_deposit__submit_structured_output"]
      assert config.cwd == ctx.project_dir
      assert config.add_dirs == [ctx.project_dir]
      assert config.max_turns == 40
      assert config.timeout_ms == 240_000

      # Local-plan byte-identical regression (docker write build): the docker
      # keys never ride a local runner config, and the loopback URL is
      # untranslated.
      refute Map.has_key?(config, :mcp_config_json)
      refute Map.has_key?(config, :strict_mcp)
      assert config.mcp_server_url =~ "127.0.0.1"

      assert_vendor_resources_released(ctx)
    end

    test "an invalid-only deposit is rejected by the box — typed nil, raw text fallback", ctx do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{
        deposits: [%{"summary" => "missing required fields"}],
        output: "raw-vendor-stdout"
      })

      assert {:ok, %StepResult{} = result} =
               ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

      assert result.typed_output == nil
      assert result.result == "raw-vendor-stdout"

      assert_vendor_resources_released(ctx)
    end

    test "no deposit at all — typed nil (never a fabricated shape)", ctx do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{deposits: []})

      assert {:ok, %StepResult{typed_output: nil}} =
               ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

      assert_vendor_resources_released(ctx)
    end

    test "the system_prompt opt leads the vendor prompt; deposit instruction stays last", ctx do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{
        deposits: [],
        notify: self()
      })

      assert {:ok, _} =
               ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context,
                 system_prompt: "# Role\nYou are the coder."
               )

      assert_receive {:scripted_deposit_runner, :prompt, prompt}
      assert String.starts_with?(prompt, "# Role\nYou are the coder.")

      [_pre, post] = String.split(prompt, "submit_structured_output", parts: 2)
      refute post =~ "do it"

      assert_vendor_resources_released(ctx)
    end

    test "workspace: :repo without a project_dir fails loudly BEFORE any resource", ctx do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{notify: self()})

      for context <- [%{}, %{project_dir: nil}, %{project_dir: ""}] do
        assert {:error, msg} =
                 ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", context)

        assert msg =~ "workspace: :repo requires a project_dir"
      end

      # Pre-flight refusal: no session, no runner init, no box/endpoint/config.
      refute_received {:scripted_deposit_runner, :config, _}
      assert_vendor_resources_released(ctx)
    end

    test "a session-start failure (no vendor credentials) leaks nothing", ctx do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{
        init_error: :no_credentials,
        notify: self()
      })

      assert {:error, msg} =
               ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

      assert msg =~ "no_credentials"

      refute_received {:scripted_deposit_runner, :prompt, _}
      assert_vendor_resources_released(ctx)
    end

    test "a partial acquisition unwinds — box and endpoint torn down, no session started", ctx do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{notify: self()})

      # Break acquisition step 3 (forge-home mkdir) by pointing the base at a
      # regular FILE: box + endpoint were already acquired and must unwind.
      prev_forge = Application.get_env(:jido_claw, :forge_home)
      not_a_dir = Path.join(System.tmp_dir!(), "not_a_dir_#{:erlang.unique_integer([:positive])}")
      File.write!(not_a_dir, "file, not dir")
      Application.put_env(:jido_claw, :forge_home, not_a_dir)

      on_exit(fn ->
        File.rm_rf(not_a_dir)
        Application.put_env(:jido_claw, :forge_home, prev_forge)
      end)

      assert {:error, msg} =
               ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

      assert msg =~ "forge home mkdir failed"

      refute_received {:scripted_deposit_runner, :config, _}
      assert_vendor_resources_released(ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Docker write build — vendor dispatch through the :executor_docker_backend
  # seam (RecordingDockerBackend → StubSandbox), still hermetic: the scripted
  # runner dials the REAL scoped endpoint host-side, mapping the docker plan's
  # host.docker.internal URL back to loopback.
  # ---------------------------------------------------------------------------

  describe "{:forge, :codex} docker dispatch (the write build)" do
    setup do
      Application.put_env(:jido_claw, :executor_vendor_runners, %{
        codex: JidoClaw.Test.ScriptedDepositRunner
      })

      Application.put_env(
        :jido_claw,
        :executor_docker_backend,
        JidoClaw.Test.RecordingDockerBackend
      )

      Application.put_env(:jido_claw, :recording_docker_backend_notify, self())

      on_exit(fn ->
        Application.delete_env(:jido_claw, :executor_vendor_runners)
        Application.delete_env(:jido_claw, :executor_docker_backend)
        Application.delete_env(:jido_claw, :recording_docker_backend_notify)
        Application.delete_env(:jido_claw, :scripted_deposit_runner)
      end)

      project_dir = make_tmpdir!("docker_vendor_repo")
      on_exit(fn -> File.rm_rf(project_dir) end)

      {:links, links} = Process.info(self(), :links)

      %{
        project_dir: project_dir,
        context: %{project_dir: project_dir},
        pre_links: links,
        pre_cfg_count: deposit_cfg_count()
      }
    end

    defp docker_template(access) do
      %{
        module: @coder,
        executor: {:forge, :codex},
        executor_config: %{workspace: :repo, access: access, session_sandbox: :docker}
      }
    end

    test "write+repo dispatches: rw mount, workdir, allow_network, :full runner, translated URL, deposit lands",
         ctx do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{
        deposits: [coder_fixture("Docker vendor wrote the thing.")],
        output: "raw-cli-stream-json",
        notify: self()
      })

      assert {:ok, %StepResult{} = result} =
               ForgeExecutor.run("coder", docker_template(:write), "do it", "d-step", ctx.context)

      # The deposit landed through the real endpoint → box loop.
      assert result.typed_output.summary == "Docker vendor wrote the thing."
      assert result.typed_output.status == :completed

      # The flattened create spec that reached the backend: same-path rw repo
      # mount, workdir = project_dir, allow_network in BOTH forms with the
      # endpoint's real port.
      assert_receive {:docker_backend_create, spec}
      pd = ctx.project_dir
      assert spec.isolate_global_config == true
      assert spec.extra_mounts == [{pd, pd, "rw"}]
      assert spec.workdir == pd

      assert [<<"host.docker.internal:", port_s::binary>>, <<"localhost:", port_s::binary>>] =
               spec.allow_network

      port = String.to_integer(port_s)
      assert port > 0

      # Runner posture: write ⇒ the runners' :full arms (the microVM + mount
      # mode is the boundary, not the CLI flags), strict_mcp pins claude's MCP
      # surface, and the deposit URL names host.docker.internal on that same
      # endpoint port.
      assert_receive {:scripted_deposit_runner, :config, config}
      assert config.access == :full
      assert config.config_sync == :auth_only
      assert config.strict_mcp == true

      assert String.starts_with?(
               config.mcp_server_url,
               "http://host.docker.internal:#{port}/deposit/"
             )

      # The in-VM client-config body carries the SAME translated URL; the
      # path points into the VM's forge_home (pinned under the in-VM
      # user-writable base — /var/local/forge may not be creatable in-VM).
      assert config.mcp_config_json =~ config.mcp_server_url
      assert config.mcp_config_path == Path.join(config.forge_home, "mcp-config.json")
      assert String.starts_with?(config.forge_home, "/tmp/jidoclaw_forge_exec/")
      assert config.cwd == pd

      # Writable prompt wording (write+docker only).
      assert_receive {:scripted_deposit_runner, :prompt, prompt}
      assert prompt =~ "changes land directly in the working tree"

      # No host-tmp client config was written for a docker plan.
      assert deposit_cfg_count() == ctx.pre_cfg_count

      assert_vendor_resources_released(ctx)
    end

    test "read_only+docker keeps the read floor: :ro mount AND :read_only runner (defense in depth)",
         ctx do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{deposits: [], notify: self()})

      assert {:ok, %StepResult{typed_output: nil}} =
               ForgeExecutor.run(
                 "coder",
                 docker_template(:read_only),
                 "do it",
                 "d-step",
                 ctx.context
               )

      assert_receive {:docker_backend_create, spec}
      pd = ctx.project_dir
      assert spec.isolate_global_config == true
      assert spec.extra_mounts == [{pd, pd, "ro"}]

      assert_receive {:scripted_deposit_runner, :config, config}
      assert config.access == :read_only

      # Read-only prompt wording, never the writable note.
      assert_receive {:scripted_deposit_runner, :prompt, prompt}
      assert prompt =~ "read-only this session"
      refute prompt =~ "land directly"

      assert_vendor_resources_released(ctx)
    end

    test "workspace: :scratch on docker exposes no repo — no mount, no workdir, cwd = forge_home",
         ctx do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{deposits: [], notify: self()})

      template = %{
        module: @coder,
        executor: {:forge, :codex},
        executor_config: %{workspace: :scratch, access: :read_only, session_sandbox: :docker}
      }

      assert {:ok, _} = ForgeExecutor.run("coder", template, "do it", "d-step", ctx.context)

      # Conditionally-put: a workspace-less plan carries NEITHER key (a
      # present-nil would defeat the backend's Map.get defaults).
      assert_receive {:docker_backend_create, spec}
      assert spec.isolate_global_config == true
      refute Map.has_key?(spec, :extra_mounts)
      refute Map.has_key?(spec, :workdir)
      assert [_, _] = spec.allow_network

      assert_receive {:scripted_deposit_runner, :config, config}
      assert config.cwd == config.forge_home

      assert_vendor_resources_released(ctx)
    end

    test "expected_backend maps the :docker_sandbox wire atom to the Docker MODULE (never the raw atom)" do
      # Stub tests alone would pass while prod tears down every session as
      # {:wrong_backend, Docker}: ReadyStart compares harness `sandbox_module`
      # (a MODULE via resolve_client) to `expected_backend`.
      prev = Application.get_env(:jido_claw, :executor_docker_backend)
      Application.put_env(:jido_claw, :executor_docker_backend, :docker_sandbox)
      on_exit(fn -> Application.put_env(:jido_claw, :executor_docker_backend, prev) end)

      assert ForgeExecutor.expected_backend(:docker) == JidoClaw.Forge.Sandbox.Docker

      # An armed stub MODULE passes through as itself.
      Application.put_env(:jido_claw, :executor_docker_backend, JidoClaw.Test.StubSandbox)
      assert ForgeExecutor.expected_backend(:docker) == JidoClaw.Test.StubSandbox

      # Local vendor sessions keep the HostShell assertion.
      assert ForgeExecutor.expected_backend(:local) == JidoClaw.Forge.Runner.HostShell
    end
  end

  defp vendor_template,
    do: %{module: @coder, executor: {:forge, :codex}, executor_config: %{workspace: :repo}}

  # Every per-step vendor resource is gone: no leaked Forge session, the
  # linked box + Bandit endpoint are unlinked from this (caller) process, the
  # deposit registry drains, and the host-side client-config tmp file count
  # is back to the baseline.
  defp assert_vendor_resources_released(ctx) do
    assert_no_leaked_sessions(ctx)

    {:links, links} = Process.info(self(), :links)

    assert links -- ctx.pre_links == [],
           "expected no leaked linked resources, got: #{inspect(links -- ctx.pre_links)}"

    assert wait_until(fn -> Registry.count(@deposit_registry) == 0 end),
           "expected the deposit registry to drain"

    assert deposit_cfg_count() == ctx.pre_cfg_count,
           "expected the executor-deposit client-config tmp file to be removed"
  end

  defp deposit_cfg_count do
    System.tmp_dir!()
    |> Path.join("executor-deposit-*.json")
    |> Path.wildcard()
    |> length()
  end

  defp wait_until(fun, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Enum.reduce_while(Stream.repeatedly(fun), false, fn done?, _acc ->
      cond do
        done? ->
          {:halt, true}

        System.monotonic_time(:millisecond) >= deadline ->
          {:halt, false}

        true ->
          Process.sleep(10)
          {:cont, false}
      end
    end)
  end

  defp make_tmpdir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  describe "{:forge, :shell} through HostShell" do
    test "runs the template-declared command; stdout is the step result", ctx do
      assert {:ok, %StepResult{} = result} =
               ForgeExecutor.run("coder", shell_template("printf step-out"), "task", "s", %{})

      # Non-JSON stdout fails coder-schema validation softly → typed nil,
      # stdout verbatim as the result text.
      assert result.result == "step-out"
      assert result.typed_output == nil

      assert_no_leaked_sessions(ctx)
    end

    test "a nonzero exit maps to a step error (with the session still torn down)", ctx do
      assert {:error, msg} =
               ForgeExecutor.run("coder", shell_template("exit 3"), "task", "s", %{})

      assert msg =~ "exit code 3"
      assert_no_leaked_sessions(ctx)
    end
  end
end
