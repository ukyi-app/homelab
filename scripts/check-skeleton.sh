#!/usr/bin/env bash
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-skeleton
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 02 — 구 SKELETON_*
# env 폐지: env는 호출부에 보이지 않는 채로 바닥값을 끄거나 올린다).
take_floors "check-skeleton:bats check-skeleton:platform check-skeleton:nul-scan" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
[ $# -eq 0 ] || { echo "unknown arg: $1" >&2; exit 2; }
cd "$ROOT"
README="${CK_README:-README.md}"   # 테스트 오버라이드(역방향 검사용)
BT='`'                              # 백틱 리터럴
# platform 컴포넌트는 아래 양방향 검사(정방향 dir→표 + 역방향 표→dir)가 동적 커버한다 —
# argocd/root·charts/app 서브경로 스켈레톤만 여기 명시 유지(basename 검사가 못 잡는 깊이).
dirs=(
  infra/cloudflare infra/github infra/tailscale infra/k3s-bootstrap
  platform/argocd/root platform/charts/app
  apps tools
)
rc=0
for d in "${dirs[@]}"; do
  if [ -d "$d" ]; then echo "OK  $d"; else echo "MISSING $d"; rc=1; fi
done

# bats 네이밍 컨벤션: 모든 추적 *.bats는 test_ 접두여야 한다(run-bats.sh 수집 글롭 전제).
# 미접두 bats는 단일 러너 수집에서 조용히 빠지므로 시끄럽게 실패시킨다. (grep no-match는 || true로 흡수)
# ⚠️ 열거를 변수로 받아 rc를 잡는다. 이 도메인이 비면 네이밍 가드와 CJK 가드가 **둘 다** 0회 돈다
# (CJK는 3회 재발한 검증된 함정이라 조용히 꺼지면 특히 위험하다). 현재값은 SCAN 마커를 읽어라 — 래칫 아님.
all_bats="$(scan_enumerate check-skeleton git ls-files '*.bats')" || exit 1
# 판정만 한다(quiet) — 마커는 **전 도메인 판정 뒤** 아래에서 일괄 방출한다. 뒤 도메인이
# 붕괴한 실행이 앞 도메인의 "N건 검사했다"를 내면 소비자가 정반대로 읽는다(TS guardMain과 동형).
n_bats="$(scan_count "$all_bats")"
scan_floor check-skeleton:bats "$n_bats" "$(floor_of check-skeleton:bats 150)" quiet || exit 1
unprefixed="$(printf '%s\n' "$all_bats" | grep -vE '(^|/)test_[^/]*\.bats$' || true)"
if [ -n "$unprefixed" ]; then
  echo "FAIL: test_ 접두 없는 bats (네이밍 컨벤션 위반):"
  echo "$unprefixed"
  rc=1
fi

# CJK @test 이름 가드: bats는 디렉토리 단위 실행 시 한글/CJK @test 이름을 조용히 스킵한다(검증된 함정).
# @test 선언의 **이름만**(닫는 따옴표까지 `"([^"]*)"`) 검사 — trailing 한국어 주석·em-dash는 bats OK라 제외(F2).
cjk_hits=""
while IFS= read -r f; do
  h="$(perl -CSDA -ne 'print "$ARGV:$.: $_" if /^\s*\@test\s+"([^"]*)"/ && $1 =~ /[\p{Han}\p{Hangul}\p{Hiragana}\p{Katakana}]/' "$f")"
  if [ -n "$h" ]; then cjk_hits="$cjk_hits$h"$'\n'; fi
done <<< "$(printf '%s\n' "$all_bats" | grep -E '(^|/)test_[^/]*\.bats$' || true)"
if [ -n "$cjk_hits" ]; then
  echo "FAIL: @test 이름에 CJK 문자(디렉토리 실행 시 침묵스킵) — 영어로 변경:"
  printf '%s' "$cjk_hits"
  rc=1
fi

# README 디렉토리 지도 드리프트 가드: 모든 platform 컴포넌트(charts 제외)가 README 지도에 나열돼야 한다.
# 새 컴포넌트 추가 시 지도 갱신을 강제(가상명·누락 차단). tools/tests/test_dirmap.bats와 동일 불변식.
# glob 루프(ls 파싱 회피 — SC2011). bash 3.2 안전.
# 열거는 공유 워커의 `platform` 유닛 스코프가 소유한다(공유 차트 제외도 그 안에 있다).
# ⚠️ 프로세스 치환은 워커 실패를 전파하지 않아, bun이 죽으면 정방향(dir→표) 검사가 0회 돌고
# 역방향만 남은 채 통과했다(부분 degrade — 실측). 현재 컴포넌트 16개 — 래칫 아님.
comp_units="$(scan_enumerate check-skeleton bun "$(dirname "${BASH_SOURCE[0]}")/../tools/lib/repo-walk.ts" --units platform)" || exit 1
n_platform="$(scan_count "$comp_units")"
scan_floor check-skeleton:platform "$n_platform" "$(floor_of check-skeleton:platform 10)" quiet || exit 1
while IFS= read -r d; do
  [ -n "$d" ] || continue
  c="$(basename "$d")"
  if ! grep -q "$c" "$README"; then echo "FAIL: README 디렉토리 지도에 platform 컴포넌트 누락: $c"; rc=1; fi
done <<< "$comp_units"

# 역방향(README 컴포넌트 표 → 디렉토리): 표에 나열된 각 컴포넌트가 platform/<c>/로 실재하는지.
# 정방향(dir→표)과 합쳐 양방향 — phantom/리네임 항목을 잡고 신규 컴포넌트를 자동 편입한다.
comps="$(sed -n '/### platform 컴포넌트/,/^## /p' "$README" | grep -oE "^\| ${BT}[a-z0-9-]+${BT}" | tr -d "${BT}|" | tr -d ' ')"
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ -d "platform/$c" ] || { echo "FAIL: README 컴포넌트 표에 있으나 platform/ 디렉토리 부재: $c"; rc=1; }
done <<< "$comps"

# ── 소스에 리터럴 NUL 금지 — grep이 그 파일을 **바이너리로 판정해 통째로 건너뛴다** ────────────────
# ⚠️ 라이브 실측(2026-07-29): tools/check-image-ownership.ts가 맵 키 구분자로 **리터럴 NUL 바이트**를
#    소스에 박고 있었다(`${file}<NUL>${ref}`). 동작은 정상이지만 grep이 "Binary file … matches"만 내고
#    **내용을 한 줄도 출력하지 않는다** → 이 레포의 grep 기반 가드 전부에게 그 파일이 **투명해진다**.
#    발견 경위: SCAN 마커 파생 로스터가 이 파일의 라벨만 조용히 누락했다(정적 8 vs 런타임 9).
#    즉 "가드가 돌았고 초록인데 대상 하나를 아예 안 본" 전형적 무측정이다.
# 처방: 구분자는 이스케이프(`\u0000`)로 쓴다 — 런타임 값은 같고 파일은 텍스트로 남는다.
# 대상은 **확장자로 파생**한다(손 관리 목록 금지). 이미지 등 정당한 바이너리 자산은 자연히 빠진다.
nul_scanned=0
nul_bad=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  nul_scanned=$((nul_scanned + 1))
  # ⚠️ `grep "$(printf '\000')"`로 찾으면 안 된다 — 명령 치환이 NUL을 삼켜 **빈 패턴**이 되고,
  #    빈 패턴은 **모든 파일에 매치**한다(실측: 878건 전건 red). 열거가 아니라 패턴이 붕괴하는 형태다.
  #    tr로 NUL만 지운 스트림과 원본을 비교한다 — POSIX 도구만 쓰고 GNU/BSD 양쪽에서 같다.
  # NUL을 지운 바이트 수와 원본 바이트 수를 비교한다 — 다르면 NUL이 있다.
  # (`tr … | cmp - "$f"`는 같은 파일을 한 파이프라인에서 두 번 읽어 shellcheck SC2094가 붙는다.)
  if [ "$(LC_ALL=C tr -d '\000' < "$f" | wc -c)" -ne "$(wc -c < "$f")" ]; then nul_bad="${nul_bad}  $f"$'\n'; fi
done <<< "$(git ls-files '*.ts' '*.mts' '*.sh' '*.bats' '*.yaml' '*.yml' '*.json' '*.md' '*.py' '*.tf' '*.rego' 'Makefile')"
scan_floor check-skeleton:nul-scan "$nul_scanned" "$(floor_of check-skeleton:nul-scan 200)" quiet || exit 1

# ── 마커 일괄 방출 — 전 도메인이 바닥값을 통과한 뒤에만 나간다 ──
# 순서는 종전과 같다(bats → platform → nul-scan) — 소비자가 보는 시퀀스를 바꾸지 않는다.
scan_signal check-skeleton:bats "$n_bats"
scan_signal check-skeleton:platform "$n_platform"
scan_signal check-skeleton:nul-scan "$nul_scanned"
if [ -n "$nul_bad" ]; then
  echo "FAIL: 소스에 리터럴 NUL 바이트 — grep이 이 파일들을 바이너리로 보고 내용을 건너뛴다(가드에 투명해짐):"
  printf '%s' "$nul_bad"
  printf '  -> 구분자가 필요하면 리터럴 NUL 대신 이스케이프를 써라 (TS: \\u0000 / bash: ANSI-C 인용).\n'
  rc=1
fi

exit $rc
