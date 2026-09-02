#!/usr/bin/env bash
# 전 bats 도메인 accounting 가드 (F6 클래스 차단 — 테스트가 어느 harness에도 안 묶여 조용히 죽음).
# 모든 추적 test_*.bats는 **정확히 한 도메인**에 배정돼야 한다:
#   ① gate        — scripts/run-bats.sh --list 에 포함(required gate가 수집·실행)
#   ② chart-test  — platform/charts/app/tests/ 하위(make chart-test 별도 harness)
#   ③ .ci-exclude — not-CI-safe 레지스트리(주석이 실행처 iac/manual/age/docker 명시)
# 매치 수 ≠ 1 → 실패(0=고아, 2+=이중소유). + .ci-exclude 유효성: (a) git-tracked 실재, (b) gate 미포함(모순),
# (c) 사유 그룹 주석 지배 + 실행처 표기, (d) 레지스트리 상한.
# bash 3.2 호환: mapfile·[[ ]]·`cmd && n++`(set -e 함정) 금지 — if-블록·case·카운터로.
#
# ⚠️ **도메인 회계만으로는 gate → .ci-exclude '이동'이 원리적으로 안 보인다** — 옮겨도 여전히 정확히 한
#    도메인이라 초록이다. 실측(2026-07-30): gate 208건 중 81건을 .ci-exclude로 옮겨도 이 가드·
#    check-skeleton·check-guard-authority·`make verify`가 전부 초록이었고, 사유 주석 없이 한 줄 추가하는
#    것도 아무 가드에 안 걸렸다. `.ci-exclude` 헤더는 "accounting 가드가 강제한다"고 **주장만** 하고 있었다
#    (가드는 `#` 줄을 건너뛰기만 했다 — 이 레포가 반복해 밟은 "코드와 다른 서술").
#    ⇒ 아래 (0)(0b)(3)이 그 구멍이다.
# ⚠️ 이 가드는 ci.yaml의 **명시 스텝**이다(자기 bats에만 의존하면 .ci-exclude 한 줄로 자기가 꺼진다).
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-bats-accounting
cd "$ROOT"

# ⚠️ **맨 인자로 모드를 바꾸지 않는다.** 앞선 판은 `if [ "$#" -gt 0 ]`로 첫 인자를 레지스트리 경로로 삼았는데,
#    그러면 **아무 토큰이나 하나** 붙는 순간 도메인 회계와 gate 바닥값이 통째로 건너뛰어지고 exit 0이 된다
#    (적대 검토 실측: gate를 0건으로 파괴한 상태에서 무인자=rc 1 / 인자 1개=rc 0). 소비처가 셋이라
#    (`ci.yaml`·`Makefile` 2곳) 어디든 인자 한 토큰이면 이 가드가 자기 자신을 끄는 off-switch가 된다.
#    ⇒ 픽스처 모드는 **명시 플래그**로만 열고, 모르는 인자는 fail-loud(exit 2)다.
EXCLUDE_FILE="tests/.ci-exclude"
LINT_ONLY=0
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 03 — 구 env 폐지).
take_floors "check-bats-accounting:gate check-bats-accounting:tracked" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
while [ $# -gt 0 ]; do
  case "$1" in
    --lint-excludes)
      LINT_ONLY=1
      EXCLUDE_FILE="${2:-}"
      [ -n "$EXCLUDE_FILE" ] || { echo "ERROR: --lint-excludes에 레지스트리 파일 인자가 필요하다" >&2; exit 2; }
      shift 2 ;;
    *)
      echo "ERROR: 알 수 없는 인자 '$1' — 인자 없이 전 회계를 돌리거나 '--lint-excludes <파일>'로 레지스트리 계약만 본다." >&2
      exit 2 ;;
  esac
done
[ -f "$EXCLUDE_FILE" ] || { echo "ERROR: 레지스트리 파일 없음: $EXCLUDE_FILE" >&2; exit 2; }

rc=0

# ── (0) 레지스트리 계약: 항목은 '사유 + 실행처'를 적은 그룹 주석의 지배를 받는다 ──────────────────
# 파일 헤더가 주장하던 계약을 **실제로** 강제한다.
#   · 빈 줄이 그룹을 끊는다 — 파일 상단 헤더가 아래 항목 전부를 지배하면 무엇이든 통과한다.
#   · **항목 뒤의 주석은 새 그룹을 연다**(앞 블록에 이어붙지 않는다). 이걸 빼먹으면 새 그룹 헤더가 앞
#     그룹의 실행처 표기를 물려받아 통과한다 — 이 규칙을 쓰면서 실제로 낸 버그다(전용 @test로 고정).
#   · 지배 블록에 `실행처` 문자열이 있어야 한다.
# ⚠️ **이건 텍스트 계약이지 증명이 아니다.** 단어만 적고 실제 venue가 없어도 통과한다(실측: dev-postgres·
#    bootstrap·makefile은 자동 실행 경로가 0이라 주석을 owner-local 수동 실행으로 정직하게 고쳐 적었다.
#    sops-guard는 반대로 `make verify`에 실제 호출을 붙여 표기를 참으로 만들었다). 실행처의
#    실재를 강제하려면 check-guard-authority류의 venue 파생이 필요하다 — 별건이다.
#    증가를 실제로 **묶는 것은 아래 (0b) 상한**이고, 이 계약은 "조용히"를 없앨 뿐이다.
excl_n=0
group=""
after_entry=0
lineno=0
while IFS= read -r line; do
  lineno=$((lineno + 1))
  case "$line" in
    '') group=""; after_entry=0; continue;;
    \#*)
      if [ "$after_entry" -eq 1 ]; then group=""; after_entry=0; fi
      group="${group}${line} "; continue;;
  esac
  excl_n=$((excl_n + 1))
  after_entry=1
  if [ -z "$group" ]; then
    echo "FAIL: ${EXCLUDE_FILE}:${lineno} 사유 그룹 주석 없이 추가된 항목(직전 주석 블록이 지배해야 한다): $line"
    rc=1
    continue
  fi
  case "$group" in
    *실행처*) ;;
    *) echo "FAIL: ${EXCLUDE_FILE}:${lineno} 지배 그룹 주석에 실행처 표기 없음('왜 제외 + 어디서 실행'을 적어라): $line"; rc=1;;
  esac
done < "$EXCLUDE_FILE"
scan_signal check-bats-accounting:excludes "$excl_n"

# ── (0b) 레지스트리 상한 — 부채 천장(check-bats-style의 BB_BASELINE과 같은 성격) ──────────────────
# (0)은 *부자연스러운* 배치만 잡는다. 기존 유효 그룹 **아래**에 이어 붙이는 것은 사람이 실제로 쓸
# 자연스러운 위치이고, 적대 검토가 그 위치로 **14건을 한 번에** 조용히 제외해도 전 가드가 초록임을
# 실측했다((3)의 여유분을 정확히 소진하는 합성 공격). 상한이 그 축을 닫는다 — 늘리려면 같은 diff에서
# 이 숫자를 올려야 하고, 그건 리뷰에 보인다.
# ⚠️ 래칫이 아니라 **상한**이다: 항목을 지우는 방향(제외를 줄이는 좋은 방향)은 그냥 통과한다.
#    그래서 이 손 관리 수치의 드리프트는 단방향이고 무해하다 — 목표 상태는 0이다.
# ⚠️ **env 오버라이드를 두지 않는다.** 예전엔 `${BATS_EXCLUDE_MAX:-16}`이라 `BATS_EXCLUDE_MAX=999 make verify`
#    한 줄로 상한이 통째로 꺼졌다 — 호출부(ci.yaml·Makefile 2곳) 어디에도 보이지 않는 off-switch다.
#    바로 위 「늘리려면 … 그건 리뷰에 보인다」가 이 자리에서만 거짓이었다. 형제 처방이 같은 결론을 냈다:
#    check-bats-style.sh의 `BB_BASELINE_OVERRIDE`(소비자 0인데도 폐지) · check-doc-index.sh의
#    `README_EXEMPT_MAX=0`(상수). 상한을 올리려면 이 줄을 고쳐야 하고, 그건 diff에 남는다.
EXCL_MAX=16
if [ "$excl_n" -gt "$EXCL_MAX" ]; then
  echo "FAIL: ${EXCLUDE_FILE}: 제외 ${excl_n}건 > 상한 ${EXCL_MAX} — gate에서 테스트가 빠졌다."
  echo "  정당한 제외라면 이 상한(scripts/check-bats-accounting.sh의 EXCL_MAX 상수)을 같은 PR에서 올려라."
  echo "  제외는 부채다: CI가 안 보는 테스트는 죽어도 아무도 모른다."
  rc=1
fi

if [ "$LINT_ONLY" -eq 1 ]; then exit "$rc"; fi

# gate 도메인 = run-bats --list (공백구분 문자열로 멤버십 검사)
# ⚠️ 열거를 **변수로** — 러너가 죽으면 예전 `$( … | tr )`는 빈 GATE로 흘러 모든 파일이 '고아'가 아니라
#    '.ci-exclude 단일 소유'로 보였다(도메인이 통째로 사라져도 회계는 초록).
gate_list="$(scan_enumerate check-bats-accounting:gate ./scripts/run-bats.sh --list)" || exit 1
# ── (3) gate 도메인 바닥값 — 러너 붕괴·대량 삭제 차단 ─────────────────────────────────────────────
# (0b)가 제외 증가를 막으므로 여기는 **다른 축**을 본다: 러너 로직이 깨지거나 테스트가 대량 삭제돼
# gate가 통째로 비는 경우. 바닥값이지 래칫이 아니라 여유를 둔다(정당한 삭제는 있을 수 있다).
scan_floor check-bats-accounting:gate "$(scan_count "$gate_list")" "$(floor_of check-bats-accounting:gate 195)" || exit 1
GATE=" $(printf '%s\n' "$gate_list" | tr '\n' ' ') "
in_gate() { case "$GATE" in *" $1 "*) return 0;; *) return 1;; esac; }

# .ci-exclude 도메인 (공백구분)
EXCL=" "
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  EXCL="$EXCL$line "
done < "$EXCLUDE_FILE"
in_excl() { case "$EXCL" in *" $1 "*) return 0;; *) return 1;; esac; }

# ⚠️ 열거를 **변수로** — 자기 글롭이 비면 이 가드가 막으려던 F6 클래스(테스트가 어느 harness에도
# 안 묶여 조용히 죽음)에 **자기가 걸린다**(라이브 재현: 글롭만 비우는 셰임으로 같은 OK + rc=0).
all_bats="$(scan_enumerate check-bats-accounting:tracked git ls-files '*test_*.bats')" || exit 1
scanned="$(scan_count "$all_bats")"
scan_floor check-bats-accounting:tracked "$scanned" "$(floor_of check-bats-accounting:tracked 150)" || exit 1

# (1) 모든 추적 test_*.bats가 정확히 한 도메인
while IFS= read -r f; do
  n=0
  if in_gate "$f"; then n=$((n + 1)); fi
  case "$f" in platform/charts/app/tests/*) n=$((n + 1));; esac
  if in_excl "$f"; then n=$((n + 1)); fi
  if [ "$n" -ne 1 ]; then
    echo "FAIL: $f 가 정확히 한 도메인에 없음 (매치=$n; 0=고아, 2+=이중소유)"
    rc=1
  fi
done <<< "$all_bats"

# (2) .ci-exclude 유효성: 실재 추적 파일 & gate 미포함(제외인데 gate면 모순)
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  if ! git ls-files --error-unmatch "$line" >/dev/null 2>&1; then
    echo "FAIL: .ci-exclude 항목이 추적 파일 아님: $line"; rc=1
  fi
  if in_gate "$line"; then
    echo "FAIL: .ci-exclude 항목이 gate에도 포함(모순): $line"; rc=1
  fi
done < "$EXCLUDE_FILE"

if [ "$rc" -eq 0 ]; then echo "check-bats-accounting: 전 bats가 정확히 한 도메인(gate/chart-test/.ci-exclude) OK (${scanned}건 스캔, 제외 ${excl_n}/${EXCL_MAX}건)"; fi
exit $rc
