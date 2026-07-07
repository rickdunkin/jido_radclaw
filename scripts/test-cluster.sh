#!/usr/bin/env bash
# WS6 cluster suite entry point. Runs the :peer multi-node tests
# (@moduletag :cluster) against the shared jido_claw_cluster_test DB.
#
# Invoke via a shell where `mix` resolves to the project toolchain:
#   mise exec -- scripts/test-cluster.sh      # explicit (canonical)
#   scripts/test-cluster.sh                   # fine in an activated shell
#
# JIDOCLAW_CLUSTER_TEST=1 and --only cluster MUST travel together:
# the flag swaps the Repo pool (sandbox -> regular), which breaks every
# non-cluster test; the tag keeps peer tests out of sandbox runs.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
export JIDOCLAW_CLUSTER_TEST=1
exec mix test --only cluster "$@"
