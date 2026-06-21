#!/usr/bin/env bash
# 고아 Released PV 감사 — storageclass-standard가 Retain(DB 데이터 보호)이라 PVC 삭제 시 PV가 Released로
# 남고 hostPath 디스크가 누수된다. 나열만(파괴 없음) — reclaim은 owner 수동(런북).
# ★fail-closed(F7): 도구/접근/쿼리 실패는 비-0 종료(깨진 감사를 '고아 없음'으로 위장 금지).
set -euo pipefail
command -v kubectl >/dev/null || { echo "ERROR: kubectl 부재" >&2; exit 2; }
command -v yq >/dev/null || { echo "ERROR: yq 부재" >&2; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: 클러스터 접근 불가(KUBECONFIG/RBAC)" >&2; exit 3; }
echo "== 고아 Released PV (PVC 삭제+Retain 잔존, hostPath 디스크 누수) =="
pvs="$(kubectl get pv -o json)" || { echo "ERROR: kubectl get pv 실패" >&2; exit 3; }   # 쿼리 실패=비-0
orphans="$(printf '%s' "$pvs" | yq -r '.items[] | select(.status.phase == "Released") | .metadata.name + "\t" + (.spec.hostPath.path // .spec.local.path // "?") + "\t" + (.spec.storageClassName // "?")')"
if [ -z "$orphans" ]; then echo "고아 없음(쿼리 성공, Released 0건)"; else printf '%s\n' "$orphans"; fi
echo "== reclaim: PV 데이터 확인 후 'kubectl delete pv <name>' + 노드 hostPath 디렉토리 수동 삭제(런북) =="
