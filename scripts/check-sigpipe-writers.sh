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
#    ⚠️ pipefail은 **호출자 셸의 런타임 옵션**이지 파일의 텍스트 속성이 아니다 — source 전용 lib
#    (`scripts/lib/*.sh`, 자기 원문에 pipefail 리터럴이 없다)은 guard.sh:35 guard_init이 켠 pipefail
#    아래에서 실행되는데도(sops-guard.sh:24·verify-secrets.sh:22가 그 아래에서 lib을 source한다)
#    원문 토큰 검사에 걸리지 않아 구조적으로 면제됐다(실측 — 라이브 위반 0건, 잠재 fail-open).
#    처방: `*/lib/*.sh`는 원문 무관하게 스캔 대상에 넣는다(:52의 case).
# ② **다중행 writer**를 잡는다. 두 갈래다:
#    (a) 셸 빌트인 — `printf '%s\n' "$var"`(개행 포맷이라 여러 줄을 쓴다)·`echo "$var"`(변수가
#        다중행일 수 있고 정적으로 판별 불가). `printf '%s' "$scalar"`(개행 없음)는 write가 사실상
#        1회라 그대로 제외한다. 완벽한 구분은 아니지만(아주 긴 스칼라는 여러 번 쓸 수 있다) 실측된
#        위험은 전부 다중행 쪽이었고, 전면 금지로 넓히면 스칼라 검사 30여 곳까지 herestring으로
#        바꿔야 해 변경 대비 이득이 낮다.
#    (b) [c71-3 확장, 2026-09-05] 파일/명령 writer — `sed`·`awk`·`cat`·`grep`·`kubectl`·`locale`가
#        stdout에 쓴 다중행 출력을 그대로 `grep -q`에 파이프하는 형태도 같은 기전이다(외부 프로세스는
#        libc stdio 버퍼링 단위가 bash 빌트인 write보다 작아 다중 write() 확률이 더 높다). 라이브
#        실증: PR #641 gate red(`check-locale-collation.sh` 레인 D `sed … "$f" | grep -qE 'guard_init'`,
#        herestring으로 #642가 닫음). 이 판은 이 클래스를 여기 헤더에 「의도적으로 좁다」로 적어
#        두고 있었다(패턴을 넓히면 오탐이 도메인을 삼킨다는 근거) — 실제로 넓혀 레포 전역을 재검색한
#        결과 신규 오탐 0건, 대신 라이브 위반 2건(`scripts/netpol-rehearsal.sh`의 kubectl -o yaml →
#        grep -q "$NEEDLE" · `tests/gates/vmalert-meta-firing-e2e.sh`의 grep -oE → grep -q, 각 2곳
#        — 같은 커밋에서 herestring 전환)이 나와 그 축소 근거는 재검 결과 성립하지 않았다.
#        범위 밖(전수 열거 위반 0건이라 이번 확장 대상이 아님): `sops -d …`·`yq`·`jq` 등 나머지
#        외부 명령 writer — 새 라이브 사례가 나오면 이 목록에 추가한다.
# ③ 주석 줄은 대상이 아니다 — 이 파일과 traps-detail이 그 관용구를 **설명**하기 때문이다
#    (이 레포의 「규약을 설명한 파일이 그 규약에서 면제된다」 클래스를 반대로 밟지 않으려는 것).
#    ⚠️ 이 면제는 **패턴 안이 아니라 별도 단계**에서 한다(2026-09-01 정정). 종전에는 패턴 앞에
#    `^[[:space:]]*[^#].*`를 붙였는데, 그 `[^#]`가 **컬럼 0 줄의 첫 글자를 소비**해 버려
#    `printf`로 시작하는 줄을 다시 매치하지 못했다 — 같은 취약 코드가 들여쓰면 red, 들여쓰기가
#    없으면 초록이었다(뮤테이션 재현). #565/#574가 고친 21곳이 컬럼 0으로 회귀하면 아무도 못 봤다.
#    지금은 패턴을 순수하게 두고 줄-전체-주석만 사후에 걷어낸다.
#    증인은 tests/gates/test_sigpipe-writers.bats — 옛 접두를 되돌리면 컬럼 0 레그 3건이 red다.
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
  case "$f" in
    */lib/*.sh) : ;;                           # source 전용 lib — 원문 토큰 무관 스캔(위 ① 참고)
    *) grep -q 'pipefail' "$f" || continue ;;  # ①
  esac
  scanned=$((scanned + 1))
  # 패턴은 순수하게 두고(③), 줄 전체가 주석인 것만 사후에 걷어낸다 — 인라인 주석 앞의 코드는 살린다.
  # 접두를 패턴에 넣으면 컬럼 0을 놓친다(위 ③ 참조).
  hits_builtin="$(grep -nE "(printf[[:space:]]+'%s\\\\n'|echo)[[:space:]]+\"\\\$[A-Za-z_][A-Za-z0-9_]*\"[[:space:]]*\\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q" "$f" \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  # (b) [c71-3] 파일/명령 writer — 키워드 뒤 같은 파이프 세그먼트(`[^|]*`, 앞선 `|`를 넘지 않는다) 안에
  # 아무 인자가 오고 그 뒤 `grep -q`로 이어지면 잡는다. `printf '%s' "$scalar"`류는 이 키워드 목록에
  # 없어 자동으로 제외된다 — 별도 스칼라 예외가 필요 없다. 키워드 집합은 위 (b) 산문의 라이브 실증
  # 범위로 의도적으로 좁다(sops/yq/jq 등은 전수 열거 위반 0건이라 미포함).
  hits_cmd="$(grep -nE '\b(sed|awk|cat|grep|kubectl|locale)\b[^|]*\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' "$f" \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  hits="$(printf '%s\n' "$hits_builtin" "$hits_cmd" | grep -v '^$' | LC_ALL=C sort -t: -k1,1n -u || true)"
  [ -n "$hits" ] || continue
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    bad="${bad}  ${f}:${h}"$'\n'
  done <<<"$hits"
done <<<"$files"

# ⚠️ SCAN 신호를 손으로 내지 않는다 — scan_floor가 **통과 경로에서만** 낸다. 콜사이트가 따로 echo하면
#    실패 시에도 마커가 찍혀 소비자가 "검사했다"로 오독한다(이 레포의 「스캔 신호를 콜사이트가 손으로
#    내면 순서가 드리프트한다」 클래스). 바닥값도 floor_of를 거쳐 --floor 오버라이드를 받는다.
# ⚠️ 라벨은 **따옴표 없이** 쓴다 — tests/gates/test_scan-floor.bats의 정적 대조가
#    `scan_floor [a-z0-9:-]+`로 라벨을 뽑으므로, 따옴표를 씌우면 추출되지 않아 "선언은 있는데
#    방출이 없다"로 red가 난다(형제 가드 전부 따옴표 없는 관례).
scan_floor check-sigpipe-writers:files "$scanned" "$(floor_of check-sigpipe-writers:files 10)" || exit 1

if [ -n "$bad" ]; then
  echo "FAIL: pipefail 아래에서 다중행 writer를 grep -q에 파이프한다 — 매치가 있어도 SIGPIPE(141)로" >&2
  echo "      거짓 FAIL이 날 수 있고, 부하가 높을수록 실패율이 오른다(로컬이 CI를 예고하지 못한다)." >&2
  echo "      처방: \`grep -q PATTERN <<<\"\$var\"\` (herestring — 파이프가 없어 레이스가 원리적으로 사라진다)" >&2
  printf '%s' "$bad" >&2
  exit 1
fi
echo "check-sigpipe-writers OK (pipefail 셸 ${scanned}개 스캔, 다중행 writer→grep -q 파이프 0곳)"
