#!/usr/bin/env bats
f=platform/cnpg/prod/scheduled-backup.yaml
@test "daily cron and immediate first run" {
  grep -qE 'schedule:\s*"0 0 3 \* \* \*"' "$f" # CNPG 6-field cron, 03:00**Z**(operator TZ=UTC) = 12:00 KST
  grep -q 'immediate: true' "$f"
}
@test "plugin-based backup against cluster pg" {
  grep -q 'method: plugin' "$f"
  grep -qE 'name:\s+pg$' "$f"
  # ⚠️ 이름이 "plugin-based"인데 정작 **어느 플러그인인지**를 안 봤다 — pluginConfiguration 블록을
  #    지워도, 값을 틀리게 바꿔도 2/2 초록이었다(실측). 라이브 vscheduledbackup.cnpg.io 웹훅도
  #    두 형태를 accepted로 통과시키고(CRD의 이 필드는 CEL·enum 없는 plain string), 어긋나면
  #    ScheduledBackup이 발화해도 base backup이 만들어지지 않는다. WALArchiveStalled는
  #    Cluster.spec.plugins 경로라 무관하고, 사후 검출은 R2BackupStale(≈27h)뿐이다.
  # 리터럴 9번째 사본을 만들지 않는다 — 아카이버가 곧 백업 엔진이라는 등호를 cluster.yaml에서
  # 파생해 그대로 표현한다(형제 test_pgdump_hedge.bats:69-74 관용구). `yq -e '… == "리터럴"'`은
  # 값이 false면 exit 1이라 쓰지 않고, 값을 꺼내 비교하며 부재(null)를 명시적으로 배제한다.
  c=platform/cnpg/prod/cluster.yaml
  [ -s "$c" ] # 피연산자 실재 앵커
  want="$(yq '.spec.plugins[] | select(.isWALArchiver == true) | .name' "$c" | head -1)"
  got="$(yq '.spec.pluginConfiguration.name' "$f")"
  [ -n "$want" ]        # 열거 붕괴 방지 — 0건은 "분리됨"이 아니라 "못 쟀다"
  [ "$want" != "null" ]
  [ -n "$got" ]
  [ "$got" != "null" ]
  [ "$got" = "$want" ]
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
