#!/usr/bin/env bash
# 전 bats 도메인 accounting 가드 (F6 클래스 차단 — 테스트가 어느 harness에도 안 묶여 조용히 죽음).
# 모든 추적 test_*.bats는 **정확히 한 도메인**에 배정돼야 한다:
#   ① gate        — scripts/run-bats.sh --list 에 포함(required gate가 수집·실행)
#   ② chart-test  — platform/charts/app/tests/ 하위(make chart-test 별도 harness)
#   ③ .ci-exclude — not-CI-safe 레지스트리(주석이 실행처 iac/manual/age/docker 명시)
# 매치 수 ≠ 1 → 실패(0=고아, 2+=이중소유). + .ci-exclude 유효성: (a) git-tracked 실재, (b) gate 미포함(모순),
# (c) 사유 그룹 주석 지배 + 실행처 표기 **및 그 venue의 실재**, (d) 레지스트리 상한.
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
#   · 그리고 그 표기가 지목한 venue가 **실재해야 한다**(아래 venue_derive). 예전엔 이 자리가
#     "텍스트 계약이지 증명이 아니다"라고 스스로 적어 둔 구멍이었다 — 단어만 있으면(「실행처: 그냥
#     어딘가에서」) 통과했고, 없는 타깃을 적어도(「make no-such-target」) 통과했다(실측 2026-09-03).
#     증가를 **묶는 것은 아래 (0b) 상한**이고, 이 계약은 표기가 실물을 가리키게 한다.
# ── 실행처 표기 → **실재하는 venue** 파생 ────────────────────────────────────────
# 인식 형태 셋이고, 그룹에 하나라도 **실재하는** 토큰이 있으면 그 그룹은 증명된다:
#   ① make <타깃>   → Makefile에 ^<타깃>: 실재
#   ② bats <경로>   → 그 경로 실재
#   ③ .github/workflows/<파일>.ya?ml → 그 파일 실재
# ⚠️ ①②의 인용 부호는 **백틱과 작은따옴표 둘 다** 받는다 — 레지스트리가 실제로 둘을 섞어 쓴다
#    (실측: 대부분은 백틱이고 KSOPS 그룹만 작은따옴표). 표기를 한쪽으로 통일하는 규약은 없고,
#    있어도 다음 편집자가 다시 섞는다 — 표기를 좁히는 것보다 파서를 넓히는 쪽이 정직하다.
# ⚠️ 인용 구간 밖의 맨 텍스트는 ①②에서 **안 본다** — 산문의 「make 어쩌구」가 venue 행세를 하면
#    이 가드가 자기 도메인의 표기에 눈멀어 다시 텍스트 계약이 된다. ③는 경로 자체가 식별자라 인용을 안 묻는다.
# ⚠️ **인식 0건은 red다** — 부재가 아니라 존재 판정이라 방향이 반대다. 그래서 아래 `|| true`는
#    「`findings="$(awk … || true)"`」의 fail-open과 다르다: 추출기가 깨지면 전 그룹이 red로 간다.
VENUE_OK=0
VENUE_TOKENS=""
venue_derive() {
  VENUE_OK=0
  VENUE_TOKENS=""
  # 백틱을 작은따옴표로 정규화한 뒤 인용 구간만 뽑는다('\140' = 백틱의 8진 표기 — 리터럴로
  # 적으면 큰따옴표 안에서 명령 치환이 된다).
  _vd_spans="$(printf '%s' "$1" | tr '\140' "'" | grep -oE "'[^']*'" | tr -d "'" || true)"
  while IFS= read -r _vd_s; do
    case "$_vd_s" in
      'make '*)
        _vd_t="${_vd_s#make }"; _vd_t="${_vd_t%% *}"
        VENUE_TOKENS="${VENUE_TOKENS}[make ${_vd_t}] "
        if grep -qE "^${_vd_t}:" Makefile; then VENUE_OK=$((VENUE_OK + 1)); fi ;;
      'bats '*)
        _vd_p="${_vd_s#bats }"; _vd_p="${_vd_p%% *}"
        VENUE_TOKENS="${VENUE_TOKENS}[bats ${_vd_p}] "
        if [ -e "$_vd_p" ]; then VENUE_OK=$((VENUE_OK + 1)); fi ;;
    esac
  done <<VDEOF
$_vd_spans
VDEOF
  _vd_wfs="$(printf '%s' "$1" | grep -oE '\.github/workflows/[A-Za-z0-9._-]+\.ya?ml' || true)"
  while IFS= read -r _vd_w; do
    [ -n "$_vd_w" ] || continue
    VENUE_TOKENS="${VENUE_TOKENS}[${_vd_w}] "
    if [ -f "$_vd_w" ]; then VENUE_OK=$((VENUE_OK + 1)); fi
  done <<VDEOF
$_vd_wfs
VDEOF
}

excl_n=0
group=""
group_head=""
after_entry=0
lineno=0
while IFS= read -r line; do
  lineno=$((lineno + 1))
  case "$line" in
    '') group=""; group_head=""; after_entry=0; continue;;
    \#*)
      if [ "$after_entry" -eq 1 ]; then group=""; group_head=""; after_entry=0; fi
      if [ -z "$group" ]; then group_head="$line"; fi
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
    *실행처*)
      venue_derive "$group"
      if [ "$VENUE_OK" -eq 0 ]; then
        echo "FAIL: ${EXCLUDE_FILE}:${lineno} 실행처 표기가 가리키는 venue가 0건 실재(단어만 있고 증명이 없다): $line"
        echo "  그룹 첫 줄: ${group_head}"
        echo "  인식한 토큰: ${VENUE_TOKENS:-(없음)}"
        # shellcheck disable=SC2016  # 백틱·`^<타깃>:`는 사용법 문구의 리터럴이다(명령 치환 아님)
        echo '  인식 형태: `make <타깃>`(Makefile의 ^<타깃>:) · `bats <경로>`(경로 실재) · .github/workflows/<파일>.yaml(파일 실재) — 백틱/작은따옴표 둘 다.'
        rc=1
      fi
      ;;
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
