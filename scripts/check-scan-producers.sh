#!/usr/bin/env bash
# 스캔 신호 규약의 **거부 가드** — TS 가드가 커널(`tools/lib/scan-floor.ts`)을 우회해 `SCAN:` 마커를
# **직접 출력**하면 red. 규약 SSOT는 `CONTRIBUTING.md` '가드 스캔 신호' 절이다(설계 원문 ts-scan-kernel
# §5는 git 히스토리의 docs/reviews — 병·근거는 아래 헤더가 자체 보유한다).
#
# 병: `tests/gates/test_scan-floor.bats`의 로스터 대조(정적 콜사이트 집합 == 런타임 방출 집합)는 우회를
# 막지 못한다. 정적 집합과 실행 파일 목록이 **같은 패턴**에서 파생되므로, 한 가드가 직접 `console.log`로
# 되돌아가면 양쪽에서 동시에 사라져 등식이 그대로 성립하고, 바닥값의 여유가 정확히 한 건의 손실을 덮는다
# (게이트 r1 F1 실측). 새로 추가된 직접 생산자도 같은 이유로 보이지 않는다. 인식 제거는 "안 본다"이고,
# 필요한 것은 "있으면 red"다 — 그것이 이 가드다.
#
# 대상 = 추적 `tools/**/*.ts`·`*.mts` 전량(git 열거 — 하드코딩 글롭이 리네임에 조용히 0매치되는 것을 피한다).
# 위반 = 주석을 걷어낸 코드 줄에서 **출력 동사의 인자가 마커 리터럴로 시작**하는 것:
#   `console.log("SCAN: …` · `console.info(\`SCAN: …` · `process.stdout.write('SCAN: …` · `Bun.write(Bun.stdout, "SCAN: …`
#   · 배열 형태 `console.log(["SCAN: …` · 여러 줄 호출(`console.log(` 로 끝나고 다음 코드 줄이 리터럴로 시작 —
#   이 레포의 실제 관용구라 놓치면 드리프트급이다).
#   "인자가 마커로 시작"이 선이다 — 마커를 **다루는** 코드(`/^SCAN: /` 정규식·`l.startsWith("SCAN: ")` 소비자·
#   마커 형태를 인용하는 진단문 `console.error("힌트: 'SCAN: <라벨>…'")`)는 생산자가 아니다. 이 선이 없으면
#   규약을 구현·설명하는 파일마다 자기 자신을 제외 목록에 넣어야 하고, 그 목록이 곧 아무도 대조하지 않는
#   주장이 된다(check-skip-signalling이 같은 이유로 "출력 동사 + 문자열 리터럴"을 요구한다).
#
# ⚠️ **주석 판정이 면제 판정보다 먼저다.** 함정 원장: "면제 판정이 주석보다 먼저 돌면 규약을 *설명한* 파일이
#    그 규약에서 면제된다 — 가드 자신부터". 주석 표면: `//` 줄 · 블록 주석(`/* … */`, JSDoc 포함) 본문 ·
#    코드 줄 꼬리의 `// …`(출력 동사보다 앞에 `//`가 있으면 주석으로 본다).
#    블록 주석은 **행 앞 `/*`에서만** 상태에 들어간다 — 줄 중간의 `/*`는 `"tools/*.ts"` 같은 글롭 문자열에
#    흔해서, 그것을 주석 시작으로 읽으면 파일의 나머지가 통째로 주석이 된다(함정 원장 "heredoc 상태 기계…":
#    `<<`를 문자로 보는 상태 기계는 그것이 heredoc이 아닌 경우를 전부 열거해야 한다 — 여기서는 열거하지 않고
#    진입 조건을 좁힌다). 대가: `/* x */ console.log("SCAN: …")`처럼 같은 줄 블록 주석 **뒤**의 코드와
#    `*/` 닫는 줄의 나머지는 보지 않는다(이 레포에 없는 형태).
# ⚠️ **면제는 커널 파일 경로 하나이고, 그 파일도 건너뛰지 않는다.** 커널의 코드 줄에서 나온 히트가 ≥1이어야
#    한다 — 그 히트가 "검출기가 코드를 읽고 있다"는 유일한 양성 대조다. 주석 상태 기계가 커널 독스트링을
#    지나 코드까지 삼키거나 패턴이 깨지면 "위반 0건"이 아니라 **검출기 붕괴**로 red가 난다.
#    파일 수 축(아래 READFILES·바닥값)은 줄 단위 붕괴를 원리적으로 못 본다(함정 원장 "heredoc 상태 기계…").
# ⚠️ **탐지기는 프록시다** — 드리프트(옛 관용구 복제·새 직접 생산자)를 잡는 것이 목적이지 적대 우회를 막는
#    것이 아니다(설계 §5가 AST 발견을 기각했다). 보지 않는 것: 문자열을 상수·변수·배열에 조립한 뒤 출력,
#    동사 목록 밖의 출력 경로(`writeSync(1, …)`·`console["log"]`·bind), 같은 줄 블록 주석 뒤 코드.
# ⚠️ `findings="$(awk … || true)"` 함정의 세 겹 처방을 따른다 — ① awk rc 포착(판정 불가는 통과가 아니다)
#    ② 넘기기 전 `[ -r ]` ③ READFILES를 열거 수와 대조. 그리고 바닥값·SCAN 마커는 **검출 뒤**에 낸다 —
#    검출이 죽은 실행이 "N파일 스캔"을 내면 소비자가 정반대로 읽는다(check-bats-fd0와 같은 순서).
# ⚠️ 바닥값은 **상수**다 — env 주입 경로를 열지 않는다(티켓 04: `=0` 한 줄로 required gate의 방어가
#    꺼졌다). 붕괴 관측에는 주입이 필요 없다 — `--root <dir>`에 작은 픽스처 트리를 주면 열거가 자연히
#    붕괴한다. `--root`는 되돌림 시나리오 증인(실 `tools/` 사본 + 한 파일 되돌림)을 위한 것이다.
# bash 3.2 호환(mapfile 금지). shellcheck clean.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-scan-producers

KERNEL="tools/lib/scan-floor.ts"
# 열거 붕괴 바닥값 — 추적 .ts/.mts 파일 수. ⚠️ 여기에 현재 건수를 적지 않는다(커널 주석의 규율 — 손 관리
# 수치는 드리프트한다). 현재값은 SCAN 마커를 읽어라. 래칫이 아니다: 정당하게 줄면 같이 내린다.
MIN_FILES=40

usage() { echo "사용법: check-scan-producers.sh [--root <dir>]" >&2; exit 2; }
# ROOT 기본값은 guard_init가 산출한 레포 루트 — --root는 픽스처 트리 검증용으로만 그것을 덮는다.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || usage; ROOT="$2"; shift 2 ;;
    *) echo "알 수 없는 옵션: $1" >&2; usage ;;
  esac
done
cd "$ROOT"

# 열거 — 프로세스 치환이 아니라 커널 경유(열거자 rc가 전파된다).
listing="$(scan_enumerate check-scan-producers git ls-files -- 'tools/*.ts' 'tools/*.mts')" || exit 1
n="$(scan_count "$listing")"
FILES=()
missing=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # ② 넘기기 전에 읽기 가능성을 검증한다 — 읽을 수 없는 파일은 gawk를 fatal로 죽이고, `continue`로
  #    건너뛰면 건수는 열거 수를 그대로 내면서 그 파일만 조용히 검사 밖이 된다.
  [ -r "$f" ] || missing="${missing} ${f}"
  FILES+=("$f")
done <<EOF
$listing
EOF
[ -z "$missing" ] || { echo "FAIL: check-scan-producers: 읽을 수 없는 대상 —${missing}" >&2; exit 1; }
[ "${#FILES[@]}" -gt 0 ] || { echo "FAIL: check-scan-producers: 열거 0건 — 판정 불가(fail-closed)." >&2; exit 1; }

# 검출기. 규칙 순서가 곧 판정 순서다 — 블록 주석 상태 → 줄 주석 → 열린 호출(pending) → 동사+리터럴.
# 출력: `<파일>:<행>: <원문>` (stdout) · `READFILES=<읽은 파일 수>` (stderr, END).
# \042=쌍따옴표 \047=홑따옴표. ⚠️ 이 프로그램 안에 홑따옴표 **문자**를 쓰면 셸 인용이 끊긴다(실측).
# shellcheck disable=SC2016  # awk 프로그램의 문자 클래스에 백틱이 있다 — 셸 확장이 아니다
DETECT='
  BEGIN {
    VERB = "(console\\.(log|info|warn|error|debug|trace)|process\\.(stdout|stderr)\\.write)"
    LIT  = "[[:space:]]*\\[?[[:space:]]*[\042\047`]SCAN: "
    OPEN = VERB "\\([[:space:]]*$"
    HIT  = "(" VERB "\\(|Bun\\.write\\([^,)]*,)" LIT
  }
  FNR == 1 { nfiles++; inblock = 0; pending = 0 }
  {
    if (inblock) { if (index($0, "*/") > 0) inblock = 0; next }
    if ($0 ~ /^[[:space:]]*\/\*/) { if (index($0, "*/") == 0) inblock = 1; next }
    if ($0 ~ /^[[:space:]]*\/\//) next
    if (pending) {
      pending = 0
      if ($0 ~ ("^" LIT)) { print FILENAME ":" FNR ": " $0; next }
    }
    if ($0 ~ OPEN) { pending = 1; next }
    if (match($0, HIT) == 0) next
    # 코드 줄 꼬리 주석 — 출력 동사보다 앞에 `//`가 있으면 그 동사는 주석 안이다.
    c = index($0, "//")
    if (c > 0 && c < RSTART) next
    print FILENAME ":" FNR ": " $0
  }
  END { printf "READFILES=%d\n", nfiles > "/dev/stderr" }
'
errlog="$(mktemp)"
trap 'rm -f "$errlog"' EXIT
arc=0
findings="$(awk "$DETECT" "${FILES[@]}" 2>"$errlog")" || arc=$?
if [ "$arc" -ne 0 ]; then
  # ① 검출기 사망은 "매치 0건"이 아니다 — `|| true`로 삼키면 "0건 OK"가 된다.
  echo "FAIL: check-scan-producers: 검출기가 실패했다(awk rc=${arc}) — 판정 불가는 '통과'가 아니다." >&2
  grep -v '^READFILES=' "$errlog" >&2 || true
  exit 1
fi
read_files="$(sed -n 's/^READFILES=//p' "$errlog")"
# ③ 실제로 읽은 파일 수 == 열거 수. SCAN 신호는 "열거한" 수라 검출이 중간에 무너져도 그대로 나간다.
if [ "${read_files:-0}" -ne "$n" ]; then
  echo "FAIL: check-scan-producers: 검출기가 읽은 파일 ${read_files:-0}건 != 열거 ${n}건 — 판정 불가(fail-closed)." >&2
  exit 1
fi
# 바닥값 + SCAN 마커 — 검출이 살아 있음을 확인한 **뒤**에 낸다.
scan_floor check-scan-producers "$n" "$MIN_FILES" || exit 1

# 면제 판정은 **여기**(주석을 걷어낸 코드 히트에 대해)다 — 파일 단위 건너뛰기가 아니다.
kernel_hits="$(printf '%s\n' "$findings" | grep -c "^${KERNEL}:" || true)"
viol="$(printf '%s\n' "$findings" | grep -v "^${KERNEL}:" | grep -v '^$' || true)"

rc=0
if [ "$kernel_hits" -lt 1 ]; then
  echo "FAIL: check-scan-producers: 검출기 붕괴 — 커널 ${KERNEL}의 코드 줄에서 생산자 히트 0건. 주석 상태 기계·패턴이 코드를 못 읽고 있다(위반 0건은 판정이 아니다)." >&2
  rc=1
fi
if [ -n "$viol" ]; then
  echo "FAIL: check-scan-producers: 커널 우회 직접 생산자 — 스캔 마커는 tools/lib/scan-floor.ts(scanFloor·scanSignal)만 낸다:" >&2
  printf '%s\n' "$viol" >&2
  rc=1
fi
if [ "$rc" -eq 0 ]; then
  echo "check-scan-producers: 커널 우회 직접 생산자 0건 OK (${n}파일 스캔 · 커널 생산자 ${kernel_hits}건)"
fi
exit "$rc"
