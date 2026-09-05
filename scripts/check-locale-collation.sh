#!/usr/bin/env bash
# 로케일 콜레이션 가드 — 게이트가 오너의 셸 로케일에 따라 **다른 술어를 평가하는** 자리를 잡는다.
#
# 병(라이브 재현 2026-08-20): glibc `en_US.UTF-8`은 구두점·공백을 1차 가중에서 무시한다. 그래서
# `sort -u`가 `-1`과 `1`을, `_create-app.yaml`과 `create-app.yaml`을 **같다고 보고 하나를 버린다.**
#   · `printf -- '-1\n1\n-2\n2\n-9\n9\n' | sort -u` → en_US 3줄 / C 6줄
#   · `git ls-files .github/workflows | sort -u`    → en_US 19 / C 24
#     (삼켜지는 5건이 정확히 `create-app`·`create-cache`·`create-database`·`teardown-app`·
#      `update-secrets` — 이 레포의 `_*.yaml`↔`*.yaml` 네이밍 규약이 곧 붕괴의 모양이다.)
# 그 결과는 거짓 red가 아니라 **fail-open**이었다: `test_sync_wave_ledger.bats`가 원장의 `-1` 행
# 삭제(=실제 드리프트)를 en_US에서 초록으로 통과시켰다. 매니페스트 쪽 `sort -u`가 `-1`을 삼켜
# 그 wave가 루프에 아예 안 들어갔기 때문이다.
#
# ⚠️ **런너 로케일 고정은 이 가드의 대체가 아니다.** 고정하면 개별 결함의 뮤테이션 감도가 죽는다
#    (실측: `Makefile`의 `LC_ALL=C sort`를 되돌려도 C.UTF-8에서는 초록). 고정은 두 venue가 같은
#    술어를 평가하게 만들 뿐이고, "다음 파일에서 또 난다"를 막는 것은 이 정적 스캐너다 —
#    bash 3.2 `$VAR한글` 함정이 쓴 것과 같은 처방(러너가 원리적으로 재현 못 하는 환경 의존은
#    정적 가드로 잡는다). cf. `docs/traps-detail.md` 「로케일 콜레이션이 게이트를 뒤집는다 …」
#
# 규칙(전부 **hard-zero** — waiver 목록 없음. 도입 시점 총 57곳이라 1회 패스로 0에 도달한다):
#   A `sort -u`  : `LC_ALL=C` 접두 또는 숫자 플래그(-n/-g/-h/-V/-R)가 없으면 위반.
#   B 명령 위치 bare `sort` : 동일 규칙.
#   C TS/JS 로케일 API(`localeCompare`·`toLocale*`·`Intl.Collator`) : 결정성이 환경/ICU에 달린다.
# ⚠️ **탐지 자신은 전부 `LC_ALL=C`다** — 가드가 로케일 의존이면 자기 모순이다.
# 인자로 파일을 주면 그 파일만 스캔한다(픽스처/ad-hoc 탐지 모드 — 바닥값 면제, 신호는 낸다).
# bash 3.2 호환: mapfile 금지(while read). shellcheck 클린.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-locale-collation
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 03 — 구 env 폐지).
take_floors "check-locale-collation" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
cd "$ROOT"

FILES=()
if [ "$#" -gt 0 ]; then FILES=("$@"); else
  while IFS= read -r f; do FILES+=("$f"); done < <(
    git ls-files '*.sh' '*.bats' 'Makefile' '*.ts' '*.mts' '.github/workflows/*.yaml' '.github/actions/*/*.yml'
  )
fi
# ⚠️ 기본 모드의 도메인은 **정당하게 0이 될 수 없다** — 0건은 열거 붕괴다(형제 가드와 같은 규율).
# 판정만 한다(quiet) — 마커는 **검출기가 살아서 끝난 뒤** 아래에서 낸다. 검출기가 죽은 실행은
# 아무것도 검사하지 못했으므로 "N건 검사했다"를 내면 소비자가 정반대로 읽는다(형제 후행 가드와 같은 규율).
if [ "$#" -eq 0 ] || floor_set check-locale-collation; then
  scan_floor check-locale-collation "${#FILES[@]}" "$(floor_of check-locale-collation 200)" quiet || exit 1
fi

DETECT=""
IFS='' read -r -d '' DETECT <<'AWK' || true
# 단일따옴표 span을 지운다 — yq/jq 표현식 안의 `sort`가 셸 명령으로 오인되지 않게(실측 오탐원 1위).
# ⚠️ 이 span 제거가 yq/jq 표현식 말고도 두 번째 하중을 진다 — printf 픽스처 리터럴을 억제한다.
#    그런데 이 레포의 지배적 관용구 `(ba)?sh -c '…'`(bats의 `run bash -c '…'` 포함)도 단일따옴표라
#    span 제거가 그 **활성 셸 코드**까지 통째로 가려 hard-zero 주장이 거짓이었다(실측 — `bash -c
#    'git ls-files | sort -u'`가 레인 A/B 양쪽에 무증인). `sh -c '…'`/`bash -c '…'` 페이로드 줄만
#    원문 그대로 두어 레인 A/B가 그 안의 sort를 계속 본다 — yq/jq 표현식·픽스처 리터럴은 이 형태가
#    아니므로 그대로 마스킹된다.
function code(l){ if (l ~ /(^|[ \t;&|(])(ba)?sh[ \t]+-c[ \t]+'/) return l; gsub(/'[^']*'/,"Q",l); return l }
FNR==1 { inhere=0; delim=""; nfiles++ }
# ⚠️ **주석 규칙이 heredoc 상태 기계보다 먼저 온다 — 순서가 곧 판정이다.**
#    뒤집으면 인용된 heredoc 표기 한 줄이 파일의 나머지를 통째로 지우고, 그 침묵은 red가 아니다.
#    착지 전 실측: 이 도메인 10파일 2,956줄이 그렇게 투명했다(그중 하나가 그 함정을 문서화한
#    회귀 픽스처 자신이다). cf. docs/traps-detail.md 「heredoc 상태 기계가 주석 규칙보다 먼저 …」
/^[ \t]*#/ { next }
/^[ \t]*\/\// { next }
# heredoc 본문은 명령이 아니다(형제 check-bats-style.sh와 같은 관용구). 이 가드 자신의 awk 프로그램이
# `<<'AWK'` 본문에 패턴 **리터럴**로 들어 있어, 이게 없으면 검출기가 자기 자신을 위반으로 잡는다.
# ⚠️ 대가: heredoc으로 **스크립트를 생성**하는 자리는 여기서 안 보인다. 그 생성물이 추적 파일이면
#    자기 차례에 검사되고, 아니면 게이트 도메인 밖이라 애초에 이 가드의 관할이 아니다.
# ⚠️ TS/MTS는 heredoc 문법이 **없다** — 표면 종류로 상태 기계를 끈다. 켜 두면 문자열 속
#    `<<id>` 같은 토큰을 delimiter로 오인해 그 지점 이후를 통째로 가린다(실측: ensure-bump-pr.ts 756줄).
FILENAME !~ /\.m?ts$/ {
  if (inhere) { if ($0 ~ ("^[ \t]*"delim"[ \t]*$")) inhere=0; next }
  hl = $0
  # `<<<` herestring은 heredoc 시작이 아니다 — match()가 **2번째** `<`부터 `<< "foo"`로 읽어
  # delim="foo"를 세우고 그 뒤 파일 전체가 투명해진다(실측). 이 레포는 `done <<< "$x"`를 쓴다.
  gsub(/<<</, "@HERESTRING@", hl)
  # 산술 좌시프트 `$(( a << b ))`도 heredoc이 아니다(오인원 열거 2번).
  if (hl ~ /\$\(\(/) gsub(/<</, "@SHIFT@", hl)
  if (match(hl, /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*/)) {
    d=substr(hl,RSTART,RLENGTH); gsub(/.*<<-?[ \t]*['"]?/,"",d); delim=d; inhere=1; next
  }
}
# bats `@test "이름" {` 헤더는 **이름**이지 명령이 아니다 — 이 가드의 테스트가 픽스처 형태를
# 제목에 적는 것이 정상이고, 그걸 위반으로 세면 가드가 자기 회귀 테스트를 금지하게 된다.
/^@test[ \t]/ { next }
{
  c = code($0)
  # yq/jq의 `sort | join(...)` 필터 — 셸 명령이 아니다.
  if (c ~ /sort[ \t]*\|[ \t]*join\(/) next
  # 숫자·버전 정렬은 콜레이션 무관하므로 면제한다.
  if (c ~ /sort[ \t]+-[A-Za-z]*[nghVR]/) next
  if (c ~ /LC_ALL=C[ \t]+sort/) next
  if (c ~ /sort[ \t]+-[A-Za-z]*u/) { printf "%s:%d: [A] %s\n", FILENAME, FNR, $0; next }
  # ⚠️ 후행 문자 클래스에 `)` `}` `|` `&` `;`가 **반드시** 들어간다 — 첫 판이 `sort([ \t]|$)`였고
  #    `| sort)` 형태 10건을 놓쳐 이 레인을 13으로 과소 계수했다(열거 명령 자신의 붕괴).
  if (c ~ /(^|[|(;&{]|\$\()[ \t]*sort([ \t;)}|&]|$)/) { printf "%s:%d: [B] %s\n", FILENAME, FNR, $0; next }
  if (c ~ /localeCompare|toLocale[A-Z]|Intl\.Collator/) printf "%s:%d: [C] %s\n", FILENAME, FNR, $0
}
# 검출기가 **실제로 읽은** 파일 수를 호출자에게 알린다 — 형제 check-host-ports.sh와 같은 계약.
# awk가 중간에 죽어도 SCAN 신호(열거 수)는 그대로 나가므로, 이 축이 없으면 "몇 건을 검사했는가"가 거짓이 된다.
END { printf "READFILES=%d\n", nfiles > "/dev/stderr" }
AWK

# 검출 실행(인자 검증·rc 포착·READFILES 대조)은 detect_run(guard.sh) 소유 — 여긴 awk 본문만.
findings="$(detect_run check-locale-collation "$DETECT" "${FILES[@]}")"
# 검출기가 끝까지 돌았다 — 이제 마커를 낸다.
scan_signal check-locale-collation "${#FILES[@]}"
n="$(scan_count "$findings")"
printf '%s\n' "$findings" | grep -E '\[(A|B|C)\]' || true   # gate bats가 레인 태그를 검증
abc_rc=0
if [ "$n" -gt 0 ]; then
  echo "FAIL: 로케일 콜레이션에 물리는 정렬/비교 ${n}곳 — 셸은 'LC_ALL=C sort'(또는 -n), TS/JS는 코드유닛 비교로." >&2
  abc_rc=1   # 레인 D까지 보고한 뒤에 종료한다 — 한 실행이 두 클래스를 함께 말해야 재실행이 안 는다.
fi

# ── 레인 D: 가드 프롤로그 — scripts/ 가드류(.sh)는 guard_init를 불러야 한다(d2·11) ────────────────
# LC_ALL 전역 export는 프롤로그 커널(scripts/lib/guard.sh)이 소유한다 — 커널을 건너뛴 새 가드는
# 이 가드가 잡는 병(로케일 의존 콜레이션)의 신설 표면이라, 프롤로그 누락을 여기서 정적 red로 만든다.
# 대상 = 가드 모양 파일명 — repo-walk 'guards' 스코프의 **scripts/ 셸 부분집합**(tests/gates/*.sh와
# tools/*.ts는 대상 밖 — TS는 프롤로그 커널이 없고, 게이트 셸은 bats 하네스가 프롤로그를 진다) +
# `audit-*`(감사 가드 — 접두만 다르고 실질이 가드다: audit-orphan-pv 리뷰 실측).
# `*-gate.sh`(sealing-key-dr-gate)는 대상 밖 — source-safe lib라 guard_init의 set -euo가 호출자
# 셸을 오염시킨다(정당 제외, 파일 헤더가 근거를 진다).
# 인자 모드에선 인자 파일이 가드 모양일 때만 적용한다(픽스처 검증 경로 — 비-가드 스크립트는 관할 밖).
d_viol=""
for f in "${FILES[@]}"; do
  case "$f" in
    scripts/lib/*|*/scripts/lib/*) continue ;;   # lib은 가드가 아니라 커널 자신이다
    scripts/check-*.sh|scripts/verify-*.sh|scripts/audit-*.sh|scripts/*-guard.sh|scripts/*-check.sh) : ;;
    */scripts/check-*.sh|*/scripts/verify-*.sh|*/scripts/audit-*.sh|*/scripts/*-guard.sh|*/scripts/*-check.sh) : ;;   # 픽스처(절대경로)
    *) continue ;;
  esac
  # ⚠️ 언급이 아니라 **호출**을 센다 — 가드 머리 주석마다 "guard_init(…)이 소유한다" 산문이 있어,
  #    토큰 존재만 보면 호출 줄을 지워도 초록이다(리뷰 실측). 주석 스트립 후 행두 호출만 인정한다.
  sed 's|^[[:space:]]*#.*||' "$f" | grep -qE '^[[:space:]]*guard_init[[:space:]]' \
    || d_viol="${d_viol}${f}: [D] 가드 프롤로그 누락 — guard_init(scripts/lib/guard.sh)를 불러라(LC_ALL 전역 export·ROOT·scan-floor가 커널 소유다)"$'\n'
done
if [ -n "$d_viol" ]; then
  printf '%s' "$d_viol"
  echo "FAIL: 레인 D — guard_init 미사용 가드(프롤로그 커널 우회)" >&2
  exit 1
fi
[ "$abc_rc" -eq 0 ] || exit 1
echo "check-locale-collation: 콜레이션 의존 정렬/비교 0곳 + 가드 프롤로그 OK"
