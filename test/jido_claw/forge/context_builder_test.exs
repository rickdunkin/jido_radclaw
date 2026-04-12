defmodule JidoClaw.Forge.ContextBuilderTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Forge.{ContextBuilder, Persistence}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  # ── summarize_events/2 (pure, no DB) ──────────────────────────────

  describe "summarize_events/2" do
    test "returns placeholder for empty list" do
      assert ContextBuilder.summarize_events([]) == "No events recorded."
    end

    test "formats events with timestamps and types" do
      events = [
        %{event_type: "sandbox.provisioned", timestamp: ~U[2026-04-10 10:00:01Z], data: %{}},
        %{event_type: "bootstrap.completed", timestamp: ~U[2026-04-10 10:00:02Z], data: %{}}
      ]

      result = ContextBuilder.summarize_events(events)
      assert result =~ "sandbox.provisioned"
      assert result =~ "bootstrap.completed"
      assert result =~ "10:00:01"
    end

    test "collapses consecutive same-type events" do
      events =
        for i <- 1..5 do
          %{
            event_type: "iteration.completed",
            timestamp: ~U[2026-04-10 10:00:00Z] |> DateTime.add(i),
            data: %{}
          }
        end

      result = ContextBuilder.summarize_events(events)
      assert result =~ "(x5)"
      # Should be a single line, not 5
      refute result =~ "10:00:05"
    end

    test "includes data when include_data: true" do
      events = [
        %{
          event_type: "sandbox.provisioned",
          timestamp: ~U[2026-04-10 10:00:01Z],
          data: %{sandbox_id: "sbx-123"}
        }
      ]

      without_data = ContextBuilder.summarize_events(events, include_data: false)
      with_data = ContextBuilder.summarize_events(events, include_data: true)

      refute without_data =~ "sbx-123"
      assert with_data =~ "sbx-123"
    end

    test "truncates to max_tokens budget" do
      events =
        for i <- 1..200 do
          %{
            event_type: "event.type.#{i}",
            timestamp: ~U[2026-04-10 10:00:00Z] |> DateTime.add(i),
            data: %{}
          }
        end

      result = ContextBuilder.summarize_events(events, max_tokens: 100)
      assert result =~ "more events"
    end
  end

  # ── context_for_resume/1 (DB-backed) ─────────────────────────────

  describe "context_for_resume/1" do
    test "returns nil for nonexistent session" do
      assert Persistence.context_for_resume("nonexistent-session") == nil
    end

    test "returns structured context for a session with events" do
      sid = "ctx-test-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :shell})
      Persistence.log_event(sid, "sandbox.provisioned", %{sandbox_id: "sbx-1"})

      Persistence.log_event(sid, "iteration.completed", %{
        iteration: 1,
        status: :done,
        output_sequence: 1
      })

      Persistence.record_execution_complete(sid, "hello world", 0, 1, :done)

      ctx = Persistence.context_for_resume(sid)

      assert ctx.session.name == sid
      assert ctx.iteration_count == 1
      assert ctx.last_checkpoint == nil
      assert length(ctx.events_since_checkpoint) >= 2
      assert ctx.last_output.output == "hello world"
      assert ctx.last_output.status == :completed
      assert ctx.error_history == []
    end

    test "scopes events_since_checkpoint to after checkpoint timestamp" do
      sid = "ctx-cp-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :shell})

      Persistence.log_event(sid, "iteration.completed", %{
        iteration: 1,
        status: :done,
        output_sequence: 1
      })

      # Save checkpoint — events after this should be in events_since_checkpoint
      Persistence.save_checkpoint(sid, 1, %{step: 1}, %{})

      # Small delay so timestamp is strictly after checkpoint
      Process.sleep(10)

      Persistence.log_event(sid, "iteration.completed", %{
        iteration: 2,
        status: :done,
        output_sequence: 2
      })

      ctx = Persistence.context_for_resume(sid)

      assert ctx.last_checkpoint != nil
      # Only the post-checkpoint event should be in events_since_checkpoint
      since_types = Enum.map(ctx.events_since_checkpoint, & &1.event_type)
      assert "iteration.completed" in since_types
      assert ctx.iteration_count == 2
    end

    test "captures runner errors in error_history" do
      sid = "ctx-err-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :shell})
      Persistence.log_event(sid, "iteration.completed", %{iteration: 1, status: :error})
      Persistence.log_event(sid, "bootstrap.failed", %{reason: "timeout"})

      ctx = Persistence.context_for_resume(sid)

      assert length(ctx.error_history) == 2
      types = Enum.map(ctx.error_history, & &1.event_type)
      assert "iteration.completed" in types
      assert "bootstrap.failed" in types
    end

    test "last_output reflects runner error status via runner_status param" do
      sid = "ctx-status-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :shell})
      # Runner.error() produces status: :error, no exit_code
      Persistence.record_execution_complete(sid, "error output", 0, 1, :error)

      ctx = Persistence.context_for_resume(sid)

      assert ctx.last_output.status == :failed
      assert ctx.last_output.output == "error output"
    end
  end

  # ── build_resume_prompt/1 (DB-backed) ────────────────────────────

  describe "build_resume_prompt/1" do
    test "returns error for nonexistent session" do
      assert {:error, :no_session} = ContextBuilder.build_resume_prompt("no-such-session")
    end

    test "builds prompt with session header and progress" do
      sid = "prompt-test-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :shell})

      Persistence.log_event(sid, "iteration.completed", %{
        iteration: 1,
        status: :done,
        output_sequence: 1
      })

      Persistence.record_execution_complete(sid, "iteration output here", 0, 1, :done)

      assert {:ok, prompt} = ContextBuilder.build_resume_prompt(sid)

      assert prompt =~ "Session Context"
      assert prompt =~ sid
      assert prompt =~ "shell"
      assert prompt =~ "1 iteration(s) completed"
      assert prompt =~ "iteration output here"
    end

    test "includes checkpoint section when checkpoint exists" do
      sid = "prompt-cp-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :workflow})

      Persistence.log_event(sid, "iteration.completed", %{
        iteration: 1,
        status: :done,
        output_sequence: 1
      })

      Persistence.save_checkpoint(sid, 1, %{current_step: 1}, %{})

      assert {:ok, prompt} = ContextBuilder.build_resume_prompt(sid)
      assert prompt =~ "Last Checkpoint"
      assert prompt =~ "iteration 1"
    end

    test "includes error section for runner errors" do
      sid = "prompt-err-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :shell})
      Persistence.log_event(sid, "iteration.completed", %{iteration: 1, status: :error})
      Persistence.log_event(sid, "sandbox.provision_failed", %{reason: "docker timeout"})

      assert {:ok, prompt} = ContextBuilder.build_resume_prompt(sid)
      assert prompt =~ "Errors"
      assert prompt =~ "iteration 1"
      assert prompt =~ "docker timeout"
    end

    test "reports failed status for runner error iterations" do
      sid = "prompt-fail-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :shell})
      # Log the iteration event so iteration_count > 0 and progress_section renders
      Persistence.log_event(sid, "iteration.completed", %{iteration: 1, status: :error})
      # Simulates Runner.error/2 path: exit_code defaults to 0, runner_status is :error
      Persistence.record_execution_complete(sid, "crash trace", 0, 1, :error)

      assert {:ok, prompt} = ContextBuilder.build_resume_prompt(sid)
      assert prompt =~ "failed"
    end

    test "respects max_tokens option" do
      sid = "prompt-tok-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :shell})

      # Create a checkpoint early so events after it populate "Activity Since Checkpoint"
      Persistence.save_checkpoint(sid, 0, %{}, %{})
      Process.sleep(10)

      for i <- 1..20 do
        # Use distinct event types to prevent collapse into a single line
        Persistence.log_event(sid, "step.#{i}.completed", %{iteration: i, status: :done})
      end

      {:ok, short} = ContextBuilder.build_resume_prompt(sid, max_tokens: 50)
      {:ok, long} = ContextBuilder.build_resume_prompt(sid, max_tokens: 8_000)

      assert byte_size(short) < byte_size(long)
    end

    test "bounds output excerpt size via max_tokens" do
      sid = "prompt-big-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :shell})

      Persistence.log_event(sid, "iteration.completed", %{
        iteration: 1,
        status: :done,
        output_sequence: 1
      })

      big_output = String.duplicate("x", 10_000)
      Persistence.record_execution_complete(sid, big_output, 0, 1, :done)

      {:ok, small_prompt} = ContextBuilder.build_resume_prompt(sid, max_tokens: 200)
      {:ok, large_prompt} = ContextBuilder.build_resume_prompt(sid, max_tokens: 8_000)

      # Small budget should produce a much shorter prompt than large budget
      assert byte_size(small_prompt) < byte_size(large_prompt)
      # Small budget should not contain the full 10k output
      refute small_prompt =~ big_output
    end

    test "enforces hard bound on total prompt size" do
      sid = "prompt-bound-#{System.unique_integer([:positive])}"
      max_tokens = 200

      Persistence.record_session_started(sid, %{runner: :shell})

      Persistence.log_event(sid, "iteration.completed", %{
        iteration: 1,
        status: :done,
        output_sequence: 1
      })

      # Large output that would blow the budget on its own
      Persistence.record_execution_complete(sid, String.duplicate("o", 10_000), 0, 1, :done)

      # Large error reasons (inspect of big terms)
      for i <- 1..5 do
        big_reason = String.duplicate("e", 2_000)
        Persistence.log_event(sid, "step.#{i}.failed", %{reason: big_reason})
      end

      # Many events for the activity section
      Persistence.save_checkpoint(sid, 1, %{}, %{})
      Process.sleep(10)

      for i <- 1..30 do
        Persistence.log_event(sid, "post.#{i}.event", %{})
      end

      {:ok, prompt} = ContextBuilder.build_resume_prompt(sid, max_tokens: max_tokens)

      # Prompt must not exceed the token budget (max_tokens * 4 chars + truncation suffix)
      max_chars = max_tokens * 4 + byte_size("\n... (truncated to fit token budget)")
      assert byte_size(prompt) <= max_chars
    end

    test "truncates large error reasons within budget" do
      sid = "prompt-bigerr-#{System.unique_integer([:positive])}"

      Persistence.record_session_started(sid, %{runner: :shell})

      big_reason = String.duplicate("R", 5_000)
      Persistence.log_event(sid, "bootstrap.failed", %{reason: big_reason})

      {:ok, prompt} = ContextBuilder.build_resume_prompt(sid, max_tokens: 300)

      assert prompt =~ "Errors"
      # The full 5k reason should not appear
      refute prompt =~ big_reason
    end
  end
end
