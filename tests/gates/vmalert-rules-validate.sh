#!/usr/bin/env bash
# vmalert 룰 파서 검증(컨테이너, 배포 버전) — grep만으론 오류 PromQL/MetricsQL이 통과한다(적대 리뷰 Pass3 #2).
# 룰 ConfigMap(rules/*.yaml)의 .data 룰 파일을 추출해 vmalert -dryRun으로 룰 로딩/expr 파싱을 검증한다.
# kustomize render는 룰 의미오류를 못 잡는다(alertmanager-render-e2e·vector-validate 선례). docker는 러너 기본.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMALERT="$ROOT/platform/victoria-stack/prod/vmalert.yaml"
# ⚠️ `|| VER=""`가 **필요하다** — `set -o pipefail` 아래에서 grep 0건은 파이프라인 rc=1이라
#    `set -e`가 **할당 단계에서** 죽인다. 그러면 아래 `[ -n "$VER" ]` 진단이 영원히 실행되지
#    않고 게이트가 메시지 0줄에 rc=1로 끝난다(형제 alertmanager-render-e2e에서 실측된 클래스).
VER="$(grep -oE 'victoriametrics/vmalert:v[0-9.]+' "$VMALERT" | head -1 | cut -d: -f2)" || VER=""   # Deployment 이미지와 동일(드리프트 0)
[ -n "$VER" ] || { echo "vmalert 버전 추출 실패"; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# 각 rule ConfigMap의 단일 data 키(룰 파일)를 추출 — 키명은 .yaml 접미(core.yaml/r4.yaml/...).
for f in "$ROOT"/platform/victoria-stack/prod/rules/*.yaml; do
  key="$(yq '.data | keys | .[0]' "$f")"
  [ -n "$key" ] && [ "$key" != "null" ] || { echo "룰 data 키 추출 실패: $f"; exit 1; }
  yq ".data.\"$key\"" "$f" > "$TMP/$key"
  [ -s "$TMP/$key" ] || { echo "룰 추출 실패: $f"; exit 1; }
done
# -dryRun: 룰 파일만 검증하고 vmalert를 실행하지 않는다(datasource 불요). 잘못된 expr면 비-0.
docker run --rm -v "$TMP:/rules:ro" "victoriametrics/vmalert:${VER}" -rule='/rules/*.yaml' -dryRun
echo "vmalert-rules-validate OK (rules/*.yaml dryRun 통과)"
