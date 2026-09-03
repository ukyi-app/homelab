#!/usr/bin/env bats
# vmalert 발화 e2e의 **replay 지연 계약** — 속도를 위해 체이닝 레이스 방지선이 깎이는 것을 막는다.
#
# 왜 이 게이트가 필요한가: `--replay.rulesDelay`는 이 계열 게이트의 wall-clock **그 자체**다.
#   벽시계 ≈ (룰 파일의 룰 수) × rulesDelay × (레그 수)
#   실측(CI run 30332565823 + 로컬): drift = r6(6룰)×8레그×4s → 192s 예측 / 194s 실측(1% 이내).
# 즉 이 값은 "CI가 느리다"는 압력을 상시로 받는다. 그런데 낮추면 되돌아오는 것은 조용한 오답이 아니라
# **간헐적 거짓 RED**이고, 그건 게이트를 신뢰 불가로 만들어 결국 꺼지게 만든다.
#
#   ⚠️ 체이닝 레이스: alert 룰은 record 룰이 remoteWrite한 시리즈를 query_range **1회**로 읽는다.
#      record 샘플이 아직 적재 전이면 결과가 통째로 비어 ALERTS=0 → 버그가 아닌데 RED.
#
# ★ 실측이 "비율만 지키면 된다"를 기각했다(2026-07-28): rulesDelay 4s→1s를 하면서 flushInterval을
#   500ms→100ms로 함께 줄여 비율을 8×→10×로 **키웠는데도** drift가 그 FAULT로 죽었다. 구속 조건은
#   비율이 아니라 **절대 지연 예산**이다. ⇒ 속도는 **체인이 없는 룰 파일에서만** 얻을 수 있다.
#   그래서 lib은 지연을 룰 파일에서 파생하고(vme_rules_delay), 이 게이트는 그 파생이 살아 있는지를 본다.
#
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  LIB="tests/gates/lib/vmalert-e2e.sh"
}

# replay를 실행하는 **추적된** 사이트 전량. 하드코딩 목록이 아니다 — 새 하네스가 자기 replay를
# 인라인하면 자동으로 이 게이트의 대상이 된다.
sites() { git ls-files 'tests/gates/*.sh' 'tests/gates/lib/*.sh' | xargs grep -l -- '--replay.rulesDelay'; }

@test "replay sites are enumerated (floor guards against a collapsed scope)" {
  n="$(sites | grep -c .)"
  # 바닥값 1 = lib 단독. 인라인 사본은 전부 흡수됐다(마지막이 drift 하네스였다) → 남는 사이트는 lib뿐이다.
  # 0건이면 아래 검사가 전부 vacuous하게 통과한다.
  # ⚠️ 바닥값을 2→1로 내린 대가는 **아래 "사본 0" 단언이 갚는다**. 바닥값만 내리면 인라인 사본이
  #    되살아나도 아무도 안 본다(사본은 하한 검사만 만족시키면 되고, 그러면 "파생이 살아 있다"는
  #    이 파일의 나머지 단언이 그 사본에 대해서는 통째로 무의미해진다).
  [ "$n" -ge 1 ]
}

@test "no firing-e2e harness runs vmalert replay outside the shared lib" {
  hs="$(git ls-files 'tests/gates/vmalert-*-firing-e2e.sh')"
  n="$(printf '%s\n' "$hs" | grep -c .)"
  # 열거 붕괴 방어 — 글롭이 깨져 0건이 되면 아래 루프가 vacuous하게 통과한다(ci.yaml의 같은 목록도 ≥3).
  [ "$n" -ge 3 ] || { echo "발화 e2e 하네스 ${n}건 < 3 — 열거 붕괴(무측정 초록)"; return 1; }
  for f in $hs; do
    if grep -q -- '--replay.rulesDelay' "$f"; then
      echo "$f: vmalert replay를 **인라인**한다 — lib의 vme_replay를 쓰라."
      echo "  인라인 사본은 vme_rules_delay 파생을 통째로 우회하므로, 체인 없는 룰 파일에서 얻을 수 있는"
      echo "  속도도 못 얻고 리터럴이 lib과 갈리기만 한다(그 갈림은 red를 내지 않는다)."
      return 1
    fi
    grep -q 'vme_replay ' "$f" || { echo "$f: vme_replay 호출이 없다 — replay 경로가 lib을 통하지 않는다"; return 1; }
  done
}

@test "no firing-e2e harness redefines the lib expr/rollup helpers (verdict vocabulary stays local by policy)" {
  # lib 헬퍼(vme_alert_expr·vme_rollup_windows)의 로컬 재정의는 byte-identical 사본 표면이다 — 한쪽만
  # 바뀌면 하네스가 배포 룰이 아니라 자기 사본의 해석을 검증하게 된다(d5 사본-0 축의 확장).
  # ⚠️ 판정 어휘(fault/contract/fail/pass)는 **명시 제외**다 — 문서화된 하네스-로컬 정책
  #    (CONTEXT.md 「판정 어휘」: (preflight) 라벨과 로컬 집계가 진단의 절반)이라 측정 도메인 밖이다.
  #    2-피연산자 rollup preflight(bulkssd)도 로컬 유지다(vme_assert_rollup_ok가 표현 불가).
  hs="$(git ls-files 'tests/gates/vmalert-*-firing-e2e.sh')"
  n="$(printf '%s\n' "$hs" | grep -c .)"
  [ "$n" -ge 6 ] || { echo "발화 e2e 하네스 ${n}건 < 6 — 열거 붕괴(무측정 초록)"; return 1; }
  for f in $hs; do
    # 이름 축 — lib 헬퍼(및 그 접두 없는 원형)의 로컬 재정의 금지.
    run grep -cE '^[[:space:]]*(vme_)?(alert_expr|alert_for|record_expr|rollup_windows|rollup_count)[[:space:]]*\(\)' "$f"
    [ "$output" = "0" ] || { echo "$f: lib 헬퍼의 로컬 재정의(${output}곳) — vme_* 헬퍼를 쓰라(사본은 red를 내지 않고 갈린다)"; return 1; }
    # 형태 축 — 개명해도 잡는다: yq 룰-워크 리터럴은 룰 해석 사본의 지문이다(lib 밖 출현 0 —
    # drift의 record_expr 사본이 이름 축만으로는 초록이던 실측 구멍의 봉쇄).
    run grep -cF 'groups[].rules[]' "$f"
    [ "$output" = "0" ] || { echo "$f: yq 룰-워크 리터럴(${output}곳) — 룰 해석은 lib 헬퍼가 소유한다(개명 사본도 이 지문으로 잡힌다)"; return 1; }
  done
}

@test "no replay site hardcodes a rulesDelay below the measured-safe floor" {
  # 리터럴로 박은 사이트는 체인이 있다고 가정해야 안전하다 → 4s 하한. 파생($delay)을 쓰는 사이트는
  # 아래 별도 테스트가 파생 자체를 검증한다.
  for f in $(sites); do
    v="$(grep -oE -- '--replay\.rulesDelay=[^ \\]+' "$f" | head -1 | cut -d= -f2)"
    [ -n "$v" ] || { echo "$f: rulesDelay 추출 실패"; return 1; }
    case "$v" in
      '"$delay"') continue ;;                      # 파일에서 파생 — 아래에서 별도 검증
      *s) s="${v%s}" ;;
      *) echo "$f: rulesDelay '$v' 형식 미인식(초 단위 리터럴 또는 \$delay만 허용)"; return 1 ;;
    esac
    case "$s" in ''|*[!0-9]*) echo "$f: rulesDelay '$v' 비수치"; return 1 ;; esac
    [ "$s" -ge 4 ] || {
      echo "$f: rulesDelay=${v} < 4s — 체이닝 레이스 방지선 아래다."
      echo "  속도가 목적이면 값을 깎지 말고 **체인 없는 룰 파일**에서 얻어라(lib의 vme_rules_delay)."
      echo "  4s→1s는 flushInterval을 함께 줄여 비율을 키워도 실패한다(2026-07-28 실측)."
      return 1
    }
  done
}

@test "the shared lib derives rulesDelay from the rules file AND actually passes it to vmalert" {
  # 이 파생이 사라지면(리터럴로 회귀) 속도가 조용히 되돌아간다 — 성능 회귀는 red를 안 내므로 여기서 잡는다.
  # ⚠️ 대입문만 보면 안 된다: 값을 계산해 놓고 플래그엔 리터럴을 넘기는 변이가 통과한다(mutation으로 실측).
  #    **소비 지점**이 load-bearing 단언이다.
  run grep -q 'delay="$(vme_rules_delay' "$LIB"
  [ "$status" -eq 0 ]
  run grep -q -- '--replay.rulesDelay="\$delay"' "$LIB"
  [ "$status" -eq 0 ]
}

@test "the chained constant stays at or above the measured-safe floor" {
  v="$(grep -oE '^VME_DELAY_CHAINED=[0-9]+s' "$LIB" | cut -d= -f2)"
  [ -n "$v" ] || { echo "$LIB: VME_DELAY_CHAINED 부재"; return 1; }
  [ "${v%s}" -ge 4 ]
}

# ── 파생기 자체의 이빨: 양성·음성 대조 ────────────────────────────────────────────────────────────
# 한 방향만 보면 무력한 파생기가 통과한다 — 항상 4s를 돌려주면 음성 대조가, 항상 1s면 양성 대조가 잡는다.
# 대조군은 **레포의 실제 배포 룰**이다(픽스처 복제 금지 — 룰이 바뀌면 이 테스트도 함께 따라와야 한다).

@test "chain detector: r6 (has a record rule consumed by an alert) yields the conservative delay" {
  tmp="$(mktemp -d)"
  yq '.data["r6.yaml"]' platform/victoria-stack/prod/rules/r6-ci-staleness.yaml > "$tmp/r6.yaml"
  [ -s "$tmp/r6.yaml" ] || { rm -rf "$tmp"; echo "r6 룰 추출 실패"; return 1; }
  # 전제: r6에 실제로 체인이 있어야 이 대조가 의미를 갖는다(룰이 바뀌어 체인이 사라지면 여기서 드러난다).
  grep -q 'record: app:image_digest_drift' "$tmp/r6.yaml" || { rm -rf "$tmp"; echo "r6에 record 룰 부재 — 양성 대조가 성립하지 않는다"; return 1; }
  # shellcheck source=/dev/null
  source "$LIB"
  got="$(vme_rules_delay "$tmp/r6.yaml")"
  rm -rf "$tmp"
  [ "$got" = "$VME_DELAY_CHAINED" ]
}

@test "chain detector: r4 (no record rules at all) yields the fast delay" {
  tmp="$(mktemp -d)"
  yq '.data["r4.yaml"]' platform/victoria-stack/prod/rules/r4-storage-backup.yaml > "$tmp/r4.yaml"
  [ -s "$tmp/r4.yaml" ] || { rm -rf "$tmp"; echo "r4 룰 추출 실패"; return 1; }
  # shellcheck source=/dev/null
  source "$LIB"
  got="$(vme_rules_delay "$tmp/r4.yaml")"
  rm -rf "$tmp"
  # 핵심 단언(마지막): 여기가 red면 가장 느린 두 하네스(digest·bulkssd)가 불필요한 대기로 돌아간 것이다.
  [ "$got" = "$VME_DELAY_PLAIN" ]
}

@test "chain detector is fail-closed on an unreadable rules file" {
  # shellcheck source=/dev/null
  source "$LIB"
  got="$(vme_rules_delay "/nonexistent/rules-$$.yaml")"
  [ "$got" = "$VME_DELAY_CHAINED" ]
}

@test "the chaining-race discriminator is called wherever it is defined" {
  # 원장 71행 「체이닝 레이스의 두 번째 얼굴」의 처방(require_engaged)은 drift·meta 두 하네스에
  # 정의돼 있지만, 그 정의를 실제로 호출하는지 재는 정적 게이트가 없었다 — 뮤테이션 실측
  # (2026-09-03): drift 하네스의 `require_engaged L*` 호출 6건을 전부 삭제해도(정의만 잔존)
  # 이 파일의 나머지 8레인·check-bats-style·verify-traps·check-skeleton 전건 초록이었다.
  # 건수 바닥값·정의-보유-하네스 집합 등식은 손 로스터다(레그 증감·새 하네스 채택마다 갱신 필요) —
  # 대신 "정의는 있는데 호출 0"만 좁혀 잡는다(뮤테이션을 정확히 잡고 정당한 증감엔 안 문다).
  hs="$(git ls-files 'tests/gates/vmalert-*-firing-e2e.sh')"
  [ "$(printf '%s\n' "$hs" | grep -c .)" -ge 6 ] || { echo "발화 e2e 하네스 열거 붕괴"; return 1; }
  n=0
  for f in $hs; do
    grep -q '^require_engaged() {' "$f" || continue
    run grep -cE '^require_engaged ' "$f"
    [ "$output" -gt 0 ] || { echo "$f: 정의만 있고 호출 0 — 레이스 판별기가 죽었다"; return 1; }
    n=$((n + 1))
  done
  [ "$n" -ge 2 ] || { echo "정의 보유 하네스 ${n} < 2(drift + meta)"; return 1; }
}
