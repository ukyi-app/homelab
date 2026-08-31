#!/usr/bin/env bash
# 함정 원장 3종(원장 docs/traps.md · SSOT docs/traps-detail.md · AGENTS.md 한줄 인덱스)의 **4방향**
# 드리프트 가드. ①은 원장이 '강제됐다'며 가리키는 guard 파일(백틱으로 감싼, 가드 확장자로 끝나는
# 경로)이 실재하는지, ②③은 원장↔SSOT 양방향 추적, ④는 SSOT 섹션 헤드라인 ↔ AGENTS 인덱스 줄의
# **완전 일치**를 본다. 가드 파일이 삭제/리네임됐는데 원장이 enforced로 남아있는 거짓 안심을
# 차단(KD-4). doc-only 함정(guard 경로 없음)은 ①②③의 대상이 아니다(④는 전건 대상 — 인덱스는
# doc-only를 포함해 SSOT 전체를 비춘다).
# 인자로 대상 3종을 덮어쓸 수 있다(테스트용 — argc 규약은 아래). 순수 파일 검사 — 라이브 무관.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init verify-traps
cd "$ROOT"

# ⚠️ 이 파일의 멤버십 검사는 전부 `grep -Fqx -- "$x" <<<"$list"`다. **`printf … | grep -q`로 쓰지 마라.**
#    `grep -q`는 첫 매치에서 즉시 종료하는데, 그때 writer(bash printf 빌트인)가 아직 쓸 것이 남아 있으면
#    SIGPIPE로 죽고 `set -o pipefail`이 그 141을 파이프라인 rc로 채택한다 — **매치가 있었는데 FAIL**이 된다.
#    writer가 얼마나 썼는지는 스케줄링에 달려 있어 부하가 높을수록 실패율이 오른다(CI 실측: 러너가
#    bats 스위트와 발화 e2e 8건을 한 스텝에서 병렬로 돌리는 창에서 발현. 로컬 재현: CPU 부하 아래
#    30회 중 22회 red · 무부하 20회 전건 green · 최소 재현은 10000줄에 첫 줄 매치로 rc=141 직접 관측).
#    herestring은 임시 파일을 seek 가능한 fd로 붙여 파이프 자체가 없으므로 이 레이스가 원리적으로 없다.

take_floors "verify-traps:index verify-traps:ledger" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"

# ── argc 규약: 0(실 트리) 또는 3(호출자가 소유한 트리플) — 부분 지정은 없다 ─────────────────────
# 네 방향이 세 파일을 **짝으로** 읽는다(②③은 원장↔SSOT, ④는 SSOT↔인덱스). 일부만 픽스처로 바꾸면
# 남은 하나가 실 트리 파일이라 그 방향이 **의도하지 않은 이유로** 판정되고(픽스처 SSOT vs 실 인덱스는
# 언제나 불일치), 그때 유일한 회피가 "그 방향을 argc로 끈다"인데 그것이 이 가드가 닫은 fail-open
# 그 자체다. ⇒ 스코프는 원자로 좁힌다(CONTEXT.md 「가드 스코프」): 전부 실 트리이거나 전부 호출자
# 소유이거나. 부분 argc를 사용법 오류(exit 2)로 거부하는 것이 방향을 조용히 끄는 문을 없앤다.
case "$#" in
  0) LEDGER="docs/traps.md"; DETAIL="docs/traps-detail.md"; INDEX="AGENTS.md" ;;
  3) LEDGER="$1"; DETAIL="$2"; INDEX="$3" ;;
  *) echo "사용법: verify-traps.sh [<원장> <SSOT> <인덱스>] — 파일 인자는 0개(실 트리) 또는 3개다(받은 인자 $#개)" >&2
     exit 2 ;;
esac

# ⚠️ **대상 부재는 통과가 아니다.** 예전엔 ②③이 `if [ -f "$DETAIL" ]`로 감싸여 있어, SSOT가
#    삭제/리네임되면 두 방향이 통째로 건너뛰어지고도 rc=0으로 "양방향 일치 OK"를 출력했다 —
#    건너뛴 것이 아니라 **검증하지 않은 주장**이다. 세 대상 전부 LEDGER와 같은 규율로 문다.
for _vt_f in "$LEDGER" "$DETAIL" "$INDEX"; do
  [ -f "$_vt_f" ] || { echo "verify-traps: $_vt_f 없음 — 대상 부재로는 어떤 방향도 검증할 수 없다" >&2; exit 1; }
done

fail=0
# shellcheck disable=SC2016  # 백틱은 의도된 리터럴 매칭(명령 치환 아님)
paths="$(grep -oE '`[^`]+`' "$LEDGER" | tr -d '`' | grep -E '\.(bats|sh|ts|rego|mjs|ya?ml|json)$' | LC_ALL=C sort -u)"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -e "$p" ] || { echo "FAIL: 원장이 가리키는 가드 부재: $p"; fail=1; }
done <<< "$paths"

# 역방향 guard-path-tie(D3): traps-detail.md의 '> 가드:' 주석 경로가 원장(traps.md)에도 등장하는지.
# 위는 원장→가드파일 존재검사, 이건 SSOT(traps-detail.md) 가드주석→원장 추적 검사 — SSOT가 enforced라 단
# 가드를 원장이 안 따라가는 드리프트 차단. ★'> 가드:' 줄의 백틱 경로만 — 본문 prose 백틱(scripts/verify-traps.sh
# 등)은 비대상(F6: 원장 prose 경로를 SSOT에 요구하던 overbroad tie 회피).
# shellcheck disable=SC2016  # 백틱은 리터럴 매칭
# ⚠️ `|| detail_guards=""`가 **필요하다** — `> 가드:` 줄이 0건이면 첫 grep이 rc=1이고 `set -o pipefail`
#    아래에서 `set -e`가 **할당 단계에서** 스크립트를 죽인다. 그러면 아래 방향들이 아예 실행되지
#    않고 verify-traps가 **메시지 0줄에 rc=1**로 끝난다(무엇이 틀렸는지 알 수 없다).
detail_guards="$(grep -E '^> 가드:' "$DETAIL" | grep -oE '`[^`]+`' | tr -d '`' | grep -E '\.(bats|sh|ts|rego|mjs|ya?ml|json)$' | LC_ALL=C sort -u)" || detail_guards=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  grep -Fq -- "$p" "$LEDGER" || { echo "FAIL: SSOT(traps-detail.md) 가드가 원장에 부재(드리프트): $p"; fail=1; }
done <<< "$detail_guards"

# 세 번째 방향(원장 행 → SSOT 섹션): 원장의 각 행이 가리키는 가드가 traps-detail.md의 어느
# `> 가드:` 줄에도 없으면, 그 행은 **SSOT에 서사가 없는 함정을 enforced로 주장**하는 것이다.
# 원장 머리말이 스스로 "traps-detail.md가 단일 SSOT이고 이 원장은 **그중** 강제된 것만 추적한다"고
# 선언하므로, 그 주장이 참이 아니면 원장이 거짓말을 한다.
# ⚠️ 위 두 방향은 이 갭을 **원리적으로 못 본다**: ①은 파일 실재만, ②는 SSOT→원장 방향만 본다.
#    실측 2026-08-21 도입 시점에 9행이 이 상태였다(SSOT에도 AGENTS 인덱스에도 없음).
# 면제는 `where` 열에 **사유와 함께 명시**한다 — 목록이 아니라 마커라 새 행에도 같은 규칙이 적용된다:
#   `SSOT없음(불변식)`   = 함정 서사가 아니라 불변식·규약을 지키는 가드다(SSOT에 들어갈 대상이 아니다)
#   `SSOT없음(승격대상)` = 함정인데 traps-detail 서사가 아직 없다(부채를 침묵시키지 않고 계상한다)
n_rows=0
while IFS= read -r row; do
  case "$row" in '|'*) : ;; *) continue ;; esac
  case "$row" in *'|---'*) continue ;; esac
  where="$(printf '%s' "$row" | awk -F'|' '{print $3}')"
  # shellcheck disable=SC2016  # 백틱은 의도된 리터럴 매칭(명령 치환 아님)
  guards="$(printf '%s' "$row" | awk -F'|' '{print $4}' | grep -oE '`[^`]+`' | tr -d '`' | grep -E '\.(bats|sh|ts|rego|mjs|ya?ml|json)$' || true)"
  [ -n "$guards" ] || continue
  n_rows=$((n_rows + 1))
  case "$where" in *'SSOT없음('*) continue ;; esac
  hit=0
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    grep -Fqx -- "$g" <<<"$detail_guards" && { hit=1; break; }
  done <<EOF
$guards
EOF
  if [ "$hit" -eq 0 ]; then
    title="$(printf '%s' "$row" | awk -F'|' '{print $2}' | cut -c1-72)"
    echo "FAIL: 원장 행이 SSOT(traps-detail.md)에 대응 '> 가드:' 없이 enforced를 주장한다: ${title}"
    echo "      → traps-detail.md에 섹션을 쓰고 '> 가드:'를 달거나, where 열에 SSOT없음(불변식)/SSOT없음(승격대상)을 사유로 명시하라."
    fail=1
  fi
done < "$LEDGER"

# ── 네 번째 방향(SSOT 섹션 ↔ AGENTS 한줄 인덱스): 헤드라인 **완전 일치** ────────────────────────
# AGENTS.md가 스스로 "헤드라인 = traps-detail.md 섹션과 동일"을 선언하는데 ①②③은 전부 원장↔SSOT
# 사이라 이 등식을 **원리적으로 못 본다**. 실측 2026-08-29 도입 시점: 개수는 107=107인데 4건의 인덱스
# 줄이 SSOT 헤드라인에 꼬리를 덧붙인 상태였다(개수 축으로는 관측 불가 — 「표면 붕괴」와 같은 계열).
# ⚠️ **접두 일치를 허용하지 않는다.** 꼬리를 허용하면 "인덱스가 더 자세하다"는 드리프트에 사후
#    정당성을 주는 뒷문이 되고, 그 순간 이 방향이 재는 것은 등식이 아니라 접두 관계가 된다.
#    꼬리가 정보를 담고 있으면 처방은 **SSOT 헤드라인을 그만큼 늘리는 것**이다(도입 시 4건 전건 그렇게 해소).
# ⚠️ 개수 등식도 함께 본다 — 집합 대조만으로는 인덱스에 **같은 줄이 두 번** 있는 중복을 못 본다.
INDEX_SECTION='^## 라이브에서 검증된 함정'
# ⚠️ `|| x=""` 는 위 detail_guards와 같은 이유다(0건이면 pipefail+set -e가 할당 단계에서 죽인다).
index_lines="$(sed -n "/${INDEX_SECTION}/,/^## /p" "$INDEX" | grep '^- ' | sed 's/^- //')" || index_lines=""
detail_heads="$(grep '^### ' "$DETAIL" | sed 's/^### //')" || detail_heads=""
n_index="$(scan_count "$index_lines")"
n_heads="$(scan_count "$detail_heads")"

# 바닥값 — 절 제목이 바뀌어 sed 절 추출이 0건이 되면 두 방향이 **공집합끼리 일치**해 vacuous green이
# 된다(열거 붕괴). 근거: 인덱스는 함정을 지우지 않고 쌓는 원장이다 — AGENTS.md를 건드린 최근 60커밋
# 실측(2026-08-29)에서 절 불릿 수가 42→107로 **단조 비감소**(감소 0회)였다:
#   for c in $(git log --format=%h -- AGENTS.md | head -60); do \
#     git show "$c":AGENTS.md | sed -n '/^## 라이브에서 검증된 함정/,/^## /p' | grep -c '^- '; done
# 80은 오늘값의 여유를 두되 "절반이 사라져도 통과"(scan-floor 커널 주석이 금지한 상태)는 아닌 선이다.
# 픽스처 모드($# != 0)는 트리플이 호출자 소유라 면제하고 신호만 낸다(바닥값 면제 규약 — `--floor
# verify-traps:index=<n>` 명시가 면제를 되살린다).
if [ "$#" -eq 0 ] || floor_set verify-traps:index; then
  scan_floor verify-traps:index "$n_index" "$(floor_of verify-traps:index 80)" quiet || exit 1
fi

while IFS= read -r h; do
  [ -n "$h" ] || continue
  grep -Fqx -- "$h" <<<"$index_lines" || {
    echo "FAIL: SSOT 헤드라인이 AGENTS 인덱스에 없다(완전 일치 아님): $h"
    echo "      → AGENTS.md 「라이브에서 검증된 함정」절에 **같은 텍스트로** 한 줄 추가하라(꼬리를 덧붙이지 말 것)."
    fail=1; }
done <<< "$detail_heads"
while IFS= read -r l; do
  [ -n "$l" ] || continue
  grep -Fqx -- "$l" <<<"$detail_heads" || {
    echo "FAIL: AGENTS 인덱스 줄이 SSOT 섹션 헤드라인과 다르다(완전 일치 아님): $l"
    echo "      → traps-detail.md의 '### ' 헤드라인을 이 텍스트와 같게 하라(꼬리가 정보를 담으면 SSOT를 늘린다)."
    fail=1; }
done <<< "$index_lines"
if [ "$n_index" -ne "$n_heads" ]; then
  echo "FAIL: 인덱스 ${n_index}줄 != SSOT 섹션 ${n_heads}개 — 집합은 같은데 개수가 다르면 한쪽에 중복이 있다."
  fail=1
fi

# 네 방향의 판정이 끝났다 — 이제 마커를 낸다(중간에 죽으면 이 줄에 닿지 않는다).
# ⚠️ 위반(fail=1)으로 끝나는 실행도 도메인은 **평가했다** — 그래서 exit보다 앞이다
#    (tests/gates/test_scan-floor.bats가 rc 1을 "마커는 이미 방출됐다"로 읽는 계약).
scan_signal verify-traps:index "$n_index"
# 방향 ③이 실제로 순회한 원장 행 수 — 바닥값은 두지 않는다(원장 행의 정당한 감소를 이 티켓이
# 실측한 바 없다). 붕괴가 일어나면 "0행 검사 후 초록"이 신호로 보이는 것이 계상 방식이다.
scan_signal verify-traps:ledger "$n_rows"

if [ "$fail" -ne 0 ]; then echo "verify-traps: 가드 드리프트 발견" >&2; exit 1; fi
echo "verify-traps: 원장 guard 실재 + SSOT↔원장 양방향 일치 + SSOT↔AGENTS 인덱스 등식 OK"
