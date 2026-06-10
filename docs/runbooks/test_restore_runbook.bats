#!/usr/bin/env bats
f=docs/runbooks/restore.md
@test "runbook covers R2 barman recovery, pg_dump hedge, and local basebackup" {
  grep -qi 'bootstrap.recovery' "$f"
  grep -qi 'pg_restore' "$f"
  grep -qi 'pg_basebackup' "$f"
}
@test "runbook gives a PITR (point-in-time) recovery example" {
  grep -qi 'recoveryTarget' "$f"
}
@test "runbook records the drill cadence and the row-count gate" {
  grep -qi 'restore_canary' "$f"
}
