#!/usr/bin/env bats
# 변이 디스패처(create-app/update-secrets/create-database/create-cache) 구조·notify 불변식.
# 구 단일 디스패처 전용 테스트(삭제됨)의 단언을 4 디스패처로 일반화.
# (@test 이름 영어, 단언은 run+[ ] — bash 3.2 [[ ]] 침묵통과 함정 회피)
#
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 워크플로 **파일**이라 그것으로 닫힌다.
#    반면 루프 구동 자리(DISPATCHERS·글롭)는 반복 0회가 어떤 rc로도 안 보이므로, setup의 열거
#    바닥값과 각 @test의 양성 대조가 한 쌍으로 닫는다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
setup() {
  ROOT="$(git rev-parse --show-toplevel)"; WF="$ROOT/.github/workflows"
  # 디스패처 목록 동적 파생 — 하드코딩 열거는 신규 디스패처를 조용히 빠뜨린다(fail-open, arch-meta finding).
  # 규칙: workflow_dispatch 보유 + 동명 reusable(uses: ./.github/workflows/_<self>.yaml) 참조.
  DISPATCHERS=""; DISPATCHER_N=0
  for f in "$WF"/*.yaml; do
    base="$(basename "$f" .yaml)"
    case "$base" in _*) continue;; esac
    grep -q 'workflow_dispatch:' "$f" || continue
    grep -q "uses: ./.github/workflows/_${base}.yaml" "$f" || continue
    DISPATCHERS="$DISPATCHERS $base"; DISPATCHER_N=$((DISPATCHER_N + 1))
  done
  # 열거 바닥값 — WF가 리네임되면 글롭이 리터럴로 남아 파생이 0건이 되고, 아래 루프 구동 @test들이
  # 반복 0회로 조용히 초록이 된다. setup에 두어 **개별 @test 실행에서도** 닫는다.
  # 5는 이 파일이 이미 소유한 레인 수다(아래 known five 열거 · bun 디스패처 붕괴 하한 · LANES 행 수)
  # — 손으로 관리하는 새 수치가 아니다.
  [ -d "$WF" ]
  [ -n "$DISPATCHERS" ]
  [ "$DISPATCHER_N" -ge 5 ]
}

@test "every dispatcher serializes via homelab-mutation group with queue max" {
  # ⚠️ `queue: max`는 **키 행으로 앵커한다** — 무앵커 grep은 규약을 설명하는 주석에 걸려, 실키를
  #    지워도 초록이었다(실측 2026-09-03 · 형제 자리 tests/gates/test_actionlint-gate.bats:17).
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"; [ -f "$f" ]
    grep -q "group: homelab-mutation" "$f"
    grep -Eq '^[[:space:]]*queue:[[:space:]]*max[[:space:]]*$' "$f"
    grep -q "cancel-in-progress: false" "$f"
  done
}

@test "every job holding the homelab-mutation group carries a timeout-minutes ceiling" {
  # 이 그룹은 `queue: max` + `cancel-in-progress: false`라 in-progress run이 끝날 때까지 나머지를
  # pending FIFO로 붙든다 — 잡 하나가 네트워크에서 hang하면 변이 플레인 전체가 platform max(6h)까지
  # 선다. 실행기 쪽 하위 상한도 없다(tools/lib/exec.ts `timeoutMs: 0`). 유일한 런타임 신호인
  # GHAWorkflowStale은 예산이 21600s라 그 6h와 사실상 같은 시각에 울린다. 형제 자리에서 이미 채택한
  # 방어다(reusable-app-build 2026-08-24 6h 실사고 · contract-drift).
  # ⚠️ 디스패처의 route 잡(`uses: ./.github/workflows/_<self>.yaml`)에는 timeout-minutes를 둘 수 없다
  #    — actionlint가 거부한다. 그래서 `uses:`를 **따라 내려가** 그 reusable의 잡에서 상한을 찾는다.
  #    따라가지 않으면 변이 본체 5종이 통째로 분모 밖이 되어 초록이 무의미해진다.
  command -v yq >/dev/null || skip "yq required"
  wfn=0; checked=0; followed=0; bad=""
  for f in "$WF"/*.yaml; do
    [ -e "$f" ] || continue
    wg="$(yq -r '.concurrency.group // ""' "$f")"   # workflow-레벨 그룹
    keys="$(yq -r '.jobs | keys | .[]' "$f")"
    holder=0
    while read -r j; do
      [ -n "$j" ] || continue
      jg="$(yq -r ".jobs.\"$j\".concurrency.group // \"\"" "$f")"   # 잡-레벨 그룹(iac.yaml apply)
      hold=0
      if [ "$wg" = "homelab-mutation" ]; then hold=1; fi
      if [ "$jg" = "homelab-mutation" ]; then hold=1; fi
      [ "$hold" -eq 1 ] || continue
      holder=1
      uses="$(yq -r ".jobs.\"$j\".uses // \"\"" "$f")"
      case "$uses" in
        ./.github/workflows/*)
          tgt="$ROOT/${uses#./}"
          [ -f "$tgt" ] || { bad="$bad
  $(basename "$f"):$j → $uses 파일 부재"; continue; }
          followed=$(( followed + 1 ))
          tkeys="$(yq -r '.jobs | keys | .[]' "$tgt")"
          while read -r tj; do
            [ -n "$tj" ] || continue
            checked=$(( checked + 1 ))
            tm="$(yq -r ".jobs.\"$tj\".\"timeout-minutes\" // \"\"" "$tgt")"
            [ -n "$tm" ] || bad="$bad
  $(basename "$tgt"):$tj — timeout-minutes 없음(route 잡 $(basename "$f"):$j 경유)"
          done <<EOF
$tkeys
EOF
          ;;
        *)
          checked=$(( checked + 1 ))
          tm="$(yq -r ".jobs.\"$j\".\"timeout-minutes\" // \"\"" "$f")"
          [ -n "$tm" ] || bad="$bad
  $(basename "$f"):$j — timeout-minutes 없음"
          ;;
      esac
    done <<EOF
$keys
EOF
    wfn=$(( wfn + holder ))
  done
  [ -z "$bad" ] || { echo "$bad"; false; }
  # 열거 바닥값 — 셋 다 있어야 "위반 0"이 "아무것도 안 봤다"와 갈린다(부정 카운트 판정이라 루프가
  # 0회 돌아도 rc에 안 보인다). 수치는 도메인이 소유한다:
  #   9  = 그룹 보유 워크플로(bump-poll·bump·tf-reconcile·iac·변이 디스패처 5종)
  #   5  = route 잡을 따라 들어간 reusable(_create-app/_create-cache/_create-database/_teardown-app/_update-secrets)
  #   20 = 그 안에서 실제로 상한을 확인한 잡 수의 하한(현재 26)
  [ "$wfn" -ge 9 ]
  [ "$followed" -ge 5 ]
  [ "$checked" -ge 20 ]
}

@test "every job in every workflow carries a timeout-minutes ceiling below the platform max" {
  # 위 @test의 분모는 homelab-mutation 그룹 9 워크플로뿐이었다 — 그룹 밖(ci·build·audit·dns-drift·
  # pr-sweeper·credential-expiry·renovate·iac의 PR 잡·reusable-app-build deploy-trigger)은 상한 없이
  # platform max(6h)에 노출된 채였다. 이 @test가 분모를 **전 워크플로**로 넓힌다. 두 @test는 축이
  # 다르므로 공존한다: 위는 "그룹을 쥐는 잡이 빠짐없이 덮이는가"(route `uses:` 하강 포함), 여기는
  # "워크플로 파일 안의 모든 잡이 덮이는가"다. 그룹 판정이 깨져도 여기가, 파일이 통째로 새로 생겨도
  # 여기가 먼저 잡는다.
  # ⚠️ 여기서는 route 잡의 `uses:`를 따라 내려가지 않는다 — 하강 대상인 `_*.yaml`이 이 글롭 안이라
  #    **직접** 검사되기 때문이다. 그 전제가 깨지는 경우(대상이 이 디렉토리 밖)를 routes 레인이 red로
  #    만든다. 따라가지 않으면서 전제도 안 보면 변이 본체 5종이 조용히 분모 밖으로 샌다.
  # ⚠️ **존재만 보면 안 된다** — `timeout-minutes: 360`은 platform 기본값과 같아 이름만 상한이다.
  #    값이 정수이고 1..359인지 함께 본다(360 이상 = 천장이 아니라 no-op).
  command -v yq >/dev/null || skip "yq required"
  wfn=0; checked=0; routes=0; bad=""
  for f in "$WF"/*.yaml; do
    [ -e "$f" ] || continue
    wfn=$(( wfn + 1 ))
    keys="$(yq -r '.jobs | keys | .[]' "$f")"
    while read -r j; do
      [ -n "$j" ] || continue
      uses="$(yq -r ".jobs.\"$j\".uses // \"\"" "$f")"
      if [ -n "$uses" ]; then
        # route 잡(`uses:`)엔 timeout-minutes를 둘 수 없다(actionlint 거부) — 본체가 이 글롭 안에
        # 있는지만 확인하고 상한 자체는 그 파일 차례에 본다.
        routes=$(( routes + 1 ))
        case "$uses" in
          ./.github/workflows/*)
            [ -f "$ROOT/${uses#./}" ] || bad="$bad
  $(basename "$f"):$j — route 대상 $uses 파일 부재" ;;
          *)
            bad="$bad
  $(basename "$f"):$j — route 대상이 .github/workflows 밖이다($uses) — 상한 분모에서 샌다" ;;
        esac
        continue
      fi
      checked=$(( checked + 1 ))
      tm="$(yq -r ".jobs.\"$j\".\"timeout-minutes\" // \"\"" "$f")"
      case "$tm" in
        ''|*[!0-9]*)
          bad="$bad
  $(basename "$f"):$j — timeout-minutes 없음/비정수('$tm')"
          continue ;;
      esac
      [ "$tm" -ge 1 ] && [ "$tm" -lt 360 ] || bad="$bad
  $(basename "$f"):$j — timeout-minutes $tm 은 천장이 아니다(1..359 밖 · 360=platform 기본값)"
    done <<EOF
$keys
EOF
  done
  [ -z "$bad" ] || { echo "$bad"; false; }
  # 열거 바닥값 — 셋 다 있어야 "위반 0"이 "아무것도 안 봤다"와 갈린다(부정 카운트 판정이라 루프가
  # 0회 돌아도 rc에 안 보인다). 수치는 도메인이 소유한다:
  #   20 = 워크플로 파일 수의 하한(현재 23) — 글롭이 리터럴로 남으면 여기서 먼저 죽는다
  #   35 = 상한을 실제로 확인한 비-route 잡 수의 하한(현재 41)
  #   5  = route 잡 수(변이 디스패처 5종 — 위 @test의 followed와 같은 집합)
  [ "$wfn" -ge 20 ]
  [ "$checked" -ge 35 ]
  [ "$routes" -ge 5 ]
}

@test "no workflow combines queue:max with cancel-in-progress:true" {
  hits=0
  for f in "$WF"/*.yaml; do
    if grep -q "queue: max" "$f"; then
      hits=$((hits + 1))
      run grep -q "cancel-in-progress: true" "$f"; [ "$status" -eq 1 ]
    fi
  done
  # 양성 대조 — 루프 조건(`queue: max`)이 어디선가 참이었다. 조건이 전수 거짓이면 반복 0회라
  # 위 단언이 한 번도 평가되지 않는데 그것은 rc에 안 보인다(setup의 열거 바닥값과 한 쌍).
  [ "$hits" -ge 1 ]
}

@test "create-app dispatcher grants packages:read on the reusable call job" {
  grep -q "packages: read" "$WF/create-app.yaml"
}

@test "each dispatcher validates with fixed action then routes to its reusable" {
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"
    grep -q "validate-mutation.ts --action $d" "$f"
    grep -q "needs: validate" "$f"
    grep -q "uses: ./.github/workflows/_$d.yaml" "$f"
  done
}

@test "each dispatcher notify job needs the actual mutation job (not validate alone)" {
  # wf-mutation-dispatch-1: notify의 needs가 validate만 남고 실제 변이 잡(예: create-app)이 빠지면
  # failure()/cancelled()가 참조할 상류가 validate뿐이 되어, validate 성공 시 notify가 무조건 skip된다
  # — telegram 실패 알림이 완전히 죽는다. 위 @test의 `needs: validate`는 변이 잡 자신의 needs(단수,
  # 별개 줄)라 notify 잡의 needs 리스트(복수, `[validate, $d]`)와 매치 대상이 다르다 — 여기서
  # 리스트 원소를 앵커로 직접 검사한다(잡 이름은 파일 basename과 동일 — 위 setup 파생과 같은 전제).
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"
    grep -q "needs: \[validate, $d\]" "$f"
  done
}

@test "each dispatcher triggers only on workflow_dispatch (homelab-initiated boundary)" {
  # 양성 대조 — 같은 술어가 같은 트리 어딘가에서는 매치한다(push/schedule 구동 워크플로가 실재).
  # 술어 쪽이 부패하면 디스패처 전수 무매치가 정당한 결과처럼 보이는데, 이 줄이 먼저 red다.
  run grep -rlE "repository_dispatch|pull_request:|push:|schedule:" "$WF"
  [ "$status" -eq 0 ]
  for d in $DISPATCHERS; do
    run grep -E "repository_dispatch|pull_request:|push:|schedule:" "$WF/$d.yaml"
    [ "$status" -eq 1 ]
  done
}

@test "each dispatcher references inputs only via env or with: (no run inline interpolation)" {
  for d in $DISPATCHERS; do
    bad=$(grep -n 'github.event.inputs' "$WF/$d.yaml" \
      | grep -vE '^[0-9]+:[[:space:]]*(#|[A-Z_]+:|(sha|spec|app|confirm):)' || true)
    [ -z "$bad" ]
  done
}

@test "each dispatcher declares only its contract inputs" {
  # create-app/update-secrets는 app만(repo=ukyi-app/<app>·sha는 reusable이 main HEAD에서 해석 — 입력 없음).
  grep -q "app:" "$WF/create-app.yaml";     run grep -q "app_repo:" "$WF/create-app.yaml";     [ "$status" -eq 1 ]
  grep -q "app:" "$WF/update-secrets.yaml"; run grep -q "app_repo:" "$WF/update-secrets.yaml"; [ "$status" -eq 1 ]
  grep -q "spec:" "$WF/create-database.yaml"
  grep -q "spec:" "$WF/create-cache.yaml"
}

@test "create-app and update-secrets no longer reference app_repo anywhere (org is structurally ukyi-app)" {
  # 단일 결정 단언(bats는 마지막 명령만 평가) — 4 파일 어디에도 app_repo가 없어야 한다.
  # 형제 양성 단언이 없어 `-eq 1`이 파일 실재의 유일한 증인이다(넷 중 하나만 사라져도 rc 2).
  run grep -l "app_repo" "$WF/create-app.yaml" "$WF/_create-app.yaml" "$WF/update-secrets.yaml" "$WF/_update-secrets.yaml"
  [ "$status" -eq 1 ]
}

@test "each dispatcher notify fires on cancelled as well as failure" {
  for d in $DISPATCHERS; do
    run grep -nE "if:\s*failure\(\)\s*\|\|\s*cancelled\(\)" "$WF/$d.yaml"
    [ "$status" -eq 0 ]
  done
}

@test "dynamic DISPATCHERS derivation is non-empty and includes the known five" {
  [ -n "$DISPATCHERS" ]
  for d in create-app update-secrets create-database create-cache teardown-app; do
    case " $DISPATCHERS " in *" $d "*) : ;; *) false ;; esac
  done
}

@test "each dispatcher notify delegates to the mutation-notify composite" {
  # 양성 대조 — job.status 직접 참조 술어가 같은 트리 어딘가(reusable·이벤트 구동 워크플로)에서는
  # 매치한다. 표기가 바뀌어 술어가 죽으면 디스패처 전수 무매치가 정당해 보이는데, 이 줄이 먼저 red다.
  run grep -rlE 'status:[[:space:]]*\$\{\{[[:space:]]*job\.status[[:space:]]*\}\}' "$WF"
  [ "$status" -eq 0 ]
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"
    grep -q 'uses: ./.github/actions/mutation-notify' "$f"
    run grep -nE 'results:[[:space:]]*\$\{\{[[:space:]]*toJSON\(needs\)' "$f"; [ "$status" -eq 0 ]
    # norm 로직은 composite로 이동 — 디스패처엔 job.status 직접 참조가 없어야 한다
    run grep -nE 'status:[[:space:]]*\$\{\{[[:space:]]*job\.status[[:space:]]*\}\}' "$f"; [ "$status" -eq 1 ]
  done
}

@test "mutation-notify composite normalizes cancelled over failure and labels the mutation source" {
  a="$ROOT/.github/actions/mutation-notify/action.yml"
  [ -f "$a" ]
  grep -q 'status=cancelled' "$a"
  grep -q 'source: 변이' "$a"
  # ⚠️ 위 두 줄은 **리터럴 실재**만 잰다 — 정규화 술어를 도달불가로 만들어도(패턴을 "ZZZNEVER"로),
  #    두 echo 분기를 서로 맞바꿔도 리터럴이 그대로 남아 34/34 전건 초록이었다(2026-09-03 실측).
  #    이름이 약속한 「취소>실패」에 증인이 없던 자리다(traps 「테스트 이름은 인터페이스가 아니다」).
  # ⚠️ 스텝 선택은 인덱스가 아니라 **id**로 — steps[0]은 스텝 순서 드리프트에 조용히 엉뚱한 본문을 잡는다.
  body="$(yq -r '.runs.steps[] | select(.id == "norm") | .run' "$a")"
  [ -n "$body" ]   # 추출 붕괴 바닥값
  # ⚠️ **우선순위 증인은 혼합 페이로드다.** cancelled-only / failure-only 두 레인만으로는 단일 결과라
  #    우선순위 조건을 아예 밟지 않는다 — 취소와 실패가 **함께** 있는 입력이라야 술어가 답을 낸다.
  # ⚠️ `bash -c "$body"`는 큰따옴표로 — 홑따옴표면 bats 지역 변수가 빈 문자열이 되어 vacuous green이다
  #    (traps 「정적 증인의 두 함정」 병 ②).
  RESULTS='{"a":{"result": "cancelled"},"b":{"result": "failure"}}' \
    GITHUB_OUTPUT="$BATS_TEST_TMPDIR/norm.cancelled" bash -c "$body"
  grep -qx 'status=cancelled' "$BATS_TEST_TMPDIR/norm.cancelled"
  # 대조군 — 실패만 있으면 failure다(분기가 상수로 붕괴하면 둘 중 하나가 red).
  RESULTS='{"b":{"result": "failure"}}' \
    GITHUB_OUTPUT="$BATS_TEST_TMPDIR/norm.failure" bash -c "$body"
  grep -qx 'status=failure' "$BATS_TEST_TMPDIR/norm.failure"
}

# ⚠️ 아래 세 거부 레인은 `-ne 0`만으로 닫히지 않는다 — validate-mutation.ts를 지우면 bun도 비-0을
#    내므로 「검증기가 거부했다」와 「검증기가 없다」가 같은 초록이 됐다(실측: 도구 삭제 시 33/34 ok).
#    피연산자 실재 + 고정 에러 접두(`validate-mutation: `, tools/validate-mutation.ts:9)로 가른다.
#    접두를 쓰는 이유: 레인별 손복사 문구는 메시지 리워딩에 부서지고, 짧은 부분문자열은 bun의
#    `Module not found ".../validate-mutation.ts"`에 도로 매치한다.
@test "dispatcher rejects a reserved db name before the executor" {
  [ -f "$ROOT/tools/validate-mutation.ts" ]
  run bun "$ROOT/tools/validate-mutation.ts" --action create-database --payload '{"spec":"{\"name\":\"postgres\"}"}'
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'validate-mutation: spec.name 예약된 DB 이름'
}
@test "dispatcher rejects a cache -ro suffix name" {
  [ -f "$ROOT/tools/validate-mutation.ts" ]
  run bun "$ROOT/tools/validate-mutation.ts" --action create-cache --payload '{"spec":"{\"name\":\"foo-ro\"}"}'
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "validate-mutation: spec.name '-ro' 접미사 예약"
}
@test "dispatcher rejects a db -ro suffix name (F8)" {
  [ -f "$ROOT/tools/validate-mutation.ts" ]
  run bun "$ROOT/tools/validate-mutation.ts" --action create-database --payload '{"spec":"{\"name\":\"foo-ro\"}"}'
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "validate-mutation: spec.name '-ro' 접미사 예약"
}

@test "teardown-app dispatcher declares only app and confirm inputs (no app_repo)" {
  grep -q "app:" "$WF/teardown-app.yaml"
  grep -q "confirm:" "$WF/teardown-app.yaml"
  run grep -q "app_repo:" "$WF/teardown-app.yaml"; [ "$status" -eq 1 ]
}

@test "teardown-app reusable uses writer token only (no reader, no GHCR)" {
  grep -q "HOMELAB_WRITER_APP_ID" "$WF/_teardown-app.yaml"
  run grep -q "HOMELAB_READER_APP_ID" "$WF/_teardown-app.yaml"; [ "$status" -eq 1 ]
}

@test "teardown-app reusable enforces confirm at its boundary (workflow_call input + re-validate)" {
  grep -q "confirm:" "$WF/_teardown-app.yaml"                                  # workflow_call에 confirm 입력
  grep -q "validate-mutation.ts --action teardown-app" "$WF/_teardown-app.yaml" # teardown 前 재검증(defense-in-depth)
}

@test "teardown-app reusable does NOT auto-merge (destruction = manual merge)" {
  # 주석 제외 후 실행 라인만 검사 — 워크플로 주석에 'auto-merge-or-fail' 설명 문구가 있어 그대로 grep하면 오탐
  # ⚠️ 파이프 종단 grep이라 rc로는 못 닫는다 — 대상이 사라지면 앞 grep만 rc 2로 죽고 뒤 grep은 빈
  #    stdin에 무매치 rc 1을 내므로 `-eq 1` 전환조차 통과한다(SSOT ③-b · 2026-08-29 이 파일로 실측).
  #    파괴 경계의 불변식이 대상 리네임에 침묵 초록이면 안 되므로 실재를 먼저 못 박는다.
  [ -f "$WF/_teardown-app.yaml" ]
  run bash -c "grep -v '^[[:space:]]*#' '$WF/_teardown-app.yaml' | grep -q 'auto-merge-or-fail'"; [ "$status" -ne 0 ]
  run bash -c "grep -v '^[[:space:]]*#' '$WF/_teardown-app.yaml' | grep -qE 'gh pr merge.*--auto'"; [ "$status" -ne 0 ]
}

@test "every mutation reusable routes its PR through the pr-first-commit composite" {
  for wf in _create-app _create-database _create-cache _update-secrets _teardown-app; do
    grep -q 'uses: ./.github/actions/pr-first-commit' "$WF/$wf.yaml"
  done
}

@test "auto-merge policy is preserved per reusable (db/cache/secrets=true, app/teardown=false)" {
  for wf in _create-database _create-cache _update-secrets; do
    grep -qE "auto-merge:[[:space:]]*'true'" "$WF/$wf.yaml"
  done
  for wf in _create-app _teardown-app; do
    grep -qE "auto-merge:[[:space:]]*'false'" "$WF/$wf.yaml"
  done
}

@test "the five mutation reusables carry no inline bot identity copy (pr-first-commit is their SSOT)" {
  a="$ROOT/.github/actions/pr-first-commit/action.yml"
  grep -q 'ukyi-homelab-writer\[bot\]' "$a"
  # 다중 피연산자 — 다섯 중 하나라도 리네임되면 rc 2다. 위 양성 단언은 composite 파일이라
  # 이 다섯의 실재를 증언하지 않는다.
  run grep -l '293311924+ukyi-homelab-writer' "$WF"/_create-app.yaml "$WF"/_create-database.yaml "$WF"/_create-cache.yaml "$WF"/_update-secrets.yaml "$WF"/_teardown-app.yaml
  [ "$status" -eq 1 ]
}

@test "reusables carry no inline RESOURCE_NAME_RE copy (identity.ts SSOT via validate-mutation)" {
  for wf in _create-cache _create-database; do
    run grep -Fq '{0,28}' "$WF/$wf.yaml"; [ "$status" -eq 1 ]
    grep -q 'validate-mutation.ts --action' "$WF/$wf.yaml"
  done
}

@test "every mutation reusable re-validates via validate-mutation at its boundary (symmetric defense-in-depth)" {
  for wf in _create-app _update-secrets _create-database _create-cache _teardown-app; do
    grep -q 'validate-mutation.ts --action' "$WF/$wf.yaml"
  done
}

@test "every workflow_dispatch entrypoint is actor-guarded or explicitly allowlisted" {
  # 동적 열거(P2-1): 하드코딩 목록이 아니라 dispatch 보유 전수를 스캔 — 신규 워크플로 자동 편입(fail-open 차단).
  run bun -e '
    const y = require("yaml"), fs = require("fs");
    const dir = process.argv[1] + "/.github/workflows";
    const ALLOW = new Set(["bump-poll.yaml"]); // 자체 fail-closed 검증기 — 디스패치 자격의 의도된 유일 표적
    const bad = [];
    for (const f of fs.readdirSync(dir)) {
      if (!/\.ya?ml$/.test(f)) continue;
      const src = fs.readFileSync(dir + "/" + f, "utf8");
      const doc = y.parse(src);
      const on = doc?.on ?? doc?.[true];   // 일부 YAML 파서의 on→true 키 함정 방어
      const hasDispatch = !!on && typeof on === "object" && Object.prototype.hasOwnProperty.call(on, "workflow_dispatch");
      if (!hasDispatch || ALLOW.has(f)) continue;
      // 재료 3개의 **존재**만 보면 술어가 틀려도 초록이다(실측: `=`→`!=`가 통과했다) — 위 개수
      // 등식과 아래 실행 증인이 그 축을 닫는다. 여기서는 거부 문구를 **닫힌 열거**로 못박는다:
      // 오늘 두 변종이 있고(수동 진입 / 변이), 세 번째는 규약 결정이지 조용히 늘 것이 아니다.
      const REJECT = ["workflow_dispatch는 owner(", "변이 디스패처는 owner("];
      const guarded = src.includes("vars.HOMELAB_OWNER") && src.includes("github.actor")
        && src.includes("HOMELAB_OWNER 미설정") && REJECT.some((m) => src.includes(m));
      if (!guarded) bad.push(f + ": workflow_dispatch 진입점에 actor 가드 부재(허용목록 아님)");
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$ROOT"
  [ "$status" -eq 0 ]
}

@test "bump-poll stays allowlisted WITHOUT the actor guard (intended dispatch target)" {
  # 이 @test에는 형제 단언이 없다 — `-ne 0`이면 bump-poll.yaml 리네임에도 홀로 초록으로 남는다.
  run grep -q 'HOMELAB_OWNER' "$WF/bump-poll.yaml"; [ "$status" -eq 1 ]
}

@test "reusable branch: lines match the lane rows' neutral patterns (TS-YAML parity)" {
  # 레인 신원 parity 축 1(cli-deepening 심화 2): YAML 쪽 branch: 개명은 어떤 테스트도 red가
  # 아니었다 — 이 가드가 그 방향을 CI로 당긴다. 값은 YAML 파서로 읽는다(따옴표·주석 재포맷에
  # 흔들리지 않고, 축 2와 같은 venue). key 표현식은 레인별 **열거 매핑**(가드 소유 — 설계 심화 2
  # "정규화 매핑은 가드 쪽")으로 기대 문자열을 조립해 정확 대조한다 — 포괄 ${{…}}→{key} 붕괴는
  # 오타 표현식(inputs.applicaton)도 green으로 접는 fail-open이다(리뷰 실측). 경로는 $ROOT 절대
  # (cwd 의존은 venue가 갈리면 로컬이 CI를 예고하지 못한다). 5는 레인 수 손 앵커다.
  run bun -e '
    const root = process.argv[1];
    const { parse } = require("yaml");
    const { readFileSync } = require("node:fs");
    const { LANES, fillLanePattern } = await import(root + "/tools/lib/catalog-rows.ts");
    const KEY_EXPR = {
      "create-database": "steps.spec.outputs.name",
      "create-cache": "steps.spec.outputs.name",
      "create-app": "steps.img.outputs.app",
      "update-secrets": "inputs.app",
      "teardown-app": "inputs.app",
    };
    const collect = (node, out) => {
      if (Array.isArray(node)) { for (const v of node) collect(v, out); return; }
      if (node && typeof node === "object") {
        for (const k of Object.keys(node)) {
          if (k === "branch" && typeof node[k] === "string") out.push(node[k]);
          else collect(node[k], out);
        }
      }
    };
    const bad = [];
    let n = 0;
    for (const row of Object.values(LANES)) {
      const doc = parse(readFileSync(root + "/.github/workflows/" + row.reusable, "utf8"));
      const got = [];
      collect(doc, got);
      if (got.length !== 1) { bad.push(row.reusable + ": branch 값 " + got.length + "개(정확히 1 기대)"); continue; }
      const want = fillLanePattern(row.branchPattern, { key: "${{ " + KEY_EXPR[row.action] + " }}", runId: "${{ github.run_id }}" });
      const normed = got[0].replace(/\s+/g, " ").trim();
      if (normed !== want) { bad.push(row.reusable + ": " + normed + " != " + want); continue; }
      n++;
    }
    if (n !== 5 || bad.length) { console.error(bad.join("\n") || ("레인 수 " + n + " != 5")); process.exit(1); }
    console.log("ok:" + n);
  ' "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:5$"
}

@test "dispatcher workflow_dispatch inputs equal the lane row inputs plus correlation" {
  # 레인 신원 parity 축 2: 디스패치 입력 이름의 양끝(행 ↔ 디스패처 YAML) 집합 동치.
  # 경로는 $ROOT 절대(venue 비의존). 5는 레인 수 손 앵커.
  run bun -e '
    const root = process.argv[1];
    const { parse } = require("yaml");
    const { readFileSync } = require("node:fs");
    const { LANES } = await import(root + "/tools/lib/catalog-rows.ts");
    const bad = [];
    let n = 0;
    for (const row of Object.values(LANES)) {
      const doc = parse(readFileSync(root + "/.github/workflows/" + row.workflow, "utf8"));
      const on = doc?.on ?? doc?.[true]; // YAML 1.1 on→true 키 함정 방어
      const got = Object.keys(on?.workflow_dispatch?.inputs ?? {}).sort();
      const want = [...row.inputs, "correlation"].sort();
      if (JSON.stringify(got) !== JSON.stringify(want)) bad.push(row.workflow + ": " + JSON.stringify(got) + " != " + JSON.stringify(want));
      n++;
    }
    if (n !== 5 || bad.length) { console.error(bad.join("\n") || ("레인 수 " + n + " != 5")); process.exit(1); }
    console.log("ok:" + n);
  ' "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:5$"
}

@test "lane row inputs match validate-mutation CONTRACT: pass-through equality and the spec layer pin" {
  # 레인 신원 parity 축 3(Q7 참조·대조 — validate-mutation은 무변경 서버 끝 선언으로 남는다).
  # 패스스루 레인은 행 inputs == required. 조립 레인(create-database/create-cache)은 디스패처가
  # 입력을 spec으로 조립하므로 검증기는 조립 후 계층을 본다(설계 게이트 r1 아티팩트의 검증 노트가
  # 수용한 계층 구분 — design.md 본문이 아니라 design-r1.json notes가 출처인 구현 결정이다).
  # 그 경계의 양쪽을 각각 핀한다: ① required == ["spec"], ② validateSpec 허용 필드 리터럴 핀
  # (db) / 행 inputs 동치(cache), ③ 행 inputs 전부를 디스패처 조립이 실제로 소비.
  # CONTRACT/OPTIONAL 키는 전량 리터럴 핀 — 개수 핀만으로는 회귀 앵커 행 개명이 통과한다.
  run bun -e '
    const root = process.argv[1];
    const { readFileSync } = require("node:fs");
    const { LANES } = await import(root + "/tools/lib/catalog-rows.ts");
    const src = readFileSync(root + "/tools/validate-mutation.ts", "utf8");
    const block = (name) => {
      const i = src.indexOf("const " + name);
      const j = src.indexOf("};", i);
      if (i < 0 || j < 0) { console.error(name + " 블록 없음"); process.exit(1); }
      return src.slice(i, j);
    };
    const rows = (text) => {
      const out = {};
      for (const m of text.matchAll(/^\s*"?([a-z-]+)"?:\s*\[([^\]]*)\]/gm)) {
        out[m[1]] = m[2].split(",").map((s) => s.trim().replace(/^"|"$/g, "")).filter((s) => s !== "");
      }
      return out;
    };
    const contract = rows(block("CONTRACT"));
    const optional = rows(block("OPTIONAL"));
    const wantContractKeys = ["activate-app", "audit", "create-app", "create-cache", "create-database", "teardown-app", "teardown-resource", "update-secrets"];
    const wantOptionalKeys = ["create-app", "create-cache", "create-database", "teardown-app", "update-secrets"];
    if (JSON.stringify(Object.keys(contract).sort()) !== JSON.stringify(wantContractKeys)) { console.error("CONTRACT 키 전량 핀 어긋남: " + Object.keys(contract).sort().join(",")); process.exit(1); }
    if (JSON.stringify(Object.keys(optional).sort()) !== JSON.stringify(wantOptionalKeys)) { console.error("OPTIONAL 키 전량 핀 어긋남: " + Object.keys(optional).sort().join(",")); process.exit(1); }
    const am = src.match(/const allowed = action === "create-database" \? \[([^\]]*)\] : \[([^\]]*)\]/);
    if (!am) { console.error("validateSpec allowed 추출 실패"); process.exit(1); }
    const list = (s) => s.split(",").map((x) => x.trim().replace(/^"|"$/g, "")).filter((x) => x !== "");
    if (JSON.stringify(list(am[1])) !== JSON.stringify(["name", "owner", "extensions"])) { console.error("db spec 허용 필드 핀 어긋남: " + am[1]); process.exit(1); }
    if (JSON.stringify(list(am[2]).sort()) !== JSON.stringify([...LANES["create-cache"].inputs].sort())) { console.error("cache spec 허용 필드가 행 inputs와 다르다: " + am[2]); process.exit(1); }
    const bad = [];
    let n = 0;
    for (const row of Object.values(LANES)) {
      if ((optional[row.action] ?? []).join(",") !== "correlation") bad.push(row.action + ": OPTIONAL != [correlation]");
      const required = contract[row.action] ?? [];
      if (row.action === "create-database" || row.action === "create-cache") {
        if (JSON.stringify(required) !== JSON.stringify(["spec"])) bad.push(row.action + ": spec 계층 핀 어긋남 — " + JSON.stringify(required));
        const wf = readFileSync(root + "/.github/workflows/" + row.workflow, "utf8");
        for (const i of row.inputs) if (wf.indexOf("inputs." + i) < 0) bad.push(row.workflow + ": 조립이 inputs." + i + "를 소비하지 않는다");
      } else if (JSON.stringify([...required].sort()) !== JSON.stringify([...row.inputs].sort())) {
        bad.push(row.action + ": " + JSON.stringify(required) + " != " + JSON.stringify(row.inputs));
      }
      n++;
    }
    if (n !== 5 || bad.length) { console.error(bad.join("\n") || ("레인 수 " + n + " != 5")); process.exit(1); }
    console.log("ok:" + n);
  ' "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:5$"
}

@test "each dispatcher declares an optional correlation input echoed into run-name (web-UI compat by definition)" {
  # 하위호환의 정의상 증명: required 아님 + 기본값 빈 문자열 + run-name은 빈값에서 바이트 동일(조건부 에코).
  run bun -e '
    const y = require("yaml"), fs = require("fs");
    const wf = process.argv[1];
    const dispatchers = process.argv.slice(2);
    if (dispatchers.length < 5) { console.error("dispatcher 열거 붕괴: " + dispatchers.length); process.exit(1); }
    const bad = [];
    for (const d of dispatchers) {
      const src = fs.readFileSync(wf + "/" + d + ".yaml", "utf8");
      const doc = y.parse(src);
      const on = doc?.on ?? doc?.[true];   // 일부 YAML 파서의 on→true 키 함정 방어
      const inp = on?.workflow_dispatch?.inputs?.correlation;
      if (!inp) { bad.push(d + ": correlation 입력 부재"); continue; }
      if (inp.required === true) bad.push(d + ": correlation이 required — 웹 UI 하위호환 위반");
      if (inp.default !== "") bad.push(d + ": correlation 기본값이 빈 문자열이 아니다");
      const rn = String(doc["run-name"] ?? "");
      if (!rn.includes("inputs.correlation != '\''") || !rn.includes("format(")) bad.push(d + ": run-name이 correlation을 조건부 에코하지 않는다");
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$WF" $DISPATCHERS
  [ "$status" -eq 0 ]
}

@test "the actor predicate copies are counted (a deleted or flipped copy is red)" {
  # 아래 로스터 판정은 술어의 **텍스트 존재**만 본다 — 그래서 `=`를 `!=`로 뒤집어도 초록이었다
  # (2026-08 실측). 이 등식이 그 우회의 절반을 닫는다: 사본이 사라지거나 비교가 뒤집히면 수가 어긋난다.
  # 나머지 절반은 아래 **실행 증인**이 닫는다 — 개수만으로는 "뒤집고 하나 더 추가"를 못 잡는다.
  # 수치는 콜사이트가 소유한다(CONTEXT.md 「열거 바닥값」) — 도메인이 줄지 않는 한 손대지 않는다.
  pred="$(grep -rhoF '[ "$ACTOR" = "$OWNER" ] ||' "$WF"/*.yaml | wc -l | tr -d ' ')"
  [ "$pred" -ge 15 ]
  # 빈 owner fail-closed(vacuous 방지)는 술어와 **같은 수**로 존재해야 한다 — 한쪽만 남으면
  # 변수 미설정이 곧 통과가 된다.
  # 빈 owner fail-closed는 **모든** 가드 스텝에 있어야 한다(dispatch 가드 + replay 전용 가드).
  empty="$(grep -rhoF '[ -n "$OWNER" ] ||' "$WF"/*.yaml | wc -l | tr -d ' ')"
  [ "$empty" -ge 15 ]
  # 정본 본문은 축이 셋이고 **셋 다 같은 수**여야 한다. 하나만 빠져도 그 축이 조용히 다시 열린다.
  #   ① 재실행 축   — 이벤트를 보지 않는다(github.run_attempt).
  #   ② 트리거 축   — 종전 `if:` 한정을 본문으로 옮긴 것. `if:`로 두면 재실행에서 스텝이 skip된다.
  #   ③ dispatch 축 — actor와 개시자 둘 다 owner여야 한다(actor는 재실행에서 보존된다).
  replay="$(grep -rhoF '[ "$ATTEMPT" = "1" ] ||' "$WF"/*.yaml | wc -l | tr -d ' ')"
  gate="$(grep -rhoF '[ "$EVENT" = "workflow_dispatch" ] || exit 0' "$WF"/*.yaml | wc -l | tr -d ' ')"
  init="$(grep -rhoF '재실행 개시자=$TRIGGERING 거부' "$WF"/*.yaml | wc -l | tr -d ' ')"
  [ "$replay" -ge 15 ]
  # 재실행 절은 dispatch 가드 15 + 이벤트 구동 잡의 replay 전용 가드에 붙는다. 등식으로 못을 박아야
  # 한쪽에서 사라진 것이 다른 쪽 증가로 가려지지 않는다.
  evt="$(grep -rhoF 'replay 가드 (이벤트 구동 잡' "$WF"/*.yaml | wc -l | tr -d ' ')"
  [ "$evt" -ge 2 ]
  [ "$replay" -eq "$((pred + evt))" ]
  [ "$empty" -eq "$replay" ]
  [ "$pred" -eq "$gate" ]
  [ "$pred" -eq "$init" ]
  # 가드 스텝에 `if:`가 남아 있으면 안 된다 — 그것이 재실행 축을 무력화하는 정확한 형태다.
  [ "$(grep -rhcF "if: github.event_name == 'workflow_dispatch'" "$WF"/*.yaml | paste -sd+ - | bc)" -eq 0 ]
  # env 바인딩도 같은 수 — 술어만 있고 바인딩이 없으면 빈 문자열 비교로 **전 디스패치가 잠긴다**.
  # ATTEMPT/TRIGGERING은 **모든** 가드 스텝이 바인딩한다 — replay 총계와 등식이어야 한다.
  # (`-ge pred`로 두면 replay 전용 가드 2건이 여유가 되어 dispatch 가드 하나의 누락을 가린다.)
  for k in 'ATTEMPT: ${{ github.run_attempt }}' 'TRIGGERING: ${{ github.triggering_actor }}'; do
    b="$(grep -rhoF "$k" "$WF"/*.yaml | wc -l | tr -d ' ')"
    [ "$b" -eq "$replay" ]
  done
  # EVENT는 트리거 축을 가진 dispatch 가드만 바인딩한다.
  [ "$(grep -rhoF 'EVENT: ${{ github.event_name }}' "$WF"/*.yaml | wc -l | tr -d ' ')" -ge "$pred" ]
}

@test "every actor guard predicate actually executes and decides correctly (the predicate gets a witness)" {
  # 이 술어는 지금까지 **한 번도 실행된 적이 없었다** — 로스터는 텍스트만 봤고, 그래서 `=`를
  # `!=`로 뒤집어도 게이트가 초록이었다(2026-08 실측). owner 전용 변이 경계의 술어가 무증인이었다.
  # ⚠️ **생산 텍스트를 생산과 같은 셸 모드로 돌린다** — 렌더한 사본이 아니다. GHA의 기본 셸은
  #    `bash -e {0}`라 pipefail이 없다(함정 원장) → `bash -e`가 충실한 모드다.
  run bash -c '
    set -euo pipefail
    root="$1"; n=0; bad=""
    for f in "$root"/.github/workflows/*.yaml; do
      cnt="$(yq -r "[.jobs[]?.steps[]? | select((.run // \"\") | contains(\"ATTEMPT\"))] | length" "$f" 2>/dev/null || echo 0)"
      [ "${cnt:-0}" -gt 0 ] || continue
      i=0
      while [ "$i" -lt "$cnt" ]; do
        body="$(yq -r "[.jobs[]?.steps[]? | select((.run // \"\") | contains(\"ATTEMPT\"))][$i].run" "$f")"
        n=$((n+1)); w="$(basename "$f")#$i"
        # ── 재실행 축 (17사본 **공통**) — 이벤트를 보지 않는다 ──
        # `if:`로 dispatch에 한정한 가드는 push/schedule run의 재실행에서 **스텝 자체가 skip**되므로
        # (skip은 실패가 아니다) 아래 dispatch 축 케이스가 닿지 못한다. github.run_attempt은 재실행이
        # 보존할 수 없는 유일한 값이고, attempt>=2의 개시자는 언제나 actions:write를 든 주체다 —
        # 그래서 이 축에는 열거할 트리거가 없다.
        EVENT="workflow_dispatch" ATTEMPT="1" OWNER="" ACTOR="x" TRIGGERING="x" \
          bash -e -c "$body" >/dev/null 2>&1 && bad="$bad $w:empty-owner-passed"
        EVENT="schedule" ATTEMPT="2" OWNER="alice" ACTOR="alice" TRIGGERING="mallory" \
          bash -e -c "$body" >/dev/null 2>&1 && bad="$bad $w:replay-passed"
        # 대조군 — 최초 실행(attempt=1)의 비-dispatch 트리거는 무영향이어야 한다(종전 의미론 보존).
        EVENT="schedule" ATTEMPT="1" OWNER="alice" ACTOR="anyone" TRIGGERING="anyone" \
          bash -e -c "$body" >/dev/null 2>&1 || bad="$bad $w:first-schedule-rejected"
        # ── dispatch 축 — actor 가드를 가진 사본에만 적용한다(이벤트 구동 잡의 replay 전용 가드는 비대상) ──
        # GitHub은 재실행에서 github.actor를 **최초 트리거 신원으로 보존**하고 triggering_actor만
        # 개시자로 바꾼다 — actor만 보는 가드는 owner의 과거 디스패치 재실행으로 통과한다.
        case "$body" in *ACTOR*)
          EVENT="workflow_dispatch" ATTEMPT="1" OWNER="alice" ACTOR="mallory" TRIGGERING="mallory" \
            bash -e -c "$body" >/dev/null 2>&1 && bad="$bad $w:mismatch-passed"
          EVENT="workflow_dispatch" ATTEMPT="1" OWNER="alice" ACTOR="alice" TRIGGERING="mallory" \
            bash -e -c "$body" >/dev/null 2>&1 && bad="$bad $w:rerun-passed"
          EVENT="workflow_dispatch" ATTEMPT="1" OWNER="alice" ACTOR="alice" TRIGGERING="alice" \
            bash -e -c "$body" >/dev/null 2>&1 || bad="$bad $w:match-rejected"
        esac
        i=$((i+1))
      done
    done
    # 열거 바닥값 — 추출이 붕괴하면 0사본을 돌리고도 초록이 된다. 수치는 콜사이트 소유.
    [ "$n" -ge 17 ] || { echo "ROSTER-COLLAPSE n=$n"; exit 1; }
    [ -z "$bad" ] || { echo "PREDICATE-WRONG:$bad"; exit 1; }
    echo "EXECUTED=$n"
  ' _ "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'EXECUTED='
}

@test "no run step inline-interpolates untrusted inputs (repo-wide, not just DISPATCHERS)" {
  # traps-a-1(5라운드) — 원 가드(위 @test 「no run inline interpolation」)는 피연산자가
  # DISPATCHERS 5파일뿐이라 셸이 실제로 도는 _*.yaml과 cross-repo 계약 reusable-app-build.yaml이
  # 도메인 밖이었다(원장 36행 「GHA client_payload 비신뢰 입력」의 env-경유 규약 회귀 검출).
  # yq 비사용(tests/gates/test_workflow-pipefail.bats:7 규약과 동형) — bun+yaml 파서로 전 워크플로를 훑는다.
  run bun -e '
    const y = require("yaml"), fs = require("fs");
    const dir = process.argv[1] + "/.github/workflows";
    const NEEDLE = /\$\{\{[^}]*(inputs\.|github\.event\.|client_payload)/;
    const bad = []; let seen = 0;
    for (const f of fs.readdirSync(dir)) {
      if (!/\.ya?ml$/.test(f)) continue;
      const doc = y.parse(fs.readFileSync(dir + "/" + f, "utf8"));
      for (const [jn, job] of Object.entries(doc?.jobs ?? {})) {
        (job?.steps ?? []).forEach((st, i) => {
          if (typeof st?.run !== "string") return;
          if (st.run.includes("${{")) seen++;
          if (NEEDLE.test(st.run)) bad.push(f + " jobs." + jn + ".steps[" + i + "]: run 인라인 보간");
        });
      }
    }
    // 양성 대조 — `${{`를 담은 run 스텝 자체가 0이면 needle이 죽어도 초록이라 위 루프가 무의미.
    if (seen === 0) { console.error("NO-POSITIVE-CONTROL: run 스텝에 ${{ 0건"); process.exit(1); }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$ROOT"
  [ "$status" -eq 0 ]
}
