#!/usr/bin/env bash
# bats 단언-스타일 가드 — @test 본문에서 '마지막 명령이 아닌'(중간) 부정(`! `)·조건(`[[ `)을 잡는다.
# bats는 negated/[[ 명령의 실패를 errexit/ERR-trap 면제로 침묵 통과시킨다(라이브 확증: bats 1.13에서
# 중간 `! echo x|grep -q x`가 'ok'). 그런 중간 단언은 죽은(false-green) 가드다.
#   NEG(중간 `! `)  = 모든 bash에서 발생(negated pipeline은 set -e 면제) → hard-zero.
#   BB (중간 `[[ `) = bash 3.2 함정 변종 — **0 수렴 완료**, 이제 hard-zero다.
#     실증: bats 1.13에서 `[[ "$x" == *ABSENT* ]]`가 거짓인데 ok. 같은 자리를
#     `printf '%s' "$x" | grep -qF …`로 바꾸면 정확히 red가 난다(변환 전 53건은 전부 죽은 단언이었다).
# 휴리스틱: 다줄 @test 규약 가정("@test … {" 한 줄 시작, 0열 "}" 종료). heredoc 본문은 명령으로 안 센다.
# (레포 단일 한줄 @test는 단일 명령이라 무해 — 신규 한줄 본문은 다줄로 작성할 것.)
# 인자로 파일을 주면 그 파일만 스캔하고 NEG·BB 아무거나 있으면 실패(픽스처/ad-hoc 탐지 모드).
# bash 3.2 호환: mapfile 금지(while read). shellcheck 클린.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-bats-style
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 03 — 구 env 폐지).
take_floors "check-bats-style" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
cd "$ROOT"
BB_BASELINE="${BB_BASELINE_OVERRIDE:-0}"   # **0 수렴 완료** — 이제 hard-zero다(NEG와 같은 규율). 신규 중간 [[ ]]는 즉시 red.
FILES=()
if [ "$#" -gt 0 ]; then FILES=("$@"); else
  while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.bats')
fi
# ⚠️ 기본 모드의 도메인(추적 *.bats)은 **정당하게 0이 될 수 없다**: 0건은 열거 붕괴다.
# (건수는 여기 적지 않는다 — 손 관리 수치는 반드시 드리프트한다, scan-floor.sh 규약.)
# 여기에 skip 규약(exit 4 + `SKIP:`)을 쓰면 같은 `git ls-files '*.bats'` 도메인을 쓰는
# check-skeleton·check-bats-accounting(둘 다 바닥값 + exit 1)과 **정반대 신호**가 된다 —
# 커널 주석(lib/scan-floor.sh)이 "마커를 내면 사람이 정반대 뜻으로 읽는다"고 금지한 채널 혼동이다.
# 명시-파일 모드($# > 0)는 원소가 항상 ≥1이라 이 분기에 도달하지 않지만, 픽스처가 1건짜리로
# 부를 수 있으므로 바닥값은 기본 모드에만 건다(선례: check-app-netpol의 --root 면제). 래칫 아님.
if [ "$#" -eq 0 ] || floor_set check-bats-style; then
  scan_floor check-bats-style "${#FILES[@]}" "$(floor_of check-bats-style 150)" || exit 1
else
  scan_signal check-bats-style "${#FILES[@]}"   # 바닥값 면제 모드도 신호는 낸다(06 판별자)
fi
DETECT=""
IFS='' read -r -d '' DETECT <<'AWK' || true
function flush(){ if(pend!=""){ print pend; pend="" } }
FNR==1 { intest=0; pend=""; inhere=0; delim=""; nfiles++ }
{
  line=$0
  if (inhere){ if(line ~ ("^[ \t]*"delim"[ \t]*$")) inhere=0; next }
  # ⚠️ **주석 스킵이 heredoc 매치보다 먼저 온다 — 순서가 곧 판정이다.** 뒤집으면 인용된 heredoc
  #    표기 한 줄이 @test의 나머지를 통째로 지우고, 그 침묵은 red가 아니다(형제
  #    check-locale-collation.sh와 같은 결함 — 착지 전 실측 이 도메인 5파일 602줄).
  #    아래 intest 본문의 `t ~ /^#/`는 intest 판정 **뒤**라 heredoc 매치에 원리적으로 닿지 못한다.
  if (line ~ /^[ \t]*#/) next
  hl = line
  # `<<<` herestring은 heredoc 시작이 아니다 — match()가 **2번째** `<`부터 `<< "foo"`로 읽는다.
  # (형제 check-host-ports.sh·check-locale-collation.sh와 같은 관용구 — 오인원 열거 1번.)
  gsub(/<<</, "@HERESTRING@", hl)
  # 산술 좌시프트 `$(( a << b ))`도 heredoc이 아니다(오인원 열거 2번).
  if (hl ~ /\$\(\(/) gsub(/<</, "@SHIFT@", hl)
  if (match(hl, /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*/)) {
    d=substr(hl,RSTART,RLENGTH); gsub(/.*<<-?[ \t]*['"]?/,"",d); delim=d; inhere=1; next
  }
  if (line ~ /^@test .*\{[ \t]*$/){ intest=1; pend=""; next }
  if (!intest) next
  if (line ~ /^\}[ \t]*$/){ intest=0; pend=""; next }
  t=line; sub(/^[ \t]+/,"",t)
  if (t=="" || t ~ /^#/) next
  flush()
  if (t ~ /^![ \t]/)    pend=FILENAME":"FNR": [NEG] "t
  else if (t ~ /^\[\[/) pend=FILENAME":"FNR": [BB] "t
}
# 검출기가 **실제로 읽은** 파일 수를 호출자에게 알린다 — 형제 check-host-ports.sh와 같은 계약.
END { printf "READFILES=%d\n", nfiles > "/dev/stderr" }
AWK
# 검출 실행(인자 검증·rc 포착·READFILES 대조)은 detect_run(guard.sh) 소유 — 여긴 awk 본문만.
findings="$(detect_run check-bats-style "$DETECT" "${FILES[@]}")"
neg="$(printf '%s\n' "$findings" | grep -c '\[NEG\]' || true)"; neg="${neg//[^0-9]/}"; neg="${neg:-0}"
bb="$(printf '%s\n' "$findings" | grep -c '\[BB\]' || true)"; bb="${bb//[^0-9]/}"; bb="${bb:-0}"
printf '%s\n' "$findings" | grep -E '\[(NEG|BB)\]' || true   # gate bats가 [NEG]/[BB] 검증
rc=0
if [ "$neg" -gt 0 ]; then
  echo "FAIL: 마지막 명령이 아닌 부정 단언 ${neg}곳 — bats가 침묵 통과. 'run …; [ \"\$status\" -ne 0 ]'로 재작성." >&2; rc=1
fi
if [ "$#" -gt 0 ]; then
  [ "$bb" -eq 0 ] || { echo "FAIL: (명시 파일) 중간 [[ ]] ${bb}곳 탐지." >&2; rc=1; }
else
  echo "check-bats-style: 중간 [[ ]] ${bb} (baseline ${BB_BASELINE})"
  [ "$bb" -le "$BB_BASELINE" ] || { echo "FAIL: 중간 [[ ]]가 baseline(${BB_BASELINE}) 초과(${bb}) — 신규는 'run …; [ … ]'로." >&2; rc=1; }
fi
[ "$rc" -eq 0 ] && echo "check-bats-style: 중간 부정 0곳 + [[ ]] ratchet OK"
exit "$rc"
