#!/usr/bin/env bash
# PreToolUse 가드 — Edit|Write|MultiEdit가 위험 경로를 건드리면 차단(exit 2)한다.
# 글로벌 rtk 훅은 matcher가 Bash라 이 훅(Edit|Write|MultiEdit)과 레이어가 분리돼 공존한다.
# 고확신 경로 패턴만 차단한다(오탐 0 우선) — 콘텐츠 의존 함정(Application zero-value,
# NetworkPolicy pod-CIDR 등)은 CI/bats가 이미 잡으므로 여기서 다루지 않는다.
# DR 함정: sops 복호/재암호는 Bash 경로라 이 훅이 막지 않는다 — 재구축 복구 흐름은 무영향.
set -euo pipefail

input="$(cat)"
[ -z "$input" ] && exit 0

fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[ -z "$fp" ] && exit 0

case "$fp" in
  *.enc.yaml)
    echo "차단: '$fp' 는 SOPS 암호화 파일이다. 직접 편집은 평문 메타데이터까지 MAC에 묶여 복호 불능이 된다." >&2
    echo "→ 'sops $fp' (또는 make secret-edit FILE=$fp)로 복호화→편집→재암호화하라." >&2
    exit 2
    ;;
esac

case "$fp" in
  */prod/charts/*)
    echo "차단: '$fp' 는 kustomize --enable-helm 차트 풀 캐시(untracked 벤더)다. 수정은 렌더 시 덮어쓰인다." >&2
    echo "→ 값 변경은 상위 values.yaml / HelmChartInflationGenerator에서 하라." >&2
    exit 2
    ;;
esac

exit 0
