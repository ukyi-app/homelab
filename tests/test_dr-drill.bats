#!/usr/bin/env bats
# DR drill 스크립트(R5)의 안전 불변식을 오프라인에서 강제한다 — 라이브 파괴 없이.
sh=scripts/dr-drill.sh

@test "dr-drill exists, is executable, and passes shellcheck" {
  [ -x "$sh" ]
  run shellcheck "$sh"
  [ "$status" -eq 0 ]
}

# ── bulk 국면 A(D4 한시) 거부 게이트 ───────────────────────────────────────────────────────
# ⚠️ 아래 두 @test는 dr-drill.sh를 **실제로 실행한다.** 진짜 레포 루트에서는 절대 안 된다(:108이
#    노드를 파괴한다) — 대신 **복사본을 픽스처 REPO_ROOT 위에서** 돌린다. 그 트리에는
#    scripts/sealing-key-dr-gate.sh가 없으므로 가드가 깨져 있으면 바로 다음 줄에서 죽는다.
#    즉 파괴 지점에 닿을 길이 원리적으로 없다. grep만으로는 "가드가 **맨 앞**에 있는가"를
#    증명할 수 없어서 이 형태를 골랐다.
_drill_fixture() {          # $1 = BULK_MIGRATION_WINDOW_UNTIL 값
  fx="$BATS_TEST_TMPDIR/fx$RANDOM"
  mkdir -p "$fx/scripts" "$fx/infra/k3s-bootstrap"
  cp "$sh" "$fx/scripts/dr-drill.sh"
  printf 'export BULK_MIGRATION_WINDOW_UNTIL="%s"\n' "$1" > "$fx/infra/k3s-bootstrap/versions.env"
  echo "$fx"
}

@test "dr-drill REFUSES to run while the phase-A bulk window is open" {
  fx="$(_drill_fixture 2026-12-31)"
  run bash "$fx/scripts/dr-drill.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'DR ABORT: 국면 A'
  printf '%s' "$output" | grep -qF -- '2026-12-31'
}

@test "the phase-A refusal does NOT fire once the window is cleared (positive control)" {
  # 이게 없으면 '항상 거부하는' 가드도 위 @test를 통과한다.
  fx="$(_drill_fixture '')"
  run bash "$fx/scripts/dr-drill.sh"
  [ "$status" -ne 0 ]                       # 픽스처엔 sealing-key 게이트가 없어 어차피 죽는다
  ! printf '%s' "$output" | grep -qF -- 'DR ABORT: 국면 A'
}

@test "the phase-A gate precedes every side effect (source, yq derivation, destruction)" {
  # ⚠️ 앵커를 `orb delete`에 걸지 않는다 — D-j(베어메탈 파괴 프리미티브)가 그 줄을 교체하는 순간
  #    이 @test까지 같이 무너진다. 단계 마커 `==> [1]`은 그 교체를 넘어 살아남는다.
  # ⚠️ `^[^#]*` — 이 파일과 dr-drill.sh 양쪽의 **주석이 같은 문자열을 담고 있어서**, 전체 줄
  #    grep은 주석 줄번호를 집어 순서 단언을 거짓 red로 만든다(실측: 처음 작성했을 때 그랬다).
  gate=$(grep -nE '^[^#]*DR ABORT: 국면 A' "$sh" | head -1 | cut -d: -f1)
  src=$(grep -nE '^[^#]*sealing-key-dr-gate\.sh' "$sh" | head -1 | cut -d: -f1)
  yqline=$(grep -nE '^[^#]*PG_IMAGE=' "$sh" | head -1 | cut -d: -f1)
  destroy=$(grep -nE '^[^#]*==> \[1\]' "$sh" | head -1 | cut -d: -f1)
  [ -n "$gate" ] && [ -n "$src" ] && [ -n "$yqline" ] && [ -n "$destroy" ]
  [ "$gate" -lt "$src" ]
  [ "$gate" -lt "$yqline" ]
  [ "$gate" -lt "$destroy" ]
}

@test "dr-drill requires the out-of-band age key (R5 input that survives node loss)" {
  grep -q 'SOPS_AGE_KEY_FILE' "$sh"
  grep -q 'age key missing' "$sh"
}

@test "dr-drill PROVES recoverability BEFORE any destruction (refuses to destroy otherwise)" {
  # 파괴 전 복구 증명이 'orb delete'보다 먼저 와야 한다 — 핵심 안전 불변식.
  proof_line=$(grep -n 'DR ABORT: 파괴 전 복구 실패' "$sh" | head -1 | cut -d: -f1)
  destroy_line=$(grep -n 'orb delete -f k3s' "$sh" | head -1 | cut -d: -f1)
  [ -n "$proof_line" ] && [ -n "$destroy_line" ]
  [ "$proof_line" -lt "$destroy_line" ]
}

@test "dr-drill takes a VERIFIED backup (waits for completed, not a fixed sleep)" {
  grep -q 'kind: Backup' "$sh"
  grep -q 'completed' "$sh"
  grep -q 'COMPLETE되지 않음' "$sh"
}

@test "dr-drill destroys the node (cattle) and rebuilds from committed host-config + install" {
  grep -q 'orb delete -f k3s' "$sh"
  grep -q 'infra/k3s-bootstrap/host-up.sh' "$sh"
  grep -q 'make bootstrap' "$sh"
  # ⚠️ 이름이 주장하는 "커밋된 것에서 재구축"을 실제로 앵커한다. 예전 이름은 `cloud-init`을
  #    말했지만 본문은 그 문자열을 한 번도 보지 않았다 — 그래서 `cloud-init.yaml`을 지워도 이
  #    @test는 초록으로 남았다(복사본 트리에서 실증: red는 test_03의 7건뿐이었다).
  grep -q 'host-config/install' "$sh"
}

@test "dr-drill recovers the DB from R2 on the rebuilt node and checks the canary" {
  grep -q 'recovery:' "$sh"
  grep -q 'barmanObjectName: pg-r2' "$sh"
  grep -q 'restore_canary' "$sh"
  grep -q 'DR DRILL FAIL: recovered canary' "$sh"
}

@test "dr-drill uses drill-ssd (Delete reclaim) so verify clusters never leak storage" {
  grep -q 'storageClass: drill-ssd' "$sh"
  grep -q 'delete pvc' "$sh"
}

@test "dr-drill re-exports KUBECONFIG after the VM is rebuilt" {
  # host-up.sh가 kubeconfig를 재생성하므로 재구축 후 재export가 없으면 stale 컨텍스트로 죽는다.
  grep -q 'use_live_kubeconfig # host-up.sh가 kubeconfig를 재생성한다' "$sh"
}

@test "dr-drill prints the canonical PASS marker only at the very end" {
  grep -q 'DR DRILL PASS' "$sh"
  [ "$(grep -c 'DR DRILL PASS' "$sh")" -eq 1 ]
  [ "$(tail -1 "$sh" | grep -c 'DR DRILL PASS')" -eq 1 ]
}

@test "dr-drill [6] verifies a workload that still exists (no removed in-repo app)" {
  # prod/deploy/api는 제거됨(인-레포 앱 0) — 워크로드 서빙 검증은 현존 코어 서비스(adguard)를 가리킨다.
  run grep -n 'deploy/api' "$sh"
  [ "$status" -ne 0 ]
  grep -q 'rollout status deploy/adguard' "$sh"
}

@test "dr-drill derives the PG image from cluster.yaml instead of hardcoding a pin" {
  # 하드코딩 핀은 PG 메이저 갱신 시 cross-major 물리복구 불가로 드릴을 조용히 죽인다(M6).
  # SSOT = platform/cnpg/prod/cluster.yaml spec.imageName — 파생 실패는 fail-closed.
  run grep -c 'cloudnative-pg/postgresql:[0-9]' "$sh"
  [ "$output" -eq 0 ]                                  # 리터럴 태그 핀 0
  grep -q 'platform/cnpg/prod/cluster.yaml' "$sh"      # SSOT 참조
  grep -q 'imageName: ${PG_IMAGE}' "$sh"               # heredoc이 파생 변수 사용
  grep -q 'PG 이미지 파생 실패' "$sh"                   # fail-closed 분기 존재
}

@test "dr-drill re-attaches files data and refuses a silently-empty catalog (M14)" {
  grep -q 'rollout status deploy/files' "$sh"
  grep -q 'files-data PV 미바운드' "$sh"
  grep -q 'files 카탈로그 비어있음' "$sh"
}

@test "dr-drill proves recovery of THIS cluster's archive (serverName derived, not the k8s name)" {
  # [0.5]의 '파괴 전 복구 가능성 증명'이 엉뚱한 아카이브를 복구하면, 그 증명이 통과한 뒤 노드를
  # 파괴한다 — 증명 대상과 파괴 대상이 어긋난다.
  grep -q 'ARCHIVE_SERVER=' "$sh"
  grep -q 'parameters.serverName' "$sh"
  grep -q 'serverName: ${ARCHIVE_SERVER}' "$sh"
  run grep -nE '^[^#]*serverName: \$\{LIVE_CLUSTER\}' "$sh"
  [ "$status" -ne 0 ]
}
