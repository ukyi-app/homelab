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
  run grep -q "SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

# 커버리지 증인 — 커널을 타는 셸 가드는 **전부** 잘 형성된 신호를 낸다.
# 커널 emit이 사라지거나 콜사이트 하나가 빠지면 여기서 red가 된다(조용한 커버리지 축소 차단).
@test "every kernel-backed shell guard emits a well-formed scan marker" {
  bad=""
  for g in check-app-netpol check-app-deploy check-skeleton check-bats-accounting \
           check-bats-style sops-guard verify-secrets check-image-pins; do
    n=$(bash "$ROOT/scripts/$g.sh" 2>/dev/null | grep -cE '^SCAN: [a-z0-9:-]+: [0-9]+$' || true)
    [ "${n:-0}" -ge 1 ] || bad="$bad $g"
  done
  [ -z "$bad" ]   # 비어야 통과. 디버깅: echo "$bad"
}

# TS 가드도 같은 규약을 쓴다(커널이 셸 전용이라 마커는 콜사이트에 있다).
@test "the TypeScript guards emit the same marker shape" {
  bad=""
  for t in check-resource-limits check-alert-rules check-guard-authority; do
    n=$(bun "$ROOT/tools/$t.ts" 2>/dev/null | grep -cE "^SCAN: ${t}: [0-9]+$" || true)
    [ "${n:-0}" -eq 1 ] || bad="$bad $t"
  done
  [ -z "$bad" ]
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
  fix=$(bash "$ROOT/scripts/check-app-netpol.sh" --root "$FX" 2>/dev/null | sed -n 's/^SCAN: check-app-netpol: //p')
  real=$(bash "$ROOT/scripts/check-app-netpol.sh" 2>/dev/null | sed -n 's/^SCAN: check-app-netpol: //p')
  [ -n "$fix" ]
  [ -n "$real" ]
  [ "$fix" -ne "$real" ]
}
