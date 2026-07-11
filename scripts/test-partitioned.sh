#!/usr/bin/env bash
# Run the test suite split across N OS-level partitions (default 4), each in
# its own BEAM against its own database. config/test.exs keys the database
# name (and forge_home) off MIX_TEST_PARTITION, and the `mix test` alias runs
# `ash.setup --quiet`, so each partition creates/migrates its own DB on first
# use. Measured on a 12-core M-series: ~159s serial -> ~71s at N=4.
#
# Usage:
#   scripts/test-partitioned.sh              # 4 partitions
#   scripts/test-partitioned.sh 3            # 3 partitions
#   scripts/test-partitioned.sh 4 --seed 0   # extra args pass through to mix test
#
# Caveat: all partitions share _build/test, so the `mix test --failed`
# manifest holds only the last-finished partition's failures. To rerun a
# failure, use the per-partition rerun command printed on failure, or run
# the failing file directly.

set -u

N=4
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  N=$1
  shift
fi

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
logdir=tmp/test-partitions
mkdir -p "$logdir"

# One up-front compile so the partitions start hot instead of serializing
# on the build lock.
MIX_ENV=test mix compile || exit 1

# Lets config/test.exs + test_helper.exs divide the async concurrency and
# DB-pool budget across the N BEAMs (Postgres max_connections is the shared
# ceiling; see the Repo block in config/test.exs).
export JIDOCLAW_TEST_PARTITIONS=$N

start=$SECONDS
pids=()
for i in $(seq 1 "$N"); do
  MIX_TEST_PARTITION=$i mix test --partitions "$N" "$@" \
    >"$logdir/partition-$i.log" 2>&1 &
  pids+=("$!")
done

rc=0
failed=()
for idx in "${!pids[@]}"; do
  wait "${pids[$idx]}" || {
    rc=1
    failed+=("$((idx + 1))")
  }
done

echo
for i in $(seq 1 "$N"); do
  summary=$(grep -E '^(Finished in|Result:)' "$logdir/partition-$i.log" | tr '\n' ' ')
  echo "partition $i: ${summary:-no summary — see $logdir/partition-$i.log}"
done
echo "total wall: $((SECONDS - start))s (logs: $logdir/)"

for i in "${failed[@]:-}"; do
  [[ -n "$i" ]] || continue
  echo
  echo "== partition $i FAILED — last 40 lines of $logdir/partition-$i.log =="
  tail -n 40 "$logdir/partition-$i.log"
  echo
  echo "rerun: MIX_TEST_PARTITION=$i mix test --partitions $N"
done

exit "$rc"
