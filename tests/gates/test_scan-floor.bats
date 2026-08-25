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
  # 라벨 수 바닥값은 **전체** 정적 집합에서 센다 — SKIP과 무관하게 "라벨이 사라졌는가"를 보는 축이다.
  labels=$(printf '%s\n' "$static" | grep -c . || true)
  [ "$labels" -ge 10 ]
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
    [ "$rc" -eq 0 ] || { echo "가드가 비-0으로 죽었다: $f (rc=$rc)"; false; }
    cmp_static="${cmp_static}${lbl}
"
    runtime="${runtime}$(printf '%s\n' "$out" | sed -n 's/^SCAN: \(.*\): [0-9][0-9]*$/\1/p')
"
  done <<EOF
$guards
EOF
  # ⚠️ SKIP 상한이 없으면 "전부 SKIP → 양쪽 공집합 → 등식 성립"이라는 vacuous green이 열린다.
  #    SKIP은 venue에 따라 달라지므로(로컬 0 · CI 1) 바닥값이 아니라 **상한**으로 문다.
  echo "skipped(${nskip}):${skipped}"
  [ "$nskip" -le 2 ]
  cmp_static="$(printf '%s' "$cmp_static" | grep -v '^$' | LC_ALL=C sort -u)"
  runtime="$(printf '%s' "$runtime" | grep -v '^$' | LC_ALL=C sort -u)"
  [ "$cmp_static" = "$runtime" ] || { echo "정적:"; echo "$cmp_static"; echo "런타임:"; echo "$runtime"; false; }
}

# 콜사이트 증인 — 바닥값 면제(픽스처·인자) 모드와 바닥값 없는 레인도 **자기** 신호를 낸다.
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

# TS 가드도 같은 규약을 쓴다(커널이 셸 전용이라 마커는 콜사이트에 있다).
# ⚠️ **앞선 판은 하드코딩 로스터였고 이미 드리프트했다** — 3행(resource-limits·alert-rules·
#    guard-authority)만 적혀 있었는데 실제 방출 TS는 5종이었다(image-ownership·workflow-readiness가
#    누락). "하드코딩 소비처 목록은 자기 자신에게만 정확하다"(AGENTS.md 함정)의 살아있는 사례다.
#    ⇒ 셸 adapter와 **동형**으로 바꾼다: 정적 콜사이트 라벨 집합 == 런타임 방출 라벨 집합.
#
# ⚠️ **이행 중에는 두 형태가 공존한다.** 옛 형태(콜사이트가 직접 `console.log`)와 새 형태(커널 호출).
#    둘 다 인식해야 각 이행 티켓이 독립적으로 green이다. 한쪽만 보면 옮긴 가드가 정적·런타임 집합에서
#    **동시에** 사라져 등식이 그대로 성립하고(실측: check-disk-caps를 옮긴 직후 이 테스트가 통과했다),
#    바닥값의 여유가 그 손실을 덮는다.
# ⚠️ **이 등식만으로는 커널 우회를 막지 못한다.** 되돌린 가드도 같은 이유로 양쪽에서 함께 사라진다.
#    문을 닫는 것은 인식 제거가 아니라 **거부**다 — 마지막 이행 티켓이 "직접 생산자가 있으면 red"인
#    가드를 세운다. 그때까지 이 확장은 임시 상태다.
SCAN_OLD_RE='^[^/]*SCAN: '
SCAN_NEW_RE='^[^/]*scan(Floor|Signal)\('

@test "the TypeScript guards emit the same marker shape (derived roster, not hardcoded)" {
  # 정적: 주석(//) 줄을 제외한 콜사이트. 옛 형태는 `SCAN: <라벨>:`, 새 형태는 `scanFloor("<라벨>"`.
  # 라벨은 도메인 단위라 접미사가 붙을 수 있다.
  static="$( { grep -hE "$SCAN_OLD_RE" "$ROOT"/tools/*.ts | grep -oE 'SCAN: [a-z0-9:-]+:' | sed 's/^SCAN: //; s/:$//'
               grep -hE "$SCAN_NEW_RE" "$ROOT"/tools/*.ts | grep -oE 'scan(Floor|Signal)\("[a-z0-9:-]+"' | sed 's/^[^"]*"//; s/"$//'
             } | LC_ALL=C sort -u)"
  # 바닥값: 콜사이트가 통째로 사라지면 정적·런타임이 함께 줄어 등식이 유지된다(적대 검토가 실측한 구멍).
  n=$(printf '%s\n' "$static" | grep -c . || true)
  [ "$n" -ge 6 ]
  # 방출 TS 파일 전량을 **파생**한다 — 목록을 손으로 적지 않는다.
  files="$(grep -lE "$SCAN_OLD_RE|$SCAN_NEW_RE" "$ROOT"/tools/*.ts)"
  [ -n "$files" ]
  # ⚠️ **아래 등식은 두 형태를 다 본다는 것을 증명하지 못한다.** 커널로 옮긴 가드는 정적 로스터와
  #    이 파일 목록에서 **동시에** 빠지므로 등식이 그대로 성립하고, 바닥값의 여유가 그 손실을 덮는다
  #    (실측 재현: check-disk-caps를 옮긴 직후 이 테스트가 통과했다). 그래서 인식 자체를 여기서
  #    단언한다 — 대상이 **이 변수들**이라 검증이 자기 계산을 보는 것으로 미끄러지지 않는다.
  new_files="$(grep -lE "$SCAN_NEW_RE" "$ROOT"/tools/*.ts)"
  new_labels="$(grep -hE "$SCAN_NEW_RE" "$ROOT"/tools/*.ts \
                | grep -oE 'scan(Floor|Signal)\("[a-z0-9:-]+"' | sed 's/^[^"]*"//; s/"$//')"
  # ⚠️ **신형 열거 자체에 바닥값을 건다.** 없으면 SCAN_NEW_RE가 깨졌을 때 아래 두 루프가 0회 반복해
  #    조용히 통과하고(실측: 매치 0으로 변조하니 27건 전부 green), 등식은 양쪽이 함께 줄어 유지된다.
  #    검증이 기준을 대상과 **같은 깨진 패턴**에서 뽑는 자리라, 이 커널이 다루는 그 병을 검증 쪽에
  #    새로 만든다. 이행이 끝나 옛 형태가 0이 되면 이 단언은 거부 가드로 대체된다.
  [ -n "$new_files" ]
  [ -n "$new_labels" ]
  for f in $new_files; do
    printf '%s\n' "$files" | grep -qxF "$f"
  done
  for lbl in $new_labels; do
    printf '%s\n' "$static" | grep -qxF "$lbl"
  done
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
# 의미에서 하나라는 것이 이 커널의 주장이고, 두 레인이 한 파일에서 나란히 보여야 다음 사람이
# 한쪽만 고치지 않는다.
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
@test "the TypeScript scan kernel never terminates the process itself" {
  run grep -nE '^[^/]*process\.exit' "$ROOT/tools/lib/scan-floor.ts"
  [ "$status" -ne 0 ]
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

# 0은 정당한 바닥값이다(셸 선례: check-app-deploy의 APP_DEPLOY_MIN_SCAN:-0). 금지하면 안 된다.
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
  run bash -c "cd '$FX' && DISK_CAP_MIN_FLAGS=1 bun '$ROOT/tools/check-disk-caps.ts'"
  [ "$status" -ne 0 ]
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
  run bash -c "cd '$FX' && DISK_CAP_MIN_FLAGS=5 bun '$ROOT/tools/check-disk-caps.ts'"
  [ "$status" -ne 0 ]
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

@test "check-disk-caps rejects a malformed floor from the environment" {
  run bash -c "DISK_CAP_MIN_FLAGS=abc bun '$ROOT/tools/check-disk-caps.ts'"
  [ "$status" -eq 2 ]
  out="$output"
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
}
