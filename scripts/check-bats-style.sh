#!/usr/bin/env bash
# bats 단언-스타일 가드 — @test 본문에서 '마지막 명령이 아닌'(중간) 부정(`! `)·조건(`[[ `)을 잡는다.
# bats는 negated/[[ 명령의 실패를 errexit/ERR-trap 면제로 침묵 통과시킨다(라이브 확증: bats 1.13에서
# 중간 `! echo x|grep -q x`가 'ok'). 그런 중간 단언은 죽은(false-green) 가드다.
#   NEG(중간 `! `)  = 모든 bash에서 발생(negated pipeline은 set -e 면제) → hard-zero.
#   BB (중간 `[[ `) = bash 3.2 함정 변종. 현재 재고(BB_BASELINE)는 B13이 정비 → 0 수렴. 그때까지 ratchet.
# 휴리스틱: 다줄 @test 규약 가정("@test … {" 한 줄 시작, 0열 "}" 종료). heredoc 본문은 명령으로 안 센다.
# (레포 단일 한줄 @test는 단일 명령이라 무해 — 신규 한줄 본문은 다줄로 작성할 것.)
# 인자로 파일을 주면 그 파일만 스캔하고 NEG·BB 아무거나 있으면 실패(픽스처/ad-hoc 탐지 모드).
# bash 3.2 호환: mapfile 금지(while read). shellcheck 클린.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BB_BASELINE="${BB_BASELINE_OVERRIDE:-53}"   # 현재 트리 중간 [[ ]] 수(B13.4 차트 bats 정비로 65→53). 신규 증가 차단, 0 수렴 목표.
FILES=()
if [ "$#" -gt 0 ]; then FILES=("$@"); else
  while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.bats')
fi
[ "${#FILES[@]}" -gt 0 ] || { echo "check-bats-style: 대상 bats 없음"; exit 0; }
DETECT=""
IFS='' read -r -d '' DETECT <<'AWK' || true
function flush(){ if(pend!=""){ print pend; pend="" } }
FNR==1 { intest=0; pend=""; inhere=0; delim="" }
{
  line=$0
  if (inhere){ if(line ~ ("^[ \t]*"delim"[ \t]*$")) inhere=0; next }
  if (match(line, /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*/)) {
    d=substr(line,RSTART,RLENGTH); gsub(/.*<<-?[ \t]*['"]?/,"",d); delim=d; inhere=1; next
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
AWK
findings="$(awk "$DETECT" "${FILES[@]}" || true)"
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
  echo "check-bats-style: 중간 [[ ]] ${bb} (baseline ${BB_BASELINE} — B13 정비 대상)"
  [ "$bb" -le "$BB_BASELINE" ] || { echo "FAIL: 중간 [[ ]]가 baseline(${BB_BASELINE}) 초과(${bb}) — 신규는 'run …; [ … ]'로." >&2; rc=1; }
fi
[ "$rc" -eq 0 ] && echo "check-bats-style: 중간 부정 0곳 + [[ ]] ratchet OK"
exit "$rc"
