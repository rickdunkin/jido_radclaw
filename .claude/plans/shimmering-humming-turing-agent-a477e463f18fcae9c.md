# Adversarial critique: MCP-result shaping in OutputShaper

(Working notes — full critique returned to caller in chat.)

## Decisive downstream fact
- jido_ai `Turn.format_tool_result_content/1` JSON-encodes the result map
  (deps/jido_ai/lib/jido_ai/turn.ex:381-395, encode at :818 `Jason.encode!`),
  it does NOT `inspect`. So structure IS preserved to the model on passthrough,
  and collapse genuinely discards `isError` + keys.
- `Error.normalize_result` (lib/jido_claw/tools/error.ex) only promotes
  `{:ok, %{status: ...}}`; it ignores MCP `"isError" => true`. So an MCP error
  stays `{:ok, %{"content"=>..., "isError"=>true}}` and `isError` is the model's
  ONLY failure signal. Collapse to `%{output: text}` drops it.
- `Jason.encode!` at :818 is NOT rescued in the formatting path
  (execute_internal rescue at :563 covers only Jido.Exec.run).

## Verdict
Design is mostly sound. Biggest issue: collapse (decision A) drops isError.
Recommend preserve-map variant. Trigger (C) at cap is fine but has gaps.
