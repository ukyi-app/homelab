#!/usr/bin/env bash
set -euo pipefail
README="${CK_README:-README.md}"   # 테스트 오버라이드(역방향 검사용)
BT='`'                              # 백틱 리터럴
# platform 컴포넌트는 아래 양방향 검사(정방향 dir→표 + 역방향 표→dir)가 동적 커버한다 —
# argocd/root·charts/app 서브경로 스켈레톤만 여기 명시 유지(basename 검사가 못 잡는 깊이).
dirs=(
  infra/cloudflare infra/github infra/tailscale infra/k3s-bootstrap
  platform/argocd/root platform/charts/app
  apps tools docs/plans
)
rc=0
for d in "${dirs[@]}"; do
  if [ -d "$d" ]; then echo "OK  $d"; else echo "MISSING $d"; rc=1; fi
done

# bats 네이밍 컨벤션: 모든 추적 *.bats는 test_ 접두여야 한다(run-bats.sh 수집 글롭 전제).
# 미접두 bats는 단일 러너 수집에서 조용히 빠지므로 시끄럽게 실패시킨다. (grep no-match는 || true로 흡수)
unprefixed="$(git ls-files '*.bats' | grep -vE '(^|/)test_[^/]*\.bats$' || true)"
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
done < <(git ls-files '*test_*.bats')
if [ -n "$cjk_hits" ]; then
  echo "FAIL: @test 이름에 CJK 문자(디렉토리 실행 시 침묵스킵) — 영어로 변경:"
  printf '%s' "$cjk_hits"
  rc=1
fi

# README 디렉토리 지도 드리프트 가드: 모든 platform 컴포넌트(charts 제외)가 README 지도에 나열돼야 한다.
# 새 컴포넌트 추가 시 지도 갱신을 강제(가상명·누락 차단). tools/tests/test_dirmap.bats와 동일 불변식.
# glob 루프(ls 파싱 회피 — SC2011). bash 3.2 안전.
for d in platform/*/; do
  c="$(basename "$d")"
  case "$c" in charts) continue;; esac
  if ! grep -q "$c" "$README"; then echo "FAIL: README 디렉토리 지도에 platform 컴포넌트 누락: $c"; rc=1; fi
done

# 역방향(README 컴포넌트 표 → 디렉토리): 표에 나열된 각 컴포넌트가 platform/<c>/로 실재하는지.
# 정방향(dir→표)과 합쳐 양방향 — phantom/리네임 항목을 잡고 신규 컴포넌트를 자동 편입한다.
comps="$(sed -n '/### platform 컴포넌트/,/^## /p' "$README" | grep -oE "^\| ${BT}[a-z0-9-]+${BT}" | tr -d "${BT}|" | tr -d ' ')"
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ -d "platform/$c" ] || { echo "FAIL: README 컴포넌트 표에 있으나 platform/ 디렉토리 부재: $c"; rc=1; }
done <<< "$comps"

exit $rc
