#!/usr/bin/env bats
# DR drill 스크립트(R5)의 안전 불변식을 오프라인에서 강제한다 — 라이브 파괴 없이.
#
# ⚠️ grep 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 파일이라 그것으로 닫힌다.
#    ⚠️ `run bash "$fx/scripts/dr-drill.sh"`의 `-ne 0`은 **비대상**이다 — 그 rc는 스크립트 자신의
#       종료코드 규약이지 grep의 것이 아니다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
sh=scripts/dr-drill.sh

@test "dr-drill exists, is executable, and passes shellcheck" {
  [ -x "$sh" ]
  run shellcheck "$sh"
  [ "$status" -eq 0 ]
}

# ── bulk 국면 A(D4 한시) 거부 게이트 ───────────────────────────────────────────────────────
# ⚠️ 아래 두 @test는 dr-drill.sh를 **실제로 실행한다.** 진짜 레포 루트에서는 절대 안 된다
#    (`==> [1]`이 노드를 파괴한다) — 대신 **복사본을 픽스처 REPO_ROOT 위에서** 돌린다. 그 트리에는
#    ⚠️ 줄번호로 부르지 않는다: 이 자리는 예전에 `:108`이라 적혀 있었고 그 줄은 이미 두 번 밀렸다
#       (같은 이유로 dr-drill.sh의 상호참조도 단계 마커로 바꿨다).
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
  # 파괴 전 복구 증명이 **실제 파괴 호출**보다 먼저 와야 한다 — 핵심 안전 불변식.
  # ⚠️ 앵커를 배너(`==> [1]`)가 아니라 destroy-node.sh **호출 줄**에 건다: 지켜야 할 것은
  #    "증명이 echo보다 먼저"가 아니라 "증명이 파괴보다 먼저"다.
  # ⚠️ `^[^#]*` — dr-drill.sh의 **주석에도 같은 경로가 들어 있어서**(헤더 :3) 전체 줄 grep은
  #    주석 줄번호를 집어 순서 단언을 거짓 red로 만든다(:44-45가 기록한 실측과 같은 클래스).
  proof_line=$(grep -nE '^[^#]*DR ABORT: 파괴 전 복구 실패' "$sh" | head -1 | cut -d: -f1)
  destroy_line=$(grep -nE '^[^#]*scripts/destroy-node\.sh' "$sh" | head -1 | cut -d: -f1)
  [ -n "$proof_line" ] && [ -n "$destroy_line" ]
  [ "$proof_line" -lt "$destroy_line" ]
}

@test "dr-drill takes a VERIFIED backup (waits for completed, not a fixed sleep)" {
  grep -q 'kind: Backup' "$sh"
  grep -q 'completed' "$sh"
  grep -q 'COMPLETE되지 않음' "$sh"
}

@test "dr-drill destroys the node via the dedicated primitive and rebuilds from committed host-config + install" {
  # ⚠️ **문자열만 갈아끼우면 또 다른 거짓 초록이다.** D-j 이후 이 @test가 지켜야 할 실질은 셋이다:
  #    (a) 파괴가 전용 프리미티브를 거친다(드릴 본문에 파괴 명령이 인라인되지 않는다),
  #    (b) 확인 env를 **명시적으로** 준다(주입이 사라지면 드릴이 [1]에서 조용히 멈춘다),
  #    (c) 그 호출이 실패를 삼키지 않는다 — `|| true`가 되살아나면 [2] 이후가 '재구축'이 아니라
  #        멀쩡한 노드 재확인이 되고 드릴이 아무것도 증명하지 않은 채 PASS를 찍는다.
  #        그것이 예전 `orb delete -f k3s || true`의 정확한 고장 모드였다.
  grep -qE '^[^#]*DR_DRILL_DESTROY_CONFIRM=1[[:space:]]+bash[[:space:]].*scripts/destroy-node\.sh' "$sh"
  [ -x scripts/destroy-node.sh ]
  run grep -nE '^[^#]*destroy-node\.sh.*\|\|[[:space:]]*true' "$sh"
  [ "$status" -eq 1 ]
  # ⚠️ 한 줄 안에서만 보면 **줄바꿈 연결로 우회된다**(`… destroy-node.sh \` + 다음 줄 `|| true`).
  run grep -nE '^[^#]*bash[^#]*destroy-node\.sh[^#]*\\$' "$sh"
  [ "$status" -eq 1 ]
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
  [ "$status" -eq 1 ]
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
  # ⚠️ 열거를 **권한 상승해서** 한다. /mnt/bulk는 0700 root라(infra/k3s-bootstrap/README.md의 국면 A
  #    절차) 비권한 읽기의 EACCES가 빈 출력으로 둔갑해 '비어 있음'이라는 거짓 진단을 낸다.
  grep -qE '^[^#]*\$K3S_RUN find ' "$sh"
  # 열거 실패와 '항목 0'은 다른 사건이다 — 분기가 둘 다 있어야 한다.
  grep -q '열거하지 못했다' "$sh"
}

@test "no OrbStack binding remains in the DR destruction path (code, not prose)" {
  # 감사 12가 요구한 '가드 1건 신설'. 이 자리가 사고의 진원이다 — `orb delete -f k3s || true`가
  # 리눅스에서 조용히 no-op이라 드릴이 아무것도 파괴하지 않은 채 흐르는 것이 원래 결함이었고,
  # 그것을 실증하려고 명령을 실제로 실행한 것이 2026-08-16 사고였다.
  # ⚠️ 전체 파일 grep은 **자기 주석에 걸린다** — 두 파일의 헤더가 무엇이 왜 사라졌는지 설명하며
  #    그 단어들을 그대로 담는다. 단언 대상은 산문이 아니라 **코드**다.
  # ⚠️ 양성 대조를 **두 파일 모두**에 건다. 하나만 걸면, 두 번째 파일이 삭제/리네임됐을 때
  #    grep이 exit 2(비-0)로 죽고 `[ "$status" -ne 0 ]`가 통과해 **vacuous green**이 된다.
  #    그래서 부재 단언도 `-eq 1`이다 — 이 자리는 `-q`가 아니라 `-nE`라 한쪽 파일이 사라지면
  #    남은 파일에 매치가 있어도 rc 2가 보존된다(`-q`였다면 매치가 그 에러를 덮어 0이 됐을 자리다).
  grep -qE '^[^#]*scripts/destroy-node\.sh' "$sh"
  grep -qE '^[^#]*\$K3S_RUN' scripts/destroy-node.sh
  run grep -nE '^[^#]*(orb |orbctl|virtiofs|/mnt/mac)' "$sh" scripts/destroy-node.sh
  [ "$status" -eq 1 ]
}

@test "dr-drill proves recovery of THIS cluster's archive (serverName derived, not the k8s name)" {
  # [0.5]의 '파괴 전 복구 가능성 증명'이 엉뚱한 아카이브를 복구하면, 그 증명이 통과한 뒤 노드를
  # 파괴한다 — 증명 대상과 파괴 대상이 어긋난다.
  grep -q 'ARCHIVE_SERVER=' "$sh"
  grep -q 'parameters.serverName' "$sh"
  grep -q 'serverName: ${ARCHIVE_SERVER}' "$sh"
  run grep -nE '^[^#]*serverName: \$\{LIVE_CLUSTER\}' "$sh"
  [ "$status" -eq 1 ]
}

@test "dr-drill purges a leftover drill cluster BEFORE apply (the false-proof that authorizes node destruction)" {
  # 🔴 M17과 같은 기전인데 결과가 더 무겁다: [0.5]의 PRE 판정이 **노드 파괴를 승인**한다.
  #    정리가 함수 말미에만 있으면 비정상 종료가 고아를 남기고, 다음 실행의 apply가 그 생존자에
  #    대해 no-op이 되어 R2를 만지지 않은 채 "복구 가능"으로 통과한다 → 거짓 증거로 라이브 파괴.
  # ⚠️ 정적 grep은 순서를 증명하지 못한다 — 여기서는 **구조**만 잠근다(진입점 존재 + apply 앞).
  grep -q '_purge_drill_cluster' "$sh"
  # pre-flight 호출이 heredoc의 apply보다 앞선다(줄 번호 비교 — 파일 어디에 있든이 아니라 순서다).
  p="$(grep -n '_purge_drill_cluster "\$1"' "$sh" | head -1 | cut -d: -f1)"
  a="$(grep -n 'kubectl apply -f - >/dev/null <<YAML' "$sh" | head -1 | cut -d: -f1)"
  [ -n "$p" ]
  [ -n "$a" ]
  [ "$p" -lt "$a" ]
}

@test "dr-drill requires a positive witness that recovery actually ran (not just a healthy phase)" {
  # .status.phase는 생존자에게 즉시 참이고, canary 행 수는 initdb 1회성 시드라 상수다.
  # 두 관측점 모두 진짜 복구와 생존자 재사용을 구별하지 못한다 — 첫 폴링 healthy가 그 증거다.
  grep -q 'saw_nonhealthy' "$sh"
  grep -q '첫 폴링에 이미 healthy' "$sh"
}

@test "dr-drill deletes drill PVCs by NAME as well as by label (the label was never positively observed)" {
  # 라벨 셀렉터는 빗나가도 rc 0 + 0줄이라 '잔여 없음'과 원리적으로 구별되지 않는다.
  # 이름 접두 삭제가 그 실명을 이중화한다.
  grep -q 'persistentvolumeclaim/\$1' "$sh"
}
