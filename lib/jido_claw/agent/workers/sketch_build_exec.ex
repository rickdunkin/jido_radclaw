defmodule JidoClaw.Agent.Workers.SketchBuildExec do
  @moduledoc false

  # AR-8b-2 F2 sketch worker. Like `SketchBuild` but ALSO runs its tracer-bullet:
  # `exec?: true` adds `RunCommand` (+ its mandatory `FetchOutput` pair), which —
  # under the `sandbox: :docker` template policy (registered in
  # `JidoClaw.Agent.Templates`) — routes into a no-egress, globally-unmounted
  # Forge Docker microVM session instead of the host shell, so the spawned shell
  # can't escape the `.prototypes/<id>/` jail.
  #
  # The larger `tool_timeout_ms` gives a tracer-bullet room to build AND run: the
  # bridge reserves a ~5.5s cushion off the outer deadline before launching the
  # in-container command, so the effective in-container budget ≈ 84.5s. `90_000`
  # is a starting value — tune against real microVM exec latencies (the cushion
  # constants are Phase-1 estimates too). `sandbox`/`forward_context` are TEMPLATE
  # properties (Part 2.3), not set here.
  use JidoClaw.Agent.Workers.SketchWorker,
    exec?: true,
    name: "jido_claw_sketch_build_exec",
    description: "Builds AND runs a throwaway prototype in a Docker-isolated sandbox",
    tool_timeout_ms: 90_000
end
