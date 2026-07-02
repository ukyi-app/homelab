#!/usr/bin/env bash
# 상주 워크로드(Deployment/DaemonSet/StatefulSet)의 main 컨테이너는 cpu·memory request + memory limit 필수
# — OR 명시 allowlist. (cpu limit은 비요구: CFS quota라 유휴 노드서도 throttling 유발 → 의도적 생략이 SRE 권장.
#  starvation 방지는 cpu request의 점유율 보장으로, OOM 방지는 memory limit으로.)
# vector OOM(PR #85) 포스트모템 + CPU 단일축 편향 해소 가드: limit/request 미강제 워크로드는 OOM·starvation
# 블라인드스팟이고 메모리 원장 게이트가 못 잡는다(원장은 마크다운 행만 검증, 라이브 manifest 미교차). 소스 매니페스트 직접 스캔(렌더 불요) —
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
import re
def to_bytes(v):
    m = re.match(r'^\s*(\d+(?:\.\d+)?)\s*([A-Za-z]*)\s*$', str(v))
    if not m: return None
    u = {"":1,"B":1,"Ki":2**10,"Mi":2**20,"Gi":2**30,"Ti":2**40,
         "KiB":2**10,"MiB":2**20,"GiB":2**30,"TiB":2**40,
         "k":1e3,"K":1e3,"M":1e6,"G":1e9,"T":1e12}
    return float(m.group(1)) * u[m.group(2)] if m.group(2) in u else None
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
        res = c.get("resources") or {}
        requests = res.get("requests") or {}
        limits = res.get("limits") or {}
        # GOMEMLIMIT ≤ limit×0.95 (right-size 시 GOMEMLIMIT 미동반 갱신 → GC 소프트리밋이 cgroup limit
        # 위로 올라가 OOMKill 직행. vmalert 드리프트가 이 검사로 자동 포착 — 원장이 못 보는 2차 축).
        gomem = None
        for e in c.get("env", []) or []:
            if isinstance(e, dict) and e.get("name") == "GOMEMLIMIT":
                gomem = e.get("value")
        if gomem and "memory" in limits:
            gb, lb = to_bytes(gomem), to_bytes(limits["memory"])
            if gb is not None and lb is not None and gb > lb * 0.95:
                print("%s/%s/%s [GOMEMLIMIT %s > limit×0.95 (%s)]" % (
                    o.get("kind"), name, c.get("name"), gomem, limits["memory"]))
        missing = []
        if "cpu" not in requests:
            missing.append("requests.cpu")
        if "memory" not in requests:
            missing.append("requests.memory")
        if "memory" not in limits:
            missing.append("limits.memory")
        if not missing:
            continue
        key = "%s/%s/%s" % (o.get("kind"), name, c.get("name"))
        if key not in allowed:
            print("%s [missing: %s]" % (key, ",".join(missing)))
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
# scan-floor: grep 셀렉터 붕괴(platform 재배치·kind 들여쓰기·패턴 회귀)로 매치가 0~소수면 가드가
# 아무것도 검사 안 하고 GREEN이 되는 false-green을 차단(fail-loud). 현재 스캔 ~15건.
MIN_SCAN=10
if [ "$count" -lt "$MIN_SCAN" ]; then
  echo "FAIL: 스캔 대상 ${count}건 < ${MIN_SCAN} — grep 셀렉터 회귀 의심(platform 재배치/kind 들여쓰기?)" >&2
  exit 1
fi
if [ -n "$viol" ]; then
  echo "FAIL: cpu·memory request 또는 memory limit 없는 상주 워크로드 main 컨테이너 — 선언 후 (memory는) 원장 행 동반, 또는 ${ALLOW}에 이유와 함께 등재:"
  printf '%s' "$viol"
  exit 1
fi
echo "check-resource-limits OK (${count} 워크로드 매니페스트 스캔, cpu·memory request + memory limit 위반 0)"
