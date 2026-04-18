---
expected_task_type: verification
expected_strategy: aot
---

Verify the migration is safe under concurrent writes. Must preserve data.
Must not block reads. Cannot lose pending transactions. Do not cause
cascading retries. Include correctness invariants across all tables.
