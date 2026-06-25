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
# (migrate Job wave-1 Sync hook 테스트 제거 — migrate Job 폐기, 앱이 부팅 시 self-migrate)
