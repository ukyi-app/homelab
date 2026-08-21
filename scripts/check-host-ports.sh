#!/usr/bin/env bash
# 호스트 포트 위생 가드 — 게이트 하네스가 호스트 포트를 **리터럴로 박는** 자리를 잡는다.
#
# 병(라이브 실측 2건, 둘 다 red가 아니라 **오진**으로 나타났다):
#   ① `tests/gates/alertmanager-render-e2e.sh`가 telegram mock을 `8089`에 `&`로 띄웠다. background job의
#      종료코드는 `set -euo pipefail`이 보지 않으므로 EADDRINUSE(98)로 즉사해도 하네스는 그냥 진행하고,
#      30초 뒤 `no telegram capture within timeout` + AM 로그 tail로 죽는다 — **진단이 포트가 아니라
#      메시지 템플릿을 가리킨다.** 트레이스백은 그 로그 60줄 위에 있다.
#   ② 같은 파일이 AM을 `-p 9093:9093`으로 열었다. 점유돼 있으면 readiness 30초를 태운 뒤
#      `AM not ready`(원인이 로그 어디에도 없다). 게다가 접두 없는 `-p N:M`은 **전 인터페이스**에 연다.
# PR #521이 vmalert 하네스에서 같은 클래스를 닫았는데, 그 처방이 `lib/vmalert-e2e.sh` **안에** 갇혀 있어
# 형제 표면 셋(9093·8089·18443)은 원리적으로 그 처방을 못 받았다. 열거 붕괴가 아니라 **열거 범위가
# 좁았다** — 그때의 완전성 가드는 `vmalert-*-firing-e2e.sh` 글롭만 봤다.
#
# ⇒ 규칙(전부 **hard-zero** — waiver 목록 없음. 도입 시점 위반 0곳이라 유지만 하면 된다):
#   A publish 인자의 **호스트 포트**가 리터럴 : `-p 9093:9093`·`-p 127.0.0.1:9093:9093` 형태. 호스트
#     포트는 `hp_pick_port`가 준 변수여야 한다(컨테이너 쪽 포트는 리터럴이 정상이다 — 그건 이미지 계약이다).
#   B 호스트 리스너 헬퍼를 **리터럴 포트 인자**로 기동 : `mock-telegram.py`·`tcp-blackhole-sink.py`.
#   C 위 둘 중 하나를 하는 파일이 `lib/host-port.sh`를 **안 쓴다** : 배정을 안 받았다는 뜻이다.
#   D 포트 변수를 **자기가 리터럴로** 채운다 : `PORT=18443` 뒤에 `"$PORT"`로 쓰면 A·B가 침묵한다.
#     밴드 상수의 정의처인 `HP_` 이름공간만 면제다(파일 목록이 아니라 이름공간 규칙이다).
#
# 도메인은 `tests/gates/**`의 추적 `.sh`다. 프로덕션 실행자(`scripts/backup-files-data.sh`의
# `kubectl port-forward`)는 **의도적으로 밖**이다 — 거긴 CI 게이트가 아니라 systemd 실행자이고 실패
# 의미론(fail-open WARN + FilesBackupStale 위임)이 다르다. 그 표면은 별도 티켓이다.
# ⚠️ 탐지 자신은 전부 `LC_ALL=C`다 — 가드가 로케일 의존이면 자기 모순이다(#514).
# 인자로 파일을 주면 그 파일만 스캔한다(픽스처/ad-hoc 탐지 모드 — 바닥값 면제, 신호는 낸다).
# bash 3.2 호환: mapfile 금지(while read). shellcheck 클린.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib/scan-floor.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/scan-floor.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FILES=()
if [ "$#" -gt 0 ]; then FILES=("$@"); else
  enumerated="$(scan_enumerate check-host-ports git ls-files 'tests/gates/*.sh' 'tests/gates/lib/*.sh')" || exit 1
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done <<EOF
$enumerated
EOF
fi
# ⚠️ 기본 모드의 도메인은 **정당하게 0이 될 수 없다** — 0건은 열거 붕괴다(형제 가드와 같은 규율).
if [ "$#" -eq 0 ]; then
  scan_floor check-host-ports "${#FILES[@]}" "${HOSTPORT_MIN_SCAN:-10}" || exit 1
else
  scan_signal check-host-ports "${#FILES[@]}"
fi

DETECT=""
IFS='' read -r -d '' DETECT <<'AWK' || true
# ⚠️ **파일 경계 리셋이 맨 앞에 온다.** 주석 스킵(`/^[ \t]*#/ {next}`)을 위에 두면 모든 셸 스크립트의
#    셔뱅이 거기 먼저 걸려 `next` 하므로 `FNR==1` 블록이 **단 한 번도 실행되지 않는다**(실측: 프로브를
#    심어 15파일을 돌렸는데 0회). 그러면 heredoc 상태가 파일 경계를 넘어 새어, 상태가 열린 채 끝난
#    파일 뒤의 **모든 파일이 통째로 무검사**가 되고 가드는 초록을 낸다. 형제 check-locale-collation.sh는
#    리셋을 위에 두어 이 자리를 안 밟는다 — 그 관용구를 뒤집어 옮긴 것이 결함이었다.
function flush_prev() {
  if (prevfile != "" && inhere) {
    printf "%s:%d: [E] heredoc이 파일 끝까지 닫히지 않았다(delimiter=%s) — 그 지점 이후가 검출기에게 통째로 투명해진다\n", prevfile, herestart, delim
    bad = 1
  }
}
# 행간 주석을 잘라낸다(레인 C 전용). `#`이 문자열 안에 있으면 과하게 자르지만, 그 방향은 "배정을 받았다고
# 인정하지 않는" 쪽이라 안전하다.
function nocomment(l) { sub(/[ \t]#.*$/, "", l); return l }

FNR==1 { flush_prev(); inhere=0; delim=""; herestart=0; prevfile=FILENAME; nfiles++ }

# ── heredoc 상태 기계 ────────────────────────────────────────────────────────────
{
  hl = $0
  # `<<<` herestring을 heredoc 시작으로 오인하지 않는다 — `match()`가 2번째 `<`부터 `<< "foo"`로 읽어
  # delim="foo"를 잡고, 그 뒤 파일 전체가 투명해진다(실측). 이 레포는 `done <<< "$x"` 스타일을 쓴다.
  gsub(/<<</, "@HERESTRING@", hl)
  # 산술 좌시프트 `$(( a << b ))`도 heredoc이 아니다.
  if (hl ~ /\$\(\(/) gsub(/<</, "@SHIFT@", hl)
  if (inhere) { if ($0 ~ ("^[ \t]*"delim"[ \t]*$")) inhere=0; next }
  if (match(hl, /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*/)) {
    d=substr(hl,RSTART,RLENGTH); gsub(/.*<<-?[ \t]*['"]?/,"",d); delim=d; inhere=1; herestart=FNR; next
  }
}

# 줄 머리 주석은 명령이 아니다 — 이 레포의 하네스는 자기가 고친 함정을 **인용하며 설명**하므로
# (`-p 9093:9093`가 주석에 리터럴로 남아 있다) 이게 없으면 검출기가 문서를 위반으로 잡는다.
/^[ \t]*#/ { next }

# ── [A] publish 인자의 호스트 포트가 리터럴인가 ──────────────────────────────────────
# ⚠️ `match()`로 줄당 첫 `-p` 하나만 보면 안 된다 — 한 줄에 publish가 둘이면 두 번째가 통과하고,
#    `--publish`·`-p9093:9093`(붙임형)은 아예 안 보인다. 셋 다 docker/podman 정상 문법이다.
#    그래서 **토큰을 전부 훑는다.** [C]의 binds도 여기서만 세우므로, A가 못 보면 C까지 함께 꺼진다.
{
  nt = split($0, tk, /[ \t]+/)
  for (i = 1; i <= nt; i++) {
    cand = ""
    if (tk[i] == "-p" || tk[i] == "--publish") { cand = tk[i+1] }
    else if (tk[i] ~ /^-p./)                   { cand = substr(tk[i], 3) }
    else if (tk[i] ~ /^--publish=/)            { cand = substr(tk[i], 11) }
    if (cand == "") continue
    gsub(/^["']|["'].*$/, "", cand)
    np = split(cand, part, ":")
    # ⚠️ **콜론이 없으면 publish 인자가 아니다.** 이 조건이 없으면 `mkdir -p "$tmp/bin"`의 `-p`를
    #    publish로 읽어 그 파일을 [C]로 오탐한다(실측 — 도입 때 app-shared-node-smoke.sh가 걸렸다).
    if (np < 2) continue
    binds[FILENAME] = 1
    host = (np >= 3) ? part[2] : part[1]
    if (host ~ /^[0-9]+$/) {
      printf "%s:%d: [A] publish 호스트 포트가 리터럴(%s): %s\n", FILENAME, FNR, host, $0
      bad = 1
    }
  }
}
# ── [B] 호스트 리스너 헬퍼를 리터럴 포트로 기동하는가 ────────────────────────────────
# 헬퍼 토큰 **뒤에 오는** 인자만 본다. 줄 어디의 정수나 세면 `timeout 30 python3 …mock-telegram.py`
# 같은 정상 코드를 오탐한다(양방향으로 틀리면 아무도 이 가드를 안 켠다).
{
  nt = split($0, tk, /[ \t]+/)
  seen = 0
  for (i = 1; i <= nt; i++) {
    if (tk[i] ~ /mock-telegram\.py|tcp-blackhole-sink\.py/ || tk[i] ~ /^["']?\$\{?SINK\}?["']?$/) {
      binds[FILENAME] = 1; seen = i; continue
    }
    if (seen && i > seen) {
      a = tk[i]; gsub(/^["']|["'&;)]+$/, "", a)
      if (a ~ /^[0-9]{2,5}$/) {
        printf "%s:%d: [B] 리스너 헬퍼를 리터럴 포트로 기동: %s\n", FILENAME, FNR, $0
        bad = 1
        break
      }
    }
  }
}
# ── [D] 포트 변수를 **자기가 리터럴로** 채우는가 ────────────────────────────────────
# A·B는 리터럴이 명령줄에 직접 나타난 자리만 본다. `PORT=18443` 뒤에 `"$PORT"`로 쓰면 셋 다 침묵하는데
# (실측: 예전 skopeo 스모크가 정확히 그 모양이었고 [C]가 우연히 잡았을 뿐이다) 결과는 같은 고정 포트다.
# ⚠️ 선언 키워드(local/readonly/declare/typeset/export)와 **소문자 이름**을 전부 받는다 — 이 레포의
#    하네스 관용구가 실제로 `local … port …`다(vmalert-e2e.sh). 대문자만 보면 그 관용구가 사각이다.
# ⚠️ `${VAR:-18443}` 기본값 형태도 리터럴 고정이다.
# ⚠️ `HP_` 이름공간은 면제다 — 밴드 상수의 **정의처**라 리터럴이 정상이고, 거기가 유일한 정의처라는
#    것이 lib의 계약이다. 파일 목록이 아니라 **이름공간** 규칙이라 새 파일에도 그대로 적용된다.
# ⚠️ 줄 머리 앵커 하나로는 `f(){ local port=18443; … }`처럼 **한 줄에 뭉친** 형태를 놓친다(실측).
#    함수 정의 접두를 걷어내고 `;`로 쪼갠 **세그먼트마다** 판정한다. `{`로는 쪼개지 않는다 —
#    `${VAR:-18443}` 기본값 형태가 갈라져 그 축을 잃는다.
{
  dl = $0
  sub(/^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\{[ \t]*/, "", dl)
  nd = split(dl, dseg, /;/)
  for (di = 1; di <= nd; di++) {
    if (dseg[di] ~ /^[ \t]*((export|local|readonly|typeset|declare)([ \t]+-[A-Za-z]+)*[ \t]+)?[A-Za-z0-9_]*[Pp][Oo][Rr][Tt][A-Za-z0-9_]*=(["']?[0-9]+|["']?\$\{[A-Za-z0-9_]+:-[0-9]+\})/) {
      if (dseg[di] !~ /^[ \t]*((export|local|readonly|typeset|declare)([ \t]+-[A-Za-z]+)*[ \t]+)?HP_/) {
        printf "%s:%d: [D] 포트 변수를 리터럴로 채운다: %s\n", FILENAME, FNR, $0
        bad = 1
        break
      }
    }
  }
}
# ── [C] 호스트 포트를 잡는 파일이 배정 lib을 쓰는가(파일 단위) ──────────────────────
# publish·헬퍼 쪽 binds는 위 [A]·[B] 블록이 표시했다(판정을 두 벌로 두면 갈린다).
# ⚠️ **행간 주석은 배정으로 치지 않는다.** 텍스트 등장만 보면 "host-port.sh 라고 적기만 해도" 통과해
#    마지막 방어선이 주석 한 줄로 무너진다.
{ if (nocomment($0) ~ /host-port\.sh|hp_pick_port/) used[FILENAME] = 1 }

END {
  flush_prev()
  for (f in binds) {
    if (used[f] != 1) {
      printf "%s:0: [C] 호스트 포트를 잡는데 lib/host-port.sh를 쓰지 않는다(배정을 안 받았다)\n", f
      bad = 1
    }
  }
  # 검출기가 실제로 읽은 파일 수를 **호출자에게 알린다** — SCAN 신호가 "열거한 파일 수"이면
  # awk가 중간에 죽어도 그 수가 그대로 나가 "몇 건을 검사했는가"라는 신호의 계약이 깨진다.
  printf "READFILES=%d\n", nfiles > "/dev/stderr"
}
AWK

# ⚠️ **인자를 먼저 검증한다.** 존재하지 않거나 읽을 수 없는 파일이 awk로 가면 gawk는 fatal로 즉시
#    죽는데, 예전 코드는 그 rc를 `|| true`로 버려 "리터럴 0곳 OK" rc=0을 냈다 — 가드 본체가 fail-open
#    이었다. 이 스크립트는 `cd "$ROOT"`를 하므로 호출자 cwd 기준 상대경로 인자가 곧바로 그 경로였다.
missing=""
for f in "${FILES[@]}"; do
  [ -r "$f" ] || missing="${missing} ${f}"
done
[ -z "$missing" ] || {
  echo "FAIL: check-host-ports: 읽을 수 없는 대상 —${missing} (이 스크립트는 레포 루트로 cd한다 — 상대경로 인자는 루트 기준이다)" >&2
  exit 1
}

errlog="$(mktemp)"
trap 'rm -f "$errlog"' EXIT
arc=0
findings="$(awk "$DETECT" "${FILES[@]}" 2>"$errlog")" || arc=$?
if [ "$arc" -ne 0 ]; then
  echo "FAIL: check-host-ports: 검출기가 실패했다(awk rc=${arc}) — 판정 불가는 '통과'가 아니다." >&2
  cat "$errlog" >&2
  exit 1
fi
# 검출기가 **실제로 읽은** 파일 수를 열거 수와 대조한다. SCAN 신호가 "열거한 파일 수"이기만 하면
# 검출이 중간에 무너져도 그 수가 그대로 나가 "몇 건을 검사했는가"라는 신호의 계약(scan-floor 헤더)이
# 깨진다 — 열거 붕괴 바닥값은 파일 **개수**만 보므로 이 축을 원리적으로 못 본다.
read_files="$(sed -n 's/^READFILES=//p' "$errlog" | head -1)"
case "$read_files" in
  '' | *[!0-9]*)
    echo "FAIL: check-host-ports: 검출기가 읽은 파일 수를 보고하지 않았다(READFILES 부재) — 검출기가 끝까지 돌지 않았다." >&2
    cat "$errlog" >&2
    exit 1 ;;
esac
[ "$read_files" -eq "${#FILES[@]}" ] || {
  echo "FAIL: check-host-ports: 열거 ${#FILES[@]}파일 != 검출기가 읽은 ${read_files}파일 — 스캔이 중간에 무너졌다." >&2
  exit 1
}
grep -v '^READFILES=' "$errlog" >&2 || true

n="$(scan_count "$findings")"
printf '%s\n' "$findings" | grep -E '\[(A|B|C|D|E)\]' || true   # gate bats가 레인 태그를 검증
if [ "$n" -gt 0 ]; then
  echo "FAIL: 리터럴 호스트 포트 ${n}곳 — 포트는 tests/gates/lib/host-port.sh의 hp_pick_port로 배정받아라." >&2
  exit 1
fi
echo "check-host-ports: 리터럴 호스트 포트 0곳 OK (스캔 ${#FILES[@]}파일)"
