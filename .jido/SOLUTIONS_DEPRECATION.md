# `.jido/solutions.json` and `.jido/reputation.json` are deprecated

As of v0.6.1, the Solutions corpus and per-agent Reputation
counters live in Postgres rather than JSON files in this
directory.

These files remain on disk so users can:

  1. Run `mix jidoclaw.migrate.solutions` to pull their content
     into the new Postgres-backed corpus.
  2. Roll back to v0.5.x without losing data.

After a successful migration, the JSON files are no longer read or
written by the running app. You can keep them as a backup or move
them out of the directory once you've verified the Postgres copy
works.

To export a Postgres-backed corpus back to the legacy shape, run:

    mix jidoclaw.export.solutions --out .jido/solutions.json.exported
