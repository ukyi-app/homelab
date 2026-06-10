#!/usr/bin/env bats
f=platform/cnpg/prod/pgdump-hedge-cronjob.yaml
@test "hedge uses pg_dump piped to rclone, not barman" {
  grep -q 'pg_dump' "$f"
  grep -q 'rclone rcat' "$f"
  run grep -q 'barman' "$f"
  [ "$status" -ne 0 ]
}
@test "hedge writes a SEPARATE R2 prefix and prunes to 14 days" {
  grep -q 'r2:homelab-pg-backups-prod/pgdump/' "$f"
  grep -qE 'rclone delete .*--min-age 14d' "$f"
}
@test "hedge pulls rclone+aws creds from cnpg-r2-creds secret" {
  grep -q 'name: cnpg-r2-creds' "$f"
}
@test "hedge uses the M6-built pg-tools image" {
  grep -q 'ghcr.io/<GH_USER>/pg-tools:16-rclone' "$f"
}
