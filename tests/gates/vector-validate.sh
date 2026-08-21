#!/usr/bin/env bash
# vector config semantic 검증(컨테이너, 배포 버전) — kustomize render는 vector 의미오류 미차단. set -e.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VEC="$ROOT/platform/victoria-stack/prod/vector.yaml"
# ⚠️ `|| VER=""`가 **필요하다** — `set -o pipefail` 아래에서 grep 0건은 파이프라인 rc=1이라
#    `set -e`가 **할당 단계에서** 죽인다. 그러면 아래 `[ -n "$VER" ]` 진단이 영원히 실행되지
#    않고 게이트가 메시지 0줄에 rc=1로 끝난다(형제 alertmanager-render-e2e에서 실측된 클래스).
VER="$(grep -oE 'timberio/vector:[0-9.]+' "$VEC" | head -1 | cut -d: -f2)" || VER=""   # DaemonSet 이미지 버전과 동일(드리프트 0)
[ -n "$VER" ] || { echo "vector 버전 추출 실패"; exit 1; }
TMP="$(mktemp -d)"
yq 'select(.kind=="ConfigMap" and .metadata.name=="vector-config") | .data."vector.yaml"' "$VEC" > "$TMP/vector.yaml"
[ -s "$TMP/vector.yaml" ] || { echo "vector config 추출 실패"; exit 1; }
docker run --rm -v "$TMP/vector.yaml:/etc/vector/vector.yaml:ro" \
  "timberio/vector:${VER}-distroless-libc" validate --no-environment /etc/vector/vector.yaml
