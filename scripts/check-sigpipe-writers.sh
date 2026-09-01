#!/usr/bin/env bash
# SIGPIPE 거짓 FAIL 가드 — `set -o pipefail`을 켠 셸에서 **다중행 writer**를 `grep -q`에 파이프하면
# 매치가 있었는데도 파이프라인이 141로 끝날 수 있다.
#
# 기전(docs/traps-detail.md 「`grep -q`의 조기 종료가 pipefail 아래에서 writer를 SIGPIPE로 죽인다」):
#   `grep -q`는 **첫 매치에서 즉시 종료**한다. 그때 writer가 아직 쓸 것이 남아 있으면 SIGPIPE로 죽고,
#   `pipefail`이 그 141(=128+13)을 파이프라인 rc로 채택한다. 판정이 뒤집히는 게 아니라 판정 자체가
#   종료코드에 삼켜진다. writer가 몇 번 write()를 끝냈는지는 스케줄링에 달려 있어 **부하가 높을수록**
#   실패율이 오른다 — 그래서 로컬이 CI를 예고하지 못한다(PR #565: 부하 아래 30회 중 22회 red,
#   무부하 20회 전건 green).
#
# ⇒ 처방은 herestring이다: `grep -q PATTERN <<<"$var"`. bash가 임시 파일을 seek 가능한 fd로 붙이므로
#   파이프 자체가 없고 이 레이스가 원리적으로 사라진다.
#
# ── 판정 범위(의도적으로 좁다) ────────────────────────────────────────────────────────────────────
# ① `pipefail`을 켠 파일만 본다. bats는 pipefail을 켜지 않아 같은 관용구가 거기선 안전하다.
# ② **다중행 writer만** 잡는다:
#      - `printf '%s\n' "$var"`  — 개행 포맷이라 여러 줄을 쓴다
#      - `echo "$var"`           — 변수가 다중행일 수 있고 정적으로 판별 불가하다
#    `printf '%s' "$scalar"`(개행 없음)는 write가 사실상 1회라 제외한다. 완벽한 구분은 아니지만
#    (아주 긴 스칼라는 여러 번 쓸 수 있다) 실측된 위험은 전부 다중행 쪽이었고, 전면 금지로 넓히면
#    스칼라 검사 30여 곳까지 herestring으로 바꿔야 해 변경 대비 이득이 낮다.
# ③ 주석 줄은 대상이 아니다 — 이 파일과 traps-detail이 그 관용구를 **설명**하기 때문이다
#    (이 레포의 「규약을 설명한 파일이 그 규약에서 면제된다」 클래스를 반대로 밟지 않으려는 것).
#
# 종료코드: 0=위반 없음 · 1=위반 · 2=사용법/전제 붕괴
set -euo pipefail
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-sigpipe-writers
cd "$ROOT"

take_floors "check-sigpipe-writers:files" "$@" || exit $?

files="$(git ls-files '*.sh')"
[ -n "$files" ] || { echo "check-sigpipe-writers: 추적된 .sh가 0건 — 열거 붕괴다" >&2; exit 2; }

scanned=0
bad=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  grep -q 'pipefail' "$f" || continue          # ①
  scanned=$((scanned + 1))
  # 주석(③) 제거 후 판정한다. 줄 전체가 주석인 것만 걷어낸다 — 인라인 주석 앞의 코드는 살려야 한다.
  hits="$(grep -nE "^[[:space:]]*[^#].*(printf[[:space:]]+'%s\\\\n'|echo)[[:space:]]+\"\\\$[A-Za-z_][A-Za-z0-9_]*\"[[:space:]]*\\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q" "$f" || true)"
  [ -n "$hits" ] || continue
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    bad="${bad}  ${f}:${h}"$'\n'
  done <<<"$hits"
done <<<"$files"

# ⚠️ SCAN 신호를 손으로 내지 않는다 — scan_floor가 **통과 경로에서만** 낸다. 콜사이트가 따로 echo하면
#    실패 시에도 마커가 찍혀 소비자가 "검사했다"로 오독한다(이 레포의 「스캔 신호를 콜사이트가 손으로
#    내면 순서가 드리프트한다」 클래스). 바닥값도 floor_of를 거쳐 --floor 오버라이드를 받는다.
scan_floor "check-sigpipe-writers:files" "$scanned" "$(floor_of check-sigpipe-writers:files 10)" || exit 1

if [ -n "$bad" ]; then
  echo "FAIL: pipefail 아래에서 다중행 writer를 grep -q에 파이프한다 — 매치가 있어도 SIGPIPE(141)로" >&2
  echo "      거짓 FAIL이 날 수 있고, 부하가 높을수록 실패율이 오른다(로컬이 CI를 예고하지 못한다)." >&2
  echo "      처방: \`grep -q PATTERN <<<\"\$var\"\` (herestring — 파이프가 없어 레이스가 원리적으로 사라진다)" >&2
  printf '%s' "$bad" >&2
  exit 1
fi
echo "check-sigpipe-writers OK (pipefail 셸 ${scanned}개 스캔, 다중행 writer→grep -q 파이프 0곳)"
