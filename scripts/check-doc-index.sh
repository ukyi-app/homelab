#!/usr/bin/env bash
# 디렉토리 인덱스 드리프트 가드 — scripts/·tools/·.github/workflows/ 의 각 산출물이 해당
# README에 문자열로 등재됐는지 검사(가드 없는 인덱스 드리프트 소멸). check-skeleton.sh(디렉토리
# 지도)·verify-runbook-index.sh(런북 인덱스)와 동일 불변식. 순수 파일/문자열 검사(CI-safe).
# bash 3.2 안전(glob 루프, 배열 미사용).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BT='`'   # 백틱 리터럴(명령치환 회피)
rc=0

# scripts/*.sh ↔ scripts/README.md (백틱 감싼 파일명 — README 규약)
for f in scripts/*.sh; do
  b="$(basename "$f")"
  grep -Fq "${BT}${b}${BT}" scripts/README.md || { echo "FAIL: scripts/README.md 미등재: $b"; rc=1; }
done

# tools/*.ts·*.mts ↔ tools/README.md (스키마 .json은 표로 별도 문서화 → 제외)
for f in tools/*.ts tools/*.mts; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  grep -Fq "${BT}${b}${BT}" tools/README.md || { echo "FAIL: tools/README.md 미등재: $b"; rc=1; }
done

# .github/workflows/*.yaml ↔ workflows README (친화명 표기라 basename 존재검사)
# ⚠️ 거친 검사: prose 언급도 통과(build은 'build 완료'에 이미 등장). 제로-언급 신규 워크플로 차단이 목적.
for f in .github/workflows/*.yaml; do
  b="$(basename "$f" .yaml)"
  grep -Fq "$b" .github/workflows/README.md || { echo "FAIL: workflows README 미등재: ${b}.yaml"; rc=1; }
done

[ "$rc" -eq 0 ] && echo "check-doc-index: scripts·tools·workflows 인덱스 정합 OK"
exit "$rc"
