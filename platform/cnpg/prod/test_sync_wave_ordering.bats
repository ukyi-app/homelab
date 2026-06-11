#!/usr/bin/env bats
@test "operator wave -2 < data wave -1 (operator first)" {
  grep -qE 'sync-wave:\s*"-2"' platform/argocd/root/apps/cnpg-operator.yaml
  grep -qE 'sync-wave:\s*"-1"' platform/argocd/root/apps/cnpg-data.yaml
}
@test "Cluster CR carries wave -1 so it is Ready before app migrations (wave 1)" {
  grep -qE 'sync-wave:\s*"-1"' platform/cnpg/prod/cluster.yaml
}
@test "waves match the M3-owned SYNC-WAVES.md (cnpg-operator -2, Cluster -1)" {
  # SYNC-WAVES.md는 wave가 먼저 오는 표(| wave | component |)이므로 wave→컴포넌트 순으로 매칭.
  grep -qE '\-2.*cnpg-operator' platform/argocd/root/SYNC-WAVES.md
  grep -qE '\-1.*Cluster' platform/argocd/root/SYNC-WAVES.md
}
@test "shared app chart runs migrate as a wave-1 ArgoCD Sync hook" {
  # Milestone 6 소유 차트를 상대로 검증; 마일스톤 간 계약이다.
  # migrate는 Helm pre-install/pre-upgrade hook(ArgoCD PreSync 단계, wave-0 설정 이전 실행)이
  # 아니라 ArgoCD Sync hook으로 둔다 — wave-0 설정이 끝난 뒤 마이그레이션이 돌아야 하기 때문.
  test -f platform/charts/app/templates/migrate-job.yaml || skip "chart from M6 not present yet"
  grep -qE 'argocd.argoproj.io/hook:\s*Sync' platform/charts/app/templates/migrate-job.yaml
  grep -qE 'sync-wave:\s*"1"' platform/charts/app/templates/migrate-job.yaml
  ! grep -qE 'helm\.sh/hook' platform/charts/app/templates/migrate-job.yaml
}
