#!/usr/bin/env bats
# NOTE: the kustomize-build cases DEPEND ON M2 seeds (r2-creds.enc.yaml,
# app-credentials.enc.yaml) existing — they pass only after M2's seed-secrets.sh runs.
# The last case (data app wiring) is always offline-checkable.

@test "kustomize build with ksops renders Cluster + ObjectStore + Pooler + backups" {
  run bash -c 'kustomize build --enable-alpha-plugins --enable-exec platform/cnpg/prod'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'kind: Cluster'
  echo "$output" | grep -q 'kind: ObjectStore'
  echo "$output" | grep -q 'kind: Pooler'
  echo "$output" | grep -q 'kind: ScheduledBackup'
  echo "$output" | grep -q 'name: cnpg-local-basebackup'
  echo "$output" | grep -q 'name: pg-dump-hedge-r2'
}
@test "all THREE database-ns seeds render as Secrets via KSOPS (none silently missing)" {
  run bash -c 'kustomize build --enable-alpha-plugins --enable-exec platform/cnpg/prod'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'name: cnpg-r2-creds'
  echo "$output" | grep -q 'name: pg-app-credentials'
  echo "$output" | grep -q 'name: restore-drill-alerting'
  echo "$output" | grep -q 'AWS_ACCESS_KEY_ID' # canonical R2 schema (matches object-store.yaml)
  echo "$output" | grep -q 'TELEGRAM_BOT_TOKEN'
}
@test "restore-drill ConfigMap is GENERATED from the script (real recovery logic, not an empty placeholder)" {
  drill="$(kustomize build --enable-alpha-plugins --enable-exec platform/cnpg/prod \
    | yq 'select(.kind=="ConfigMap" and .metadata.name=="restore-drill-script") | .data."drill.sh"')"
  echo "$drill" | grep -q 'bootstrap:' # recovery-cluster logic present...
  echo "$drill" | grep -q 'recovery:'
  echo "$drill" | grep -q 'EXPECTED_ROWS'
  echo "$drill" | grep -q 'ACTUAL_ROWS'
  [ "$(printf '%s' "$drill" | wc -l)" -gt 30 ] # ...and it is the full script, not a one-line stub
}
@test "data app is sync-wave -1, project default, ns database" {
  f=platform/argocd/root/apps/cnpg-data.yaml
  grep -qE 'argocd.argoproj.io/sync-wave:\s*"-1"' "$f"
  grep -qE 'project:\s+default' "$f"
  grep -qE 'namespace:\s+database' "$f"
}
