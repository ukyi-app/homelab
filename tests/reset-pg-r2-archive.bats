#!/usr/bin/env bats
# R2 아카이브 리셋 도구(④)의 안전 불변식을 오프라인에서 강제한다 — 실제 R2 삭제 없이.
sh=scripts/reset-pg-r2-archive.sh

@test "reset-pg-r2-archive exists, is executable, and passes shellcheck" {
  [ -x "$sh" ]
  run shellcheck "$sh"
  [ "$status" -eq 0 ]
}

@test "reset is dry-run by default and requires --purge to actually delete (destructive guard)" {
  grep -q -- '--purge' "$sh"
  grep -qi 'dry-run' "$sh"
  grep -q 'rclone purge' "$sh"
}

@test "reset targets ONLY the serverName pg archive (pgdump hedge and other buckets untouched)" {
  grep -q 'SERVER=pg' "$sh"
  run grep -qE '(purge|delete).*pgdump' "$sh"
  [ "$status" -ne 0 ]
}

@test "reset derives bucket and endpoint from the live ObjectStore (not hardcoded)" {
  grep -q 'get objectstore' "$sh"
  grep -q 'destinationPath' "$sh"
  grep -q 'endpointURL' "$sh"
}

@test "reset reads R2 creds from the cnpg-r2-creds secret and skips the bucket head check" {
  grep -q 'cnpg-r2-creds' "$sh"
  grep -qiE 'no_check_bucket' "$sh"
}
