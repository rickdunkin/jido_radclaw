defmodule JidoClaw.V064FileStoreSweepTest do
  @moduledoc """
  Phase 4 / Step 4 residual file-store sweep — bans new writers to the
  legacy `.jido/` JSON/JSONL stores that v0.6 has migrated to Postgres.

  Distinguishes live writers (banned) from export writers (allowed):
  exports always write to `*.exported` paths so a v0.5-style consumer
  can roundtrip without colliding with a still-running legacy store.

  This test is a sweep guard — it does NOT delete the on-disk files.
  Step 4 leaves cron.yaml in place as a backup; the migrator
  `mix jidoclaw.migrate.cron` is the right tool for one-shot conversion.
  """

  use ExUnit.Case, async: true

  # Live (non-export) writes only — `.exported`, `.export-manifest`,
  # and `.redaction-manifest` paths are allowed since they're roundtrip
  # backups, not active stores.
  @banned_patterns [
    ~r"\.jido/memory\.json[\"']",
    ~r"\.jido/solutions\.json[\"']",
    ~r"\.jido/reputation\.json[\"']",
    ~r"\.jido/cron\.yaml[\"']",
    ~r"\.jido/sessions/[^\"']*\.jsonl[\"']"
  ]

  @write_pattern ~r/File\.write!?\b/

  test "no live writers to deprecated .jido/ stores under lib/" do
    paths = Path.wildcard("lib/**/*.ex")

    offenders =
      for path <- paths,
          content = File.read!(path),
          Regex.match?(@write_pattern, content),
          Enum.any?(@banned_patterns, &Regex.match?(&1, content)) do
        path
      end

    assert offenders == [],
           "Files containing banned writers to deprecated .jido paths:\n" <>
             Enum.join(offenders, "\n")
  end
end
