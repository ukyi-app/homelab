#!/usr/bin/env bash
# 상주 워크로드(Deployment/DaemonSet/StatefulSet)의 main 컨테이너는 memory limit 필수 — OR 명시 allowlist.
# vector OOM(PR #85) 포스트모템 가드: limit 미강제 워크로드는 OOM 블라인드스팟이고 메모리 원장 게이트가
# 못 잡는다(원장은 마크다운 행만 검증, 라이브 manifest 미교차). 소스 매니페스트 직접 스캔(렌더 불요) —
# 원격-helm 컴포넌트(cert-manager·cnpg-operator 등)는 CI 로컬렌더 불가라 범위 밖이며, 의도적 미설정은
# policy/memory-limit-allowlist.txt 에 이유와 함께 문서화한다. initContainer는 전이성이라 범위 밖(main만).
# yq(YAML→JSON 변환만, 버전 무관) + python3(stdlib json) 사용. bash 3.2 호환. shellcheck clean.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ALLOW="policy/memory-limit-allowlist.txt"
count=0
viol=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  count=$((count + 1))
  json=$(yq ea -o=json '[.]' "$f")
  out=$(ML_JSON="$json" ML_ALLOW="$ALLOW" python3 - <<'PY'
import os, json
allowed = set()
try:
    with open(os.environ["ML_ALLOW"]) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line:
                allowed.add(line)
except FileNotFoundError:
    pass
for o in json.loads(os.environ["ML_JSON"]):
    if not isinstance(o, dict):
        continue
    if o.get("kind") not in ("Deployment", "DaemonSet", "StatefulSet"):
        continue
    name = o.get("metadata", {}).get("name", "?")
    spec = o.get("spec", {}).get("template", {}).get("spec", {})
    for c in spec.get("containers", []) or []:
        limits = (c.get("resources") or {}).get("limits") or {}
        if "memory" in limits:
            continue
        key = "%s/%s/%s" % (o.get("kind"), name, c.get("name"))
        if key not in allowed:
            print(key)
PY
)
  if [ -n "$out" ]; then
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      viol="${viol}  ${k}  (${f})"$'\n'
    done <<EOF
$out
EOF
  fi
done < <(grep -rlE '^kind:[[:space:]]*(Deployment|DaemonSet|StatefulSet)' platform --include='*.yaml' | grep -vE '/charts/|barman-plugin')
if [ -n "$viol" ]; then
  echo "FAIL: memory limit 없는 상주 워크로드 main 컨테이너 — 원장 행 추가 후 limit 선언, 또는 ${ALLOW}에 이유와 함께 등재:"
  printf '%s' "$viol"
  exit 1
fi
echo "check-memory-limits OK (${count} 워크로드 매니페스트 스캔, 위반 0)"
