#!/usr/bin/env bats
# 열거 붕괴 커널(scripts/lib/scan-floor.sh)의 gate 테스트.
#
# 병: `done < <(enumerator)` **프로세스 치환은 열거자 실패를 `set -euo pipefail`로 전파하지 않는다.**
# 워커가 죽으면 소비자가 0건을 검사하고 성공 메시지를 낸다 — 라이브 재현됨(실패하는 bun 셰임으로
# check-app-netpol·check-app-deploy가 "OK … 위반 0" + rc=0).
#
# 이건 **skip이 아니다**: 도메인이 없는 게 아니라 열거를 못 한 것이다. 01의 exit 4/`SKIP:` 마커를
# 쓰면 "정당하게 대상이 없음"으로 읽혀 정반대 뜻이 된다 — 여기선 검증 실패(비-0)다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$ROOT/scripts/lib/scan-floor.sh"
}

@test "scan_enumerate returns the enumerator output when it succeeds" {
  run bash -c '. "$1"; scan_enumerate demo printf "a\nb\nc\n"' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "a
b
c" ]
}

# 핵심 — 프로세스 치환이 삼키던 바로 그 실패를 잡는다.
@test "scan_enumerate fails loudly when the enumerator dies (the substitution swallowed this)" {
  run bash -c '. "$1"; scan_enumerate demo sh -c "exit 3"' _ "$LIB"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "열거 실패"
}

@test "scan_enumerate does not treat a legitimately empty enumeration as failure" {
  # 0건 자체는 커널이 판정하지 않는다 — 그건 도메인 지식이라 소비자(scan_floor)가 정한다.
  run bash -c '. "$1"; scan_enumerate demo true; echo "rc=$?"' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "rc=0"
}

@test "scan_floor passes at or above the floor" {
  run bash -c '. "$1"; scan_floor demo 10 10' _ "$LIB"
  [ "$status" -eq 0 ]
}

@test "scan_floor fails below the floor and names both numbers" {
  run bash -c '. "$1"; scan_floor demo 0 10' _ "$LIB"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "0건"
  echo "$output" | grep -q "10"
  echo "$output" | grep -q "열거 붕괴"
}

# 이 커널은 skip 규약과 **다른 채널**이다. 마커를 내면 01의 정적 가드가 짝(exit 4)을 요구하고,
# 더 나쁘게는 사람이 "정당하게 대상이 없음"으로 읽는다.
@test "the collapse signal is not the skip convention (no SKIP marker, not exit 4)" {
  run bash -c '. "$1"; scan_floor demo 0 10' _ "$LIB"
  [ "$status" -ne 0 ]
  [ "$status" -ne 4 ]
  out="$output"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

# ── SCAN 신호(08-a) — 실행 관측용 균일 마커 ────────────────────────────────────
# 가드가 CI에서 **돈다는 사실**과 그 호출이 **실제 도메인에 닿았다는 사실**은 다른데 텍스트로는
# 갈리지 않는다(실측 반례: 루트 인자가 실 레포를 가리키거나, 한 파일에 픽스처/실 트리 호출이 섞임).
# 이 마커가 그 판정의 유일한 기계 입력이다 — CONTRIBUTING '가드 스캔 신호'.

@test "scan_signal emits the marker in the agreed shape" {
  run bash -c '. "$1"; scan_signal demo 42' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "SCAN: demo: 42" ]
}

@test "scan_floor emits the scan marker when it passes" {
  run bash -c '. "$1"; scan_floor demo 10 5' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "SCAN: demo: 10" ]
}

# 붕괴한 실행의 건수는 "검사했다"가 아니라 "붕괴했다"는 뜻이다 — 같은 마커로 내면 정반대로 읽힌다.
@test "scan_floor does NOT emit the scan marker when it fails" {
  run bash -c '. "$1"; scan_floor demo 0 5' _ "$LIB"
  [ "$status" -ne 0 ]
  out="$output"
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
}

# 두 마커는 배타적이다 — 한 실행이 둘을 같이 내면 소비자가 모순된 사실을 받는다.
@test "the scan marker never carries the skip marker (exclusive channels)" {
  run bash -c '. "$1"; scan_floor demo 10 5' _ "$LIB"
  [ "$status" -eq 0 ]
  out="$output"
  # ⚠️ 마커 존재를 먼저 단언한다 — 이게 없으면 "SKIP이 없다"는 마커가 **아예 없어도** 참이라
  # 이 테스트가 자기 자신 vacuous가 된다(적대 검토 지목).
  run grep -q "^SCAN: demo: 10$" <<<"$out"
  [ "$status" -eq 0 ]
  run grep -q "SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

# ── take_floors — --floor 어휘의 셸 adapter(kernel-followups 01, TS takeFloors 동형) ───────────
# 허용 라벨을 **선언 선행**으로 받는다 — TS는 guardMain ⓪가 파싱 뒤 전건 매칭을 검증하지만
# 셸엔 실행 커널이 없어, 파싱 시점 검증(잊을 수 없는 자리)이 등가물이다.

@test "take_floors strips --floor pairs and leaves the rest of argv intact" {
  run bash -c '. "$1"; take_floors "check-x:aa check-x:bb check-x:cc" --floor aa=3 --keep v --floor check-x:bb=7
    printf "%s\n" "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
    floor_of check-x:aa 99; floor_of check-x:bb 99; floor_of check-x:aa 42; floor_of check-x:cc 42' _ "$LIB"
  [ "$status" -eq 0 ]
  # 잔여 argv는 내용과 **순서**가 보존된다(개별 존재만 보면 순서 뒤집기 뮤테이션이 통과한다).
  echo "$output" | grep -A1 '^--keep$' | grep -q '^v$'
  out="$output"
  run grep -q '^7$' <<<"$out"
  [ "$status" -eq 0 ]
  run grep -c '^3$' <<<"$out"
  [ "$output" = "2" ]   # 접미사 키(aa)가 전체 라벨로 정규화돼 두 조회가 같은 값을 본다
  # 미오버라이드 도메인은 콜사이트 기본값으로 떨어진다(TS floorOf의 dflt 축과 동형).
  run grep -q '^42$' <<<"$out"
  [ "$status" -eq 0 ]
}

@test "take_floors keeps working when --floor is the only argv (empty rest under set -u)" {
  # bash 3.2~4.3의 빈 배열 확장 함정 — 콜사이트 관용구 `"${REST_ARGV[@]+"${REST_ARGV[@]}"}"`가
  # set -u에서 사는지 커널 계약으로 못박는다.
  run bash -c 'set -u; . "$1"; take_floors "check-x" --floor check-x=5
    set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
    echo "argc=$#"; floor_of check-x 99' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^argc=0$'
  echo "$output" | grep -q '^5$'
}

@test "floor_set distinguishes an explicit floor from the default (fixture-only semantics)" {
  # check-image-pins의 MIN_SCAN_APPS_SET 의미론("명시하면 픽스처에서도 적용")이 커널로 접힌다.
  run bash -c '. "$1"; take_floors "check-x:aa check-x:bb" --floor aa=0
    floor_set check-x:aa && echo "aa=set"; floor_set check-x:bb || echo "bb=default"' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^aa=set$'
  echo "$output" | grep -q '^bb=default$'
}

@test "an unmatched --floor domain key is a usage error, not a silently disabled floor" {
  run bash -c '. "$1"; take_floors "check-x:aa" --floor bogus=9' _ "$LIB"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "bogus"
  echo "$output" | grep -q "조용히 꺼진 바닥값"
}

@test "a --floor key matching two domains is rejected as ambiguous" {
  run bash -c '. "$1"; take_floors "check-x:dup check-y:dup" --floor dup=5' _ "$LIB"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "전체 라벨로 지정하라"
  run bash -c '. "$1"; take_floors "check-x:dup check-y:dup" --floor check-x:dup=5; floor_of check-x:dup 99' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^5$'
}

@test "a malformed --floor value fails loud (empty, non-numeric, missing operand)" {
  # 값 오류와 형식 오류는 문구가 다른 사고다 — 하나로 뭉개는 뮤테이션이 rc 단언만으로는 통과한다.
  for spec in "caps=" "caps=abc" "caps=-1"; do
    run bash -c '. "$1"; take_floors "check-x:caps" --floor "$2"' _ "$LIB" "$spec"
    [ "$status" -eq 2 ]
    echo "spec=$spec: $output" | grep -q "음이 아닌 정수"
  done
  for spec in "abc" ""; do
    run bash -c '. "$1"; take_floors "check-x:caps" --floor "$2"' _ "$LIB" "$spec"
    [ "$status" -eq 2 ]
    echo "spec=$spec: $output" | grep -q -- "--floor 형식은"
  done
  run bash -c '. "$1"; take_floors "check-x:caps" --floor' _ "$LIB"
  [ "$status" -eq 2 ]
}

@test "a repeated --floor key resolves last-wins, across suffix and full-label spellings" {
  # TS Map.set 동형 — 접미사 키도 전체 라벨로 정규화해 저장하므로 혼용 반복도 마지막 값이 이긴다.
  run bash -c '. "$1"; take_floors "check-x:aa" --floor aa=3 --floor check-x:aa=9 --floor aa=5
    floor_of check-x:aa 99' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^5$'
}

@test "an empty allowed-label declaration is a usage error (TS empty-domains parity)" {
  run bash -c '. "$1"; take_floors "" --root x' _ "$LIB"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "허용 라벨이 비었다"
}

@test "a colon-free label coexisting with suffixed labels does not self-collide (mixed declaration)" {
  # 콜론 없는 라벨은 자기 접미사가 자기 자신이다 — 전체·접미사 두 조건이 한 if의 ||로 묶여
  # hits가 1회만 증가해야 모호 오발화가 없다(check-image-pins류 혼합 선언의 하중 부품).
  run bash -c '. "$1"; take_floors "check-y check-y:apps" --floor check-y=4 --floor apps=6
    floor_of check-y 99; floor_of check-y:apps 99' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^4$'
  echo "$output" | grep -q '^6$'
}

@test "a leading-zero floor value is decimal, never octal (the low-floor direction is blocked)" {
  run bash -c '. "$1"; take_floors "check-x" --floor check-x=010; floor_of check-x 99' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^10$'
}

@test "an IFS override at the callsite cannot silently disable the floor matching" {
  # 리뷰 실측 — IFS에 콜론이 들어가면 선언 순회가 무너져 정상 키가 조용히 기본값으로 떨어졌다
  # (fail-open). 커널이 순회 구간에서 IFS·글롭을 고정한다.
  run bash -c '. "$1"; IFS=$'"'"' \t\n:'"'"'; take_floors "check-x:aa" --floor aa=3; floor_of check-x:aa 99' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^3$'
}

@test "floor_of without a prior take_floors resolves to the default (no raw unbound diagnostics)" {
  # source 시점 초기화 — 커맨드 치환 안에서 서브셸만 죽어 빈 문자열 + rc 0이 되던 갈래가
  # "항상 기본값"이라는 하나의 의미로 수렴한다(그때 argv의 --floor는 콜사이트 argv 루프 소관).
  run bash -c 'set -u; . "$1"; echo "min=$(floor_of check-x 7)"; floor_set check-x || echo "not-set"' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^min=7$'
  echo "$output" | grep -q '^not-set$'
}

@test "the take_floors declared labels are a subset of the emitted scan labels (typo goes red)" {
  # 선언은 콜사이트 손 문자열이라 TS(선언 = 마커 리터럴)만큼 강하지 않다 — 선언 오타는 조용히
  # 꺼진 바닥값이 된다(리뷰 실측). 이 정적 대조가 그 등가물이다: 선언 라벨은 반드시 어딘가의
  # scan_floor/scan_signal 콜사이트 라벨이어야 한다.
  static="$(grep -hE '^[^#]*\b(scan_floor|scan_signal) ' "$ROOT"/scripts/*.sh \
            | grep -oE '(scan_floor|scan_signal) [a-z0-9:-]+' | awk '{print $2}' | LC_ALL=C sort -u)"
  declared="$(grep -hE '^[^#]*\btake_floors "' "$ROOT"/scripts/*.sh \
              | grep -oE 'take_floors "[a-z0-9: -]+"' | sed 's/^take_floors "//; s/"$//' \
              | tr ' ' '\n' | grep . | LC_ALL=C sort -u)"
  # 양성 대조 — 선언이 하나도 파생되지 않으면 아래 루프가 vacuous다(01 시점 실측: 소비자 1가드 2라벨).
  [ -n "$declared" ]
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    printf '%s\n' "$static" | grep -qxF "$d" || {
      echo "take_floors 선언 라벨 '$d'가 방출 라벨 집합에 없다 — 선언 오타는 조용히 꺼진 바닥값이 된다"; false; }
  done <<<"$declared"
}

# 커버리지 증인 — **정적 콜사이트 라벨 집합 == 런타임 방출 라벨 집합**.
# ⚠️ 앞선 판(가드당 마커 ≥1인지만 보는 하드코딩 목록)은 세 가지를 통과시켰다(적대 검토 실측):
#    라벨 하나 삭제(가드는 다른 라벨로 여전히 ≥1) · 픽스처 콜사이트 삭제(기본 모드만 돌았다) ·
#    9번째 커널 가드 추가(목록이 하드코딩이라 모른다). 집합 대조는 셋 다 잡는다.
# 라벨을 하나 추가/삭제하면 정적 쪽이 먼저 바뀌고 런타임이 따라오지 않으면 red다 — 목록을 손으로
# 관리하지 않으므로 래칫이 아니다.
@test "the emitted scan labels exactly match the kernel call sites (no hardcoded roster)" {
  # 정적: 커널 호출의 첫 인자(주석 줄 제외 — 설명 문장의 라벨이 섞이면 대조가 무의미해진다)
  static="$(grep -hE '^[^#]*\b(scan_floor|scan_signal) ' "$ROOT"/scripts/*.sh \
            | grep -oE '(scan_floor|scan_signal) [a-z0-9:-]+' | awk '{print $2}' | LC_ALL=C sort -u)"
  # ⚠️ 집합 대조만으로는 **양쪽이 같이 사라지는** 삭제를 못 잡는다(콜사이트를 지우면 정적·런타임이
  # 함께 줄어 등식이 유지된다 — 적대 검토가 실측). 라벨 수 바닥값이 그 구멍을 막는다.
  # ⚠️ 이 바닥값은 **여유가 없다**(오늘 로스터와 같은 값). 도메인 바닥값은 도메인이 정당하게 줄 수
  #    있어 여유를 두지만, 라벨이 사라지는 것은 드리프트가 아니라 언제나 **의도적 커버리지 변경**이고
  #    그때는 CONTRIBUTING·PROGRESS의 커버리지 수치도 같이 고쳐야 하므로 diff에 보여야 한다.
  # ⚠️ 그래서 이 상수는 **로스터가 늘 때 같이 올려야 한다**. 29로 굳어 있던 동안 실측은 38이었고
  #    (2026-09-03 재측정), 그 9칸의 여유가 바로 이 바닥값이 없애려던 것이다 — 뮤테이션 실측: 단일
  #    라벨 가드 8개의 콜사이트를 죽여 38→30으로 떨어뜨려도 이 @test는 초록이었다(집합 대조는 정적·
  #    런타임이 **함께** 줄어 등식이 유지되므로 원리적으로 못 본다). 값은 실측이지 래칫이 아니다:
  #    가드당 라벨 수 = check-{skeleton,image-pins,gh-secret-coverage,doc-index,bats-accounting} 3 ·
  #    verify-{traps,credential-inventory}·sealed-guard·check-{argocd-revision,app-netpol} 2 · 나머지 13개 1.
  # 라벨 수 바닥값은 **전체** 정적 집합에서 센다 — SKIP과 무관하게 "라벨이 사라졌는가"를 보는 축이다.
  labels=$(printf '%s\n' "$static" | grep -c . || true)
  [ "$labels" -ge 38 ]
  guards="$(grep -lE '^[^#]*\b(scan_floor|scan_signal) ' "$ROOT"/scripts/*.sh)"
  [ -n "$guards" ]
  # ⚠️ **SKIP(exit 4)은 실패가 아니다 — 그리고 대조에서 양쪽 대칭으로 빠져야 한다.**
  #    `verify-credential-inventory.sh`는 런북이 gitignored라 CI에서 원리적으로 SKIP한다(rc=4,
  #    SCAN 라벨 0개). 예전 판은 그 rc를 "비-0으로 죽었다"로 읽어 **로컬은 초록·CI만 red**였다
  #    (실측 2026-08-24: 로컬 make ci rc=0인데 PR gate FAILURE — venue가 갈리는 형태라
  #    로컬 초록이 CI를 예고하지 못했다). SKIP을 인정하되 그 가드의 라벨을 **정적 쪽에서도** 빼야
  #    등식이 성립한다 — 한쪽만 빼면 반대 방향으로 red다.
  cmp_static=""; runtime=""; skipped=""; nskip=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    lbl="$(grep -hE '^[^#]*\b(scan_floor|scan_signal) ' "$f" \
           | grep -oE '(scan_floor|scan_signal) [a-z0-9:-]+' | awk '{print $2}')"
    # ⚠️ `out="$(...)"; rc=$?`로 쓰면 안 된다 — bats는 set -e 아래라 **할당이 비-0이면 그 줄에서
    #    죽어** 다음 줄의 rc 판정에 도달하지 못한다(이 레포에 반복되는 클래스: 형제 가드들이
    #    `|| arc=$?`를 쓰는 이유가 그것이다). `||`가 붙어야 set -e가 발동하지 않는다.
    rc=0
    out="$(bash "$f" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 4 ]; then skipped="${skipped} ${f##*/}"; nskip=$(( nskip + 1 )); continue; fi
    # rc 1은 "위반을 찾았다"다 — 도메인은 평가됐고 마커는 이미 방출됐다(라이브 감사 가드가 실
    # 고아를 보고하는 venue에서 이 등식이 red가 되면 게이트가 감사 결과에 오염된다). 사망은 그 외.
    [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || { echo "가드가 비-0으로 죽었다: $f (rc=$rc)"; false; }
    cmp_static="${cmp_static}${lbl}
"
    runtime="${runtime}$(printf '%s\n' "$out" | sed -n 's/^SCAN: \(.*\): [0-9][0-9]*$/\1/p')
"
  done <<EOF
$guards
EOF
  # ⚠️ SKIP 상한이 없으면 "전부 SKIP → 양쪽 공집합 → 등식 성립"이라는 vacuous green이 열린다.
  #    SKIP은 venue에 따라 달라지므로(로컬 1: audit-orphan-pv · CI 2: +verify-credential-inventory)
#    바닥값이 아니라 **상한**으로 문다.
  echo "skipped(${nskip}):${skipped}"
  [ "$nskip" -le 2 ]
  cmp_static="$(printf '%s' "$cmp_static" | grep -v '^$' | LC_ALL=C sort -u)"
  runtime="$(printf '%s' "$runtime" | grep -v '^$' | LC_ALL=C sort -u)"
  [ "$cmp_static" = "$runtime" ] || { echo "정적:"; echo "$cmp_static"; echo "런타임:"; echo "$runtime"; false; }
}

# 콜사이트 증인 — 바닥값 면제(픽스처·인자) 모드와 바닥값 없는 카운트 자리도 **자기** 신호를 낸다.
# 위 집합 대조는 기본 모드만 돌리므로 이 네 자리를 못 본다. 신호가 없으면 06은 "픽스처 호출"과
# "가드 미실행"을 구별할 수 없다 — 08-a의 명시 산출물이 그 구별이다.
@test "floor-exempt call sites emit their own scan marker" {
  FX="$BATS_TEST_TMPDIR/cs"
  mkdir -p "$FX/apps/x/deploy/prod"
  printf 'kind: NetworkPolicy\n' > "$FX/apps/x/deploy/prod/np.yaml"
  git -C "$FX" init -q
  git -C "$FX" add -A
  bad=""
  bash "$ROOT/scripts/check-app-netpol.sh" --root "$FX" 2>/dev/null \
    | grep -qE '^SCAN: check-app-netpol:manifests: [0-9]+$' || bad="$bad app-netpol"
  bash "$ROOT/scripts/check-app-deploy.sh" "$FX/apps/x/deploy/prod" 2>/dev/null \
    | grep -qE '^SCAN: check-app-deploy: [0-9]+$' || bad="$bad app-deploy"
  bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_FILENAME" 2>/dev/null \
    | grep -qE '^SCAN: check-bats-style: [0-9]+$' || bad="$bad bats-style"
  bash "$ROOT/scripts/sops-guard.sh" "$ROOT/platform/cnpg/prod/ukkiee.enc.yaml" 2>/dev/null \
    | grep -qE '^SCAN: sops-guard: [0-9]+$' || bad="$bad sops-guard"
  bash "$ROOT/scripts/verify-secrets.sh" "$ROOT/platform/cnpg/prod/ukkiee.enc.yaml" 2>/dev/null \
    | grep -qE '^SCAN: verify-secrets: [0-9]+$' || bad="$bad verify-secrets"
  # ⚠️ 픽스처 레지스트리로 부른다 — 실 `.ci-exclude`를 인자로 주면 건수가 기본 모드와 같아져
  #    "이 호출이 실 도메인에 닿았는가"를 가르는 대비(아래 마지막 @test의 취지)가 사라진다.
  printf '%s\n' '# 사유 — 실행처: owner-local' 'tests/gates/test_scan-floor.bats' > "$FX/ci-exclude"
  bash "$ROOT/scripts/check-bats-accounting.sh" --lint-excludes "$FX/ci-exclude" 2>/dev/null \
    | grep -qE '^SCAN: check-bats-accounting:excludes: [0-9]+$' || bad="$bad bats-accounting"
  [ -z "$bad" ]   # 비어야 통과. 디버깅: echo "$bad"
}

# TS 가드도 같은 규약을 쓴다 — 두 번째 adapter(`tools/lib/scan-floor.ts`)가 마커를 낸다.
# ⚠️ **앞선 판은 하드코딩 로스터였고 이미 드리프트했다** — 3행(resource-limits·alert-rules·
#    guard-authority)만 적혀 있었는데 실제 방출 TS는 5종이었다(image-ownership·workflow-readiness가
#    누락). "하드코딩 소비처 목록은 자기 자신에게만 정확하다"(AGENTS.md 함정)의 살아있는 사례다.
#    ⇒ 셸 adapter와 **동형**으로 바꾼다: 정적 콜사이트 라벨 집합 == 런타임 방출 라벨 집합.
#
# ⚠️ 정적 축은 **커널 호출 형태만** 본다. 이행 중에는 옛 형태(콜사이트가 직접 `console.log`)도 함께
#    인식했었다 — 한쪽만 보면 옮긴 가드가 정적·런타임 집합에서 **동시에** 사라져 등식이 그대로 성립하기
#    때문이다(실측: check-disk-caps를 옮긴 직후 이 테스트가 통과했다). 이행이 끝나 옛 형태가 0이 된 지금,
#    그 인식은 거뒀다. 그런데 같은 이유로 **이 등식만으로는 커널 우회를 막지 못한다** — 되돌린 가드도
#    양쪽에서 함께 사라진다. 문을 닫는 것은 인식 제거가 아니라 **거부**다: 아래 "거부 가드" 절의
#    `scripts/check-scan-producers.sh`가 "직접 생산자가 있으면 red"를 강제한다(설계 §5 · 게이트 r1 F1).
SCAN_NEW_RE='^[^/]*scan(Floor|Signal)\('

@test "the TypeScript guards emit the same marker shape (derived roster, not hardcoded)" {
  # 정적: 두 형태의 합집합 — ① 커널 콜사이트 `scanFloor("<라벨>"` · `scanSignal("<라벨>"`,
  # ② 실행 커널(guardMain) 도메인 선언의 `scan: "<라벨>"` 리터럴(17 재접목 — 커널이 마커를
  # 방출하는 가드는 소스에 콜사이트 형태가 없으므로 ②가 없으면 그 가드를 정적 쪽에서 잃는다).
  # 라벨은 도메인 단위라 접미사가 붙을 수 있다 — 두 형태 모두.
  static="$({ grep -hE "$SCAN_NEW_RE" "$ROOT"/tools/*.ts \
              | grep -oE 'scan(Floor|Signal)\("[a-z0-9:-]+"' | sed 's/^[^"]*"//; s/"$//'; \
              grep -hE '^[^/]*scan: "' "$ROOT"/tools/*.ts \
              | grep -oE 'scan: "[a-z0-9:-]+"' | sed 's/^scan: "//; s/"$//'; } | LC_ALL=C sort -u)"
  # 바닥값: 콜사이트가 통째로 사라지면 정적·런타임이 함께 줄어 등식이 유지된다(적대 검토가 실측한 구멍).
  n=$(printf '%s\n' "$static" | grep -c . || true)
  # ⚠️ 여유는 두되 **절반이 사라져도 통과하는 상태**는 아니어야 한다 — 이 바닥값의 목적은 위 구멍을
  #    막는 것이고, 여유가 크면 그 구멍이 그대로 열려 있다. 정확한 기대값은 두지 않는다(손 관리 수치는
  #    드리프트한다 — 커널 주석의 실측). 래칫은 아니다: 라벨을 정당하게 줄이는 변경에서는 같이 내리면
  #    되고, 그 조정이 diff에 보이는 것이 요점이다.
  # ⚠️ 여유 안의 **조용한 손실 두 형태는 다른 자리가 막는다.** 되돌림(콜사이트가 직접 출력으로)은 거부
  #    가드가 잡는다. 삭제(콜사이트 자체를 지움 — 바닥값도 함께 사라진다)는 거부 가드도 이 등식도 못 본다
  #    (적대 검토 실측: `scanFloor(…)`를 `void 0`으로 바꿔도 둘 다 green) — 그것은 각 가드의 도메인
  #    테스트가 자기 바닥값·마커를 단언하는 자리다. 여기서 여유를 0으로 조이면 그 자리가 필요 없어지는
  #    것이 아니라 라벨 수가 곧 손 관리 기대값이 된다(설계 §5가 기각한 형태).
  [ "$n" -ge 11 ]
  # 방출 TS 파일 전량을 **파생**한다 — 목록을 손으로 적지 않는다.
  # ⚠️ 정적 집합과 이 목록이 같은 패턴에서 나오므로, 패턴이 깨지면 둘이 함께 비어 등식이 성립한다.
  #    `[ -n "$files" ]`와 위 라벨 바닥값이 그 붕괴를 막고, 우회는 거부 가드가 막는다.
  # ⚠️ 각 grep에 `|| true` — 이관이 진행되며 한 형태가 0건이 되는 것은 정당하고, 그때 grep rc=1이
  #    set -e로 여기서 죽으면 진짜 단언(아래 비어있음·집합 대조)에 도달하지 못한다.
  files="$({ grep -lE "$SCAN_NEW_RE" "$ROOT"/tools/*.ts || true; \
             grep -lE '^[^/]*scan: "' "$ROOT"/tools/*.ts || true; } | LC_ALL=C sort -u)"
  [ -n "$files" ]
  runtime=""
  for f in $files; do
    out="$(bun "$f" 2>/dev/null)" || { echo "TS 가드가 비-0으로 죽었다: $f"; false; }
    runtime="${runtime}$(printf '%s\n' "$out" | sed -n 's/^SCAN: \(.*\): [0-9][0-9]*$/\1/p')
"
  done
  # ⚠️ 모드 의존 콜사이트도 **호출해서** 덮는다 — 제외 목록을 만들지 않는다.
  #    check-workflow-readiness의 `accounted` 라벨은 런타임 모드(`--workflow <f>`)에서만 나온다.
  #    제외하면 그 콜사이트가 죽어도 아무도 모른다(제외 목록이야말로 이 캠페인이 지우는 것이다).
  rt="$(WORKFLOW_NEEDS='{}' bun "$ROOT/tools/check-workflow-readiness.ts" --workflow bump-poll.yaml 2>/dev/null || true)"
  runtime="${runtime}$(printf '%s\n' "$rt" | sed -n 's/^SCAN: \(.*\): [0-9][0-9]*$/\1/p')
"
  runtime="$(printf '%s' "$runtime" | grep -v '^$' | LC_ALL=C sort -u)"
  # 핵심 단언(마지막): 정적 콜사이트와 런타임 방출이 **정확히 같은 집합**이어야 한다.
  [ "$static" = "$runtime" ] || { echo "정적:"; echo "$static"; echo "런타임:"; echo "$runtime"; false; }
}

# 기계 판독 stdout 모드는 마커가 오염시키면 안 된다.
@test "the json mode stays parseable (no marker in machine-readable stdout)" {
  run bash -c "bun '$ROOT/tools/check-guard-authority.ts' --json | jq -e '.guards > 0'"
  [ "$status" -eq 0 ]
}

# 08-a의 목적 자체를 고정하는 증인 — 같은 가드의 픽스처 호출과 실 트리 호출이 **다른 건수**를 낸다.
# 06이 "이 호출이 가드의 실제 도메인에 닿았는가"를 판정할 수 있는 근거가 바로 이 대비다.
# ⚠️ 대비가 항상 큰 것은 아니다(check-app-deploy는 실 트리 2 vs 픽스처 1) — 06은 저대비 사례를
#    다룰 수 있어야 하고, 신호가 없는 가드는 미지로 남긴다.
@test "a fixture invocation and a real-tree invocation report different scan counts" {
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX/apps/x/deploy/prod"
  printf 'kind: NetworkPolicy\n' > "$FX/apps/x/deploy/prod/np.yaml"
  git -C "$FX" init -q
  git -C "$FX" add -A
  fix=$(bash "$ROOT/scripts/check-app-netpol.sh" --root "$FX" 2>/dev/null | sed -n 's/^SCAN: check-app-netpol:manifests: //p')
  real=$(bash "$ROOT/scripts/check-app-netpol.sh" 2>/dev/null | sed -n 's/^SCAN: check-app-netpol:manifests: //p')
  [ -n "$fix" ]
  [ -n "$real" ]
  [ "$fix" -ne "$real" ]
}

# ── TypeScript adapter (08-b) ─────────────────────────────────────────────────
# 같은 규약의 두 번째 adapter. 셸 쪽 단위 테스트 4종을 그대로 이식한다 — 규약이 언어가 아니라
# 의미에서 하나라는 것이 이 커널의 주장이고, 두 adapter가 한 파일에서 나란히 보여야 다음 사람이
# 한쪽만 고치지 않는다(CONTEXT.md 「가드 규약」 — "레인"은 배포 핀 도메인 전용 어휘라 여기서 쓰지 않는다).
#
# 병(TS 고유): 셸 콜사이트는 `[ "$got" -lt "$min" ]`이 수가 아닌 값에 **에러를 낸다**. TypeScript는
# `Number("abc")`가 NaN이고 `n < NaN`이 항상 false라 **바닥값이 통째로 꺼진 채 초록**이 된다.
# 실측(2026-08-25): DISK_CAP_MIN_FLAGS=abc → SCAN 방출 + rc=0.

KERNEL_TS='const k = await import(process.argv[1] + "/tools/lib/scan-floor.ts");'

@test "scanSignal emits the marker in the agreed shape (TypeScript adapter)" {
  run bun -e "$KERNEL_TS"' k.scanSignal("demo", 42)' "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "SCAN: demo: 42" ]
}

@test "scanFloor emits the scan marker when it passes (TypeScript adapter)" {
  run bun -e "$KERNEL_TS"' k.scanFloor("demo", 10, 5)' "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "SCAN: demo: 10" ]
}

# 붕괴한 실행의 건수는 "검사했다"가 아니라 "붕괴했다"는 뜻이다 — 같은 마커로 내면 정반대로 읽힌다.
# ⚠️ 커널은 **종료하지 않는다**(lib 커널 규율). 콜사이트가 잡은 뒤에도 마커가 없어야 한다.
@test "scanFloor does NOT emit the scan marker when it fails (TypeScript adapter)" {
  run bun -e "$KERNEL_TS"' try { k.scanFloor("demo", 0, 5) } catch { /* 콜사이트가 종료를 소유 */ }' "$ROOT"
  [ "$status" -eq 0 ]
  out="$output"
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
}

# lib 커널 규율의 회귀 증인 — `tools/README.md`("콜사이트가 정책 소유") · `image-pin.ts`
# ("process.exit는 전부 콜사이트 소유") · `repo-walk.ts` · `sealed-contract.ts`가 같은 경계를 적었다.
# 이 커널이 종료를 도로 가져가면 콜사이트가 두 실패를 구별할 수 없고, 단위 표면 테스트도 불가능해진다.
@test "the judging kernel section never terminates the process (guardMain alone owns exit)" {
  # ⚠️ **주석 줄을 먼저 걷어낸다.** `^[^/]*` 는 `//`만 제외하므로 JSDoc의 ` * ` 연속줄이 코드로
  #    오인된다 — 실측: 커널 독스트링이 콜사이트 관용구 예시로 `process.exit(…)`를 적자 이 증인이
  #    red가 됐다. 규약은 "커널이 종료를 **부르지** 않는다"이지 "그 단어를 적지 않는다"가 아니다.
  # ⚠️ `run bash -c "… \$ROOT …"`로 쓰면 안 된다 — ROOT는 export되지 않은 bats 지역 변수라
  #    새 셸에서 빈 문자열이 되고, grep이 빈 경로를 읽어 0건 → rc=1 → **이 단언이 항상 통과**한다
  #    (실측: 그 판에서 커널 끝에 process.exit을 넣어도 red가 나지 않았다).
  # 파일은 두 절이다(17 재접목): 판정 커널(scanFloor류 — 종료 금지, ScanError로 콜사이트에 위임)과
  # 실행 커널(guardMain — 진입 함수라 exit를 소유, 반환형 never가 계약). 구분 주석이 경계다 —
  # 마커가 사라지면 절단이 파일 전체가 되어 guardMain의 exit로 이 증인이 red가 난다(fail-closed).
  code="$(awk '/── 실행 커널 guardMain/{exit} {print}' "$ROOT/tools/lib/scan-floor.ts" | grep -vE '^[[:space:]]*(//|\*|/\*)')"
  # 커널을 실제로 읽었다는 증거 — 없으면 아래 판정이 자기 자신 vacuous가 된다.
  [ -n "$code" ]
  if printf '%s\n' "$code" | grep -q 'process\.exit'; then
    echo "판정 커널 절이 종료를 부른다(판정 lib은 종료를 소유하지 않는다):"
    printf '%s\n' "$code" | grep -n 'process\.exit'
    false
  fi
  # 실행 커널 절의 exit 소유는 양성 대조다 — 이게 없으면 위 절단이 빗나가도 조용히 참이다.
  tail_code="$(awk 'f{print} /── 실행 커널 guardMain/{f=1}' "$ROOT/tools/lib/scan-floor.ts" | grep -vE '^[[:space:]]*(//|\*|/\*)')"
  [ -n "$tail_code" ]
  printf '%s\n' "$tail_code" | grep -q 'process\.exit'
}

# 실패는 ScanError로 나가고 **권고 종료코드**를 싣는다 — 콜사이트가 두 사고를 구별할 수 있어야 한다
# (바닥값 붕괴 1 · 임계값이 수가 아님 2). 셸에서 `|| exit 1`과 `|| exit 2`가 갈리던 그 구별이다.
@test "scanFloor throws ScanError carrying the advisory exit code" {
  run bun -e "$KERNEL_TS"'
    try { k.scanFloor("demo", 0, 5) } catch (e) {
      console.log("name=" + e.name + " code=" + e.exitCode);
      console.log("collapse=" + /열거 붕괴/.test(e.message));
      process.exit(0);
    }
    process.exit(9);
  ' "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "name=ScanError code=1"
  echo "$output" | grep -q "collapse=true"
}

# 두 마커는 배타적이다. ⚠️ 마커 존재를 **먼저** 단언한다 — 이게 없으면 "SKIP이 없다"는 마커가
# 아예 없어도 참이라 이 테스트가 자기 자신 vacuous가 된다(셸 쪽 적대 검토 지목, 그대로 이식).
@test "the TypeScript scan marker never carries the skip marker (exclusive channels)" {
  run bun -e "$KERNEL_TS"' k.scanFloor("demo", 10, 5)' "$ROOT"
  [ "$status" -eq 0 ]
  out="$output"
  run grep -q "^SCAN: demo: 10$" <<<"$out"
  [ "$status" -eq 0 ]
  run grep -q "SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

# 억제는 출력 채널의 성질이지 판정의 성질이 아니다 — 마커만 삼키고 바닥값은 그대로 본다.
@test "the quiet option suppresses the marker but still enforces the floor" {
  run bun -e "$KERNEL_TS"' k.scanFloor("demo", 10, 5, { quiet: true })' "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run bun -e "$KERNEL_TS"'
    try { k.scanFloor("demo", 0, 5, { quiet: true }) } catch (e) { console.log("threw:" + e.message); process.exit(0) }
    process.exit(9);
  ' "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "열거 붕괴"
}

# ── 임계값 입력 (r2 G1) ───────────────────────────────────────────────────────
# 검증이 Number() **앞**에 서야 한다. 뒤에 서면 ""가 이미 0이 되어 의도적 0과 구별할 수 없다.

# 사용법 오류라 권고 코드는 2다(열거 붕괴의 1과 구별 — 원인 계층이 다르다).
@test "parseFloor rejects malformed floor input with advisory exit code 2" {
  for bad in abc "" -1 1.5 " " 2x; do
    run bun -e "$KERNEL_TS"'
      try { k.parseFloor(process.argv[2], "--demo") } catch (e) { console.log("code=" + e.exitCode); process.exit(0) }
      process.exit(9);
    ' "$ROOT" "$bad"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "code=2"
  done
}

@test "parseFloor rejects an absent value" {
  run bun -e "$KERNEL_TS"'
    try { k.parseFloor(undefined, "--demo") } catch (e) { console.log("code=" + e.exitCode); process.exit(0) }
    process.exit(9);
  ' "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "code=2"
}

# 0은 정당한 바닥값이다(셸 선례: check-app-deploy 기본 바닥값 0 — 인-레포 앱 0개 동안). 금지하면 안 된다.
@test "parseFloor accepts an explicit zero" {
  run bun -e "$KERNEL_TS"' console.log(k.parseFloor("0", "--demo"))' "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# 상수로 주입되는 자리는 파서를 거치지 않으므로 그 경로를 덮는 안전망이 필요하다.
@test "scanFloor itself rejects a non-integer floor that bypassed the parser" {
  for expr in 'k.scanFloor("demo", 10, Number("abc"))' 'k.scanFloor("demo", Number("abc"), 5)'; do
    run bun -e "$KERNEL_TS"' try { '"$expr"' } catch (e) { console.log("code=" + e.exitCode); process.exit(0) }
      process.exit(9);' "$ROOT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "code=2"
  done
}

# ── check-disk-caps 회귀 (첫 소비자) ──────────────────────────────────────────

# 위반 1건(15GB 상한 > 10Gi 볼륨)짜리 최소 픽스처 — 아래 두 테스트가 공유한다.
# 15GB=1.50e10 > 10Gi=1.07e10 (SI vs IEC — 접미사만 보면 반대로 읽힌다).
make_caps_fixture() {
  FX="$BATS_TEST_TMPDIR/caps"
  mkdir -p "$FX/platform/demo/prod"
  cat > "$FX/platform/demo/prod/app.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: c
          args: ["--retention.maxDiskSpaceUsageBytes=15GB"]
      volumes:
        - name: data
          emptyDir: { sizeLimit: 10Gi }
YAML
  git -C "$FX" init -q
  git -C "$FX" add -A
}

# 위반이 있는 실행에서도 마커가 나와야 한다 — "마커 부재 = 미실행" 해석이 깨지지 않도록.
@test "check-disk-caps emits the scan marker even when it reports violations" {
  make_caps_fixture
  run bash -c "cd '$FX' && bun '$ROOT/tools/check-disk-caps.ts' --floor caps=1"
  [ "$status" -ne 0 ]
  # [ABS-EXEC] W1(감사 63) — 도구가 리네임/부재여도 bun은 rc 1(Module not found)을 내 위 `-ne 0`이
  # 침묵 통과한다. 실제 위반 문구로 "정말 위반을 봤다"를 못박는다(아래 히어스트링 대조와 별개 증인).
  echo "$output" | grep -q "볼륨 선언"
  out="$output"
  run grep -q "^SCAN: check-disk-caps:caps: 1$" <<<"$out"
  [ "$status" -eq 0 ]
  # 위반은 보고된다 — 바닥값을 통과한 실행이므로 그 위반은 실측 결과다.
  # ⚠️ 위반 **고유 문구**로 본다. `::error::disk-caps` 접두는 바닥값 진단도 함께 쓰므로 둘을 못 가른다.
  run grep -q "볼륨 선언" <<<"$out"
  [ "$status" -eq 0 ]
}

# 바닥값과 위반이 **둘 다** 참인 실행. 이 티켓이 "가장 위험한 가정"으로 지목한 경로다 —
# 커널이 종료를 소유하므로 콜사이트가 두 사고를 한 배열에 합칠 수 없다. 합쳐 두면(이행 전 형태)
# 바닥값 진단이 위반 사이에 섞여 나가고 마커는 어느 쪽이든 사라진다.
@test "check-disk-caps dies on the floor before it reports violations" {
  make_caps_fixture
  run bash -c "cd '$FX' && bun '$ROOT/tools/check-disk-caps.ts' --floor caps=5"
  [ "$status" -ne 0 ]
  # [ABS-EXEC] W1(감사 63) — 도구 리네임/부재의 rc 1과 진짜 열거-붕괴 rc를 문구로 가른다.
  echo "$output" | grep -q "열거 붕괴"
  out="$output"
  # 바닥값 진단은 나간다(도메인 힌트를 달고).
  run grep -q "열거 붕괴" <<<"$out"
  [ "$status" -eq 0 ]
  # 마커는 나가지 않는다 — 붕괴한 실행의 건수는 "검사했다"가 아니다.
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
  # 위반 목록은 나가지 않는다 — 0건에 가까운 검사에서 나온 것이라 보고하면 잘못된 그림을 준다.
  # ⚠️ 위반 **고유 문구**로 본다(위와 같은 이유 — 접두는 두 진단이 공유한다).
  run grep -q "볼륨 선언" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "check-disk-caps rejects a malformed floor from the override vocabulary" {
  run bash -c "bun '$ROOT/tools/check-disk-caps.ts' --floor caps=abc"
  [ "$status" -eq 2 ]
  # [ABS-EXEC] W1(감사 63) — rc 2는 이 도구의 부재(Module not found도 rc 1로 다름)와도 다르고
  # 실제 malformed-floor 오류 문구로 어느 쪽이 죽었는지 못박는다.
  echo "$output" | grep -q "음이 아닌 정수"
  out="$output"
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
}

# ── 거부 가드 — 커널 우회 직접 생산자 (T6) ────────────────────────────────────
# 위 집합 대조는 **우회를 막지 못한다**: 정적 로스터와 실행 파일 목록이 같은 패턴에서 파생되므로,
# 한 가드가 직접 출력으로 되돌아가면 양쪽에서 동시에 사라져 등식이 그대로 성립하고 바닥값의 여유가
# 그 손실을 덮는다(설계 §5 · 게이트 r1 F1). 문을 닫는 것은 인식 제거가 아니라 **거부**다 —
# `scripts/check-scan-producers.sh`가 "주석이 아닌 줄이 SCAN 마커를 직접 출력하면 red"를 강제한다.
# 이 파일에서 호출하는 것이 그 가드의 권위 venue다(check-skip-signalling과 같은 형태).

@test "no TypeScript guard emits the scan marker directly (kernel bypass is rejected)" {
  run bash "$ROOT/scripts/check-scan-producers.sh"
  [ "$status" -eq 0 ]
  out="$output"
  # 자기 열거 바닥값을 통과한 실행만 신호를 낸다 — 붕괴한 채 "직접 생산자 0건"을 내는 것이 이 캠페인이 다루는 병이다.
  run grep -qE '^SCAN: check-scan-producers: [0-9]{2,}$' <<<"$out"
  [ "$status" -eq 0 ]
  run grep -q "직접 생산자 0건" <<<"$out"
  [ "$status" -eq 0 ]
}

# 실 `tools/` 추적 트리를 픽스처 루트로 복사한다 — 되돌림 시나리오는 **진짜 가드 파일**에 대해 증명해야
# 하고, 그러면 바닥값·커널 자기 대조가 주입 없이 자연히 성립한다(티켓 04: 테스트 편의로 env를 열면
# 프로덕션 방어가 꺼진다 — 주입은 애초에 필요 없었다).
make_tools_fixture() {   # $1: 하위 디렉토리명 → 경로를 stdout으로
  local fx="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$fx"
  while IFS= read -r f; do
    mkdir -p "$fx/$(dirname "$f")"
    cp "$ROOT/$f" "$fx/$f"
  done <<LIST
$(git -C "$ROOT" ls-files -- 'tools/*.ts' 'tools/*.mts')
LIST
  git -C "$fx" init -q
  git -C "$fx" add -A
  echo "$fx"
}

# 핵심 증인 — 되돌림 시나리오가 red다. 이 단언이 없으면 "거부 축이 있다"는 주장이 무증인이다(티켓 06).
# 두 형태를 다 건다: 커널 호출을 옛 형태로 **되돌린** 가드 · 커널을 안 거치는 **새** 직접 생산자.
@test "reverting a guard to direct marker output is rejected (the bypass hole is closed)" {
  fx="$(make_tools_fixture revert)"
  # 대조군 — 손대지 않은 사본은 통과한다(아래 red가 픽스처 조립 자체의 실패가 아님을 증명).
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx"
  [ "$status" -eq 0 ]
  # 되돌림: 커널 방출을 콜사이트 직접 emission으로(guardMain 이관 후의 등가 되돌림 — 도메인
  # 선언은 그대로 두고 마커를 손으로 하나 더 내는 형태가 정확히 "두 번째 진실"의 모양이다).
  python3 - "$fx/tools/check-resource-limits.ts" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
i=s.index('guardMain({')
n=s[:i]+'console.log("SCAN: check-resource-limits: " + 0);\n'+s[i:]
assert n!=s; open(p,'w',encoding='utf-8').write(n)
PY
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx"
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "커널 우회 직접 생산자" <<<"$out"
  [ "$status" -eq 0 ]
  run grep -q "tools/check-resource-limits.ts:" <<<"$out"
  [ "$status" -eq 0 ]
  # 신호는 **나갔다** — 열거는 정상이었고 위반이 있었을 뿐이다("마커 부재 = 미실행" 해석 유지).
  run grep -qE '^SCAN: check-scan-producers: [0-9]{2,}$' <<<"$out"
  [ "$status" -eq 0 ]
}

# 네 파일이 각각 한 조건을 행사한다 — `.mts` 열거 + `console.info` · `process.stdout.write` · **여러 줄 호출**
# (이 레포의 실제 관용구: `console.log(` 로 끝나고 인자가 다음 줄 — 리뷰가 실 tools/에서 4곳을 실측했다) ·
# `Bun.write(Bun.stdout, …)`. 픽스처가 `console.log` + 쌍따옴표 + `.ts`만 쓰면 나머지 분기는 "넣었지만
# 아무도 보지 않는" 조건이 된다(적대 검토 실측: 동사 목록을 log 하나로 좁혀도 전건 green이었다).
@test "a brand-new direct producer that never touched the kernel is rejected too" {
  fx="$(make_tools_fixture fresh)"
  printf '%s\n' 'const n = 3;' 'console.info("SCAN: check-fresh: " + n);' > "$fx/tools/check-fresh.mts"
  printf '%s\n' 'const n = 3;' 'process.stdout.write(`SCAN: check-write: ${n}\n`);' > "$fx/tools/check-write.ts"
  printf '%s\n' 'const n = 3;' 'console.log(' '  `SCAN: check-multi: ${n}`,' ');' > "$fx/tools/check-multi.ts"
  printf '%s\n' 'const n = 3;' 'await Bun.write(Bun.stdout, "SCAN: check-bun: " + n + "\n");' > "$fx/tools/check-bun.ts"
  git -C "$fx" add -A
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx"
  [ "$status" -eq 1 ]
  out="$output"
  for hit in "tools/check-fresh.mts:2:" "tools/check-write.ts:2:" "tools/check-multi.ts:3:" "tools/check-bun.ts:2:"; do
    run grep -q "$hit" <<<"$out"
    [ "$status" -eq 0 ]
  done
}

# console 동사는 열거가 아니라 클래스다(`console\.[a-z]+`) — 6종 손 열거로는 dir/table/group 같은
# 목록 밖 메서드가 영원히 무증인이다(감사 6라운드 티켓64 c64-6, 형제 check-skip-signalling.sh:63).
@test "a producer using an unlisted console method (console.dir) is rejected too (verb is a class, not an enum)" {
  fx="$(make_tools_fixture unlisted-verb)"
  printf '%s\n' 'const n = 3;' 'console.dir("SCAN: check-dir: " + n);' > "$fx/tools/check-dir.ts"
  git -C "$fx" add -A
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx"
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "tools/check-dir.ts:2:" <<<"$out"
  [ "$status" -eq 0 ]
}

# 검출기 사망은 "매치 0건"이 아니다 — 읽을 수 없는 파일은 넘기기 전에 잡고, 그 실행은 마커를 내지 않는다
# (함정 원장 `findings="$(awk … || true)"`: 검출이 죽은 실행이 "N파일 스캔"을 내면 소비자가 정반대로 읽는다).
@test "an unreadable target is a loud failure before any marker, not a silently skipped file" {
  fx="$(make_tools_fixture unreadable)"
  chmod 000 "$fx/tools/check-resource-limits.ts"
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx"
  chmod 644 "$fx/tools/check-resource-limits.ts"
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "읽을 수 없는 대상" <<<"$out"
  [ "$status" -eq 0 ]
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
}

# 주석 표면 — `//` 줄 · 블록 주석 본문(JSDoc ` * ` 연속줄 **과 별 없는 줄** 둘 다) · 코드 줄 꼬리 `// …`.
# 줄 단위 규칙은 여러 줄 구조를 못 본다(함정 원장 "heredoc 상태 기계…"): 별 없는 블록 본문이 코드로
# 판정돼 오탐이었다(적대 검토 실측) — 그래서 상태 기계다. `^[^/]*`가 `//`만 제외한다는 것은 티켓 03이
# 다른 자리(H1 회귀 증인이 JSDoc의 `process.exit` 예시를 코드로 오인)에서 실측한 같은 클래스다.
# 양성 대조를 같은 파일에 함께 둔다 — 그것이 없으면 "오탐 없음"은 검출기가 죽어도 참이다. 그 대조는
# **홑따옴표 + 꼬리 주석**이다: 따옴표 세 종과 "주석 판정은 행 앞에서만"을 한 줄이 함께 행사한다
# (적대 검토 실측: 홑따옴표 조건을 지우거나 주석 앵커를 줄 중간까지 풀어도 전건 green이었다).
@test "marker text inside the comment surfaces is not a producer (and a real one beside them is)" {
  fx="$(make_tools_fixture comments)"
  cat > "$fx/tools/lib/prose.ts" <<'TS'
// console.log(`SCAN: prose-a: 1`) — 규약을 설명하는 줄
/** 독스트링 첫 줄
 * 콜사이트 관용구 예시: console.log("SCAN: prose-b: 2")
   console.log("SCAN: prose-b2: 2") — 별 없이 들여쓴 연속줄
 */
/* 블록 주석 한 줄: process.stdout.write("SCAN: prose-c: 3") */
/*
  블록 주석 본문 — 별 없는 중간 줄:
  console.log("SCAN: prose-c2: 3")
*/
export const prose = true; // 꼬리 주석: console.log("SCAN: prose-e: 5")
TS
  git -C "$fx" add -A
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx"
  [ "$status" -eq 0 ]
  # 양성 대조 — 같은 파일의 코드 줄 하나가 red를 낸다(홑따옴표 · 꼬리 주석 달림).
  printf '%s\n' "console.log('SCAN: prose-d: 4'); // 설명" >> "$fx/tools/lib/prose.ts"
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx"
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "tools/lib/prose.ts:12:" <<<"$out"
  [ "$status" -eq 0 ]
  run grep -qE "prose-(a|b|b2|c|c2|e)" <<<"$out"
  [ "$status" -ne 0 ]
}

# 마커를 **다루는** 코드는 생산자가 아니다 — 선은 "출력 동사의 인자가 마커 리터럴로 **시작**"이다.
# 정규식 리터럴·상수·`startsWith("SCAN: ")` 소비자·마커 형태를 인용하는 진단문은 전부 그 선 밖이다.
# 이 선이 없으면 규약을 구현·설명하는 파일마다 자기를 제외 목록에 넣어야 한다.
# ⚠️ 이행 첫 판은 "출력 동사 + 앞에 따옴표"였고, `if (l.startsWith("SCAN: ")) console.log(l)`와
#    `console.error("힌트: 'SCAN: <라벨>…'")`가 오탐이었다(적대 검토 실측) — 증인은 정규식 철자에서만
#    green이었다. 아래 픽스처가 그 형태들을 전부 행사한다.
@test "code that handles the marker without emitting it is not a producer" {
  fx="$(make_tools_fixture handler)"
  cat > "$fx/tools/lib/marker-parse.ts" <<'TS'
export const RE = /^SCAN: ([a-z:-]+): (\d+)$/;
export const PREFIX = "SCAN: ";
export const echoRe = (ls: string[]) => { for (const l of ls) if (/^SCAN: /.test(l)) console.log(l); };
export const echoSw = (ls: string[]) => { for (const l of ls) if (l.startsWith("SCAN: ")) console.log(l); };
export const relay = (l: string) => { if (l.startsWith("SCAN: ")) console.error(`relay ${l}`); };
export const isMark = (l: string) => { console.log(/^SCAN: /.test(l) ? "y" : "n"); };
export const hint = () => { console.error("힌트: 가드는 'SCAN: <라벨>: <n>' 마커를 stdout에 낸다"); };
export const warn = (label: string) => { console.warn(`WARN: 'SCAN: ${label}: <n>' 마커가 출력에 없다`); };
TS
  git -C "$fx" add -A
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx"
  [ "$status" -eq 0 ]
  out="$output"
  # vacuity 방지 — 이 실행이 그 파일을 실제로 읽었다(열거 수가 사본 62 + 1).
  run grep -qE '^SCAN: check-scan-producers: [0-9]{2,}$' <<<"$out"
  [ "$status" -eq 0 ]
}

# 검출기 자기 대조 — 커널의 생산자 줄이 코드에서 안 보이면 "위반 0건"이 아니라 **검출기 붕괴**다.
# 파일 수 바닥값은 줄 단위 붕괴를 원리적으로 못 본다(함정 원장 "heredoc 상태 기계…").
@test "the detector reports its own collapse when the kernel producer line is invisible to it" {
  fx="$(make_tools_fixture kernel-dead)"
  python3 - "$fx/tools/lib/scan-floor.ts" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
n=s.replace('  console.log(`SCAN: ${label}: ${n}`);','  const line = "SCAN" + ": " + label + ": " + n; console.log(line);')
assert n!=s; open(p,'w',encoding='utf-8').write(n)
PY
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx"
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "검출기 붕괴" <<<"$out"
  [ "$status" -eq 0 ]
  # 커널 파일 자체가 열거에서 빠져도 같은 판정이다(면제 대상 부재 = 붕괴, 조용한 통과가 아니다).
  fx2="$(make_tools_fixture kernel-gone)"
  git -C "$fx2" rm -qf tools/lib/scan-floor.ts
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx2"
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "검출기 붕괴" <<<"$out"
  [ "$status" -eq 0 ]
  # 면제는 **정확한 경로 하나**다 — 같은 이름의 그림자 파일은 면제되지 않는다(basename 비교로 바꿔도
  # 전건 green이었다 — 적대 검토 실측).
  fx3="$(make_tools_fixture kernel-shadow)"
  printf '%s\n' 'console.log("SCAN: shadow: 1");' > "$fx3/tools/scan-floor.ts"
  git -C "$fx3" add -A
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx3"
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "tools/scan-floor.ts:1:" <<<"$out"
  [ "$status" -eq 0 ]
}

# 자기 열거 바닥값 — 작은 트리에서 자연히 붕괴한다(주입 없음). 붕괴한 실행은 마커를 내지 않는다.
@test "the rejection guard has its own enumeration floor (a collapsed scan is not a pass)" {
  fx="$BATS_TEST_TMPDIR/tiny"
  mkdir -p "$fx/tools/lib"
  cp "$ROOT/tools/lib/scan-floor.ts" "$fx/tools/lib/scan-floor.ts"
  git -C "$fx" init -q
  git -C "$fx" add -A
  run bash "$ROOT/scripts/check-scan-producers.sh" --root "$fx"
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "열거 붕괴" <<<"$out"
  [ "$status" -eq 0 ]
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "the rejection guard rejects an unknown option with the usage exit code" {
  run bash "$ROOT/scripts/check-scan-producers.sh" --bogus
  [ "$status" -eq 2 ]
}

@test "scan_floor with quiet checks the floor but withholds the marker" {
  # TS 커널이 이미 확정한 의미론이다 — **억제(quiet)는 출력 채널의 성질이지 판정의 성질이 아니다**
  # (tools/lib/scan-floor.ts). 셸 adapter에만 그 프리미티브가 없어서 다중 도메인 가드가 도메인마다
  # 즉시 방출했고, **붕괴한 실행이 앞 도메인의 "N건 검사했다"를 그대로 냈다**(실측 3가드).
  # 통과 + quiet → 마커 없음, 종료코드 0.
  run bash -c '. "$1"; scan_floor demo 10 10 quiet' _ "$LIB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # 붕괴 + quiet → **판정은 그대로 red**이고 진단은 나간다(진단은 억제 대상이 아니다).
  run bash -c '. "$1"; scan_floor demo 0 10 quiet' _ "$LIB"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '열거 붕괴'
  # quiet를 안 주면 종전과 같다 — 선택 인자라 하위호환이다.
  run bash -c '. "$1"; scan_floor demo 10 10' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "SCAN: demo: 10" ]
}
