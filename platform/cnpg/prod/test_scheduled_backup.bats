#!/usr/bin/env bats
f=platform/cnpg/prod/scheduled-backup.yaml
@test "daily cron and immediate first run" {
  grep -qE 'schedule:\s*"0 0 3 \* \* \*"' "$f" # CNPG 6-field cron, 03:00**Z**(operator TZ=UTC) = 12:00 KST
  grep -q 'immediate: true' "$f"
}
@test "plugin-based backup against cluster pg" {
  grep -q 'method: plugin' "$f"
  grep -qE 'name:\s+pg$' "$f"
}
@test "the manifest is wired into the kustomization (prune would delete it otherwise)" {
  # ⚠️ cnpg-data App은 prune:true + selfHeal:true다 — resources에서 한 줄이 사라지는 것은
  #    곧 **클러스터에서의 삭제**다. 이 파일을 직접 grep하는 위 @test들은 배선 여부를 안 보므로,
  #    리팩터·머지 충돌로 한 줄이 없어져도 PR 게이트가 전건 초록이었다(실측).
  #    사후 검출은 R2BackupStale(≈27h)뿐이라 며칠 뒤 알림으로만 드러난다.
  # ⚠️ 원문 grep이 아니라 **파싱된** resources를 본다 — 주석 줄·들여쓰기 어긋난 줄이 통과한다
  #    (tests/gates/test_dual-run-excludes.bats:51-58의 관례). `yq -e`는 값 false와 키 부재를
  #    구별하지 못하므로 쓰지 않는다.
  run yq '.resources | contains(["scheduled-backup.yaml"])' platform/cnpg/prod/kustomization.yaml
  printf '%s' "$output" | grep -qxF -- 'true'
}
