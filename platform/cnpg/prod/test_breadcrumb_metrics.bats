#!/usr/bin/env bats

@test "Cluster enables the barman WAL archiver (feeds cnpg_collector_* backup metrics)" {
  grep -q 'isWALArchiver: true' platform/cnpg/prod/cluster.yaml
}
@test "local basebackup Job is named so kube_job_status_completion_time can match it" {
  grep -q 'name: cnpg-local-basebackup' platform/cnpg/prod/basebackup-cronjob.yaml
}
@test "restore drill pushes restore_drill_last_success_timestamp" {
  grep -q 'restore_drill_last_success_timestamp' platform/cnpg/prod/restore-drill-script.sh
}
@test "M4 authors NO vmalert / PrometheusRule (those are M5-owned)" {
  run bash -c "ls platform/cnpg/prod/alert-rules.yaml 2>/dev/null"
  [ "$status" -ne 0 ]
  # restrict to YAML manifests so this .bats file (which mentions the string) is not a self-match
  run bash -c "grep -rl --include='*.yaml' 'kind: PrometheusRule' platform/cnpg 2>/dev/null"
  [ -z "$output" ]
}
