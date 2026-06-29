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

@test "owner/ro password SealedSecrets carry a sync-wave ahead of the Cluster CR (-1)" {
  # provision-db 산출물(db-<app>-owner/ro)은 SealedSecret '리소스 자체'의 top-level metadata에
  # wave < -1을 가져야 한다 — CNPG가 managed role을 reconcile하기 전에 비번 Secret이 적용되도록
  # (방어 1층; 결정적 보장은 ensure-role-password PostSync Job). 빈 글롭 vacuous-pass를 막기 위해
  # 검사한 파일 수를 세고, bash3.2 중간단언 침묵통과를 피하려 위반 시 즉시 return 1로 하드페일한다.
  local checked=0 w
  for f in platform/cnpg/prod/databases/db-*-owner.sealed.yaml platform/cnpg/prod/databases/db-*-ro.sealed.yaml; do
    [ -e "$f" ] || continue
    checked=$((checked + 1))
    w=$(yq '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$f")
    if [ "$w" = "null" ]; then echo "no sync-wave annotation: $f"; return 1; fi
    if [ "$w" -ge -1 ]; then echo "sync-wave $w not ahead of Cluster (-1): $f"; return 1; fi
  done
  [ "$checked" -gt 0 ]
}
