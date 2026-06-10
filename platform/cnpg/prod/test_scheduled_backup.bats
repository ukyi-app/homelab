#!/usr/bin/env bats
f=platform/cnpg/prod/scheduled-backup.yaml
@test "daily cron and immediate first run" {
  grep -qE 'schedule:\s*"0 0 3 \* \* \*"' "$f" # 6-field CNPG cron, 03:00
  grep -q 'immediate: true' "$f"
}
@test "plugin-based backup against cluster pg" {
  grep -q 'method: plugin' "$f"
  grep -qE 'name:\s+pg$' "$f"
}
