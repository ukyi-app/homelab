#!/usr/bin/env bats
@test "operator wave -2 < data wave -1 (operator first)" {
  grep -qE 'sync-wave:\s*"-2"' platform/argocd/root/apps/cnpg-operator.yaml
  grep -qE 'sync-wave:\s*"-1"' platform/argocd/root/apps/cnpg-data.yaml
}
@test "Cluster CR carries wave -1 so it is Ready before app migrations (wave 1)" {
  grep -qE 'sync-wave:\s*"-1"' platform/cnpg/prod/cluster.yaml
}
@test "waves match the M3-owned SYNC-WAVES.md (cnpg-operator -2, Cluster -1)" {
  # SYNC-WAVES.md is a wave-first table (| wave | component |), so match wave→component.
  grep -qE '\-2.*cnpg-operator' platform/argocd/root/SYNC-WAVES.md
  grep -qE '\-1.*Cluster' platform/argocd/root/SYNC-WAVES.md
}
@test "shared app chart runs migrate as a wave-1 ArgoCD Sync hook" {
  # asserted against the chart owned by Milestone 6; this is the cross-milestone contract.
  # Pass-5 Open Item #2 moved this off the Helm pre-install/pre-upgrade hook (which runs in ArgoCD's
  # PreSync phase, before wave-0 config) onto an ArgoCD Sync hook that runs AFTER wave-0 config.
  test -f platform/charts/app/templates/migrate-job.yaml || skip "chart from M6 not present yet"
  grep -qE 'argocd.argoproj.io/hook:\s*Sync' platform/charts/app/templates/migrate-job.yaml
  grep -qE 'sync-wave:\s*"1"' platform/charts/app/templates/migrate-job.yaml
  ! grep -qE 'helm\.sh/hook' platform/charts/app/templates/migrate-job.yaml
}
