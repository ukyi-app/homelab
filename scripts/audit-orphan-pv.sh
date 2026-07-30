#!/usr/bin/env bash
# 고아 스토리지 감사 — hostPath 디스크가 조용히 누수되는 두 경로를 **둘 다** 본다. 나열만(파괴 없음).
# ★fail-closed(F7): 도구/접근/쿼리 실패는 비-0 종료(깨진 감사를 '고아 없음'으로 위장 금지).
#
# ⚠️ **이 가드는 자기 클래스의 병에 걸려 있었다(2026-07-29 실측).** 예전 판은 `.status.phase == "Released"`
#    **하나만** 봤다. 그 전제는 "PVC를 지우면 PV가 Released로 남는다"인데, 실제로 발생한 고아는
#    `kubectl delete sts --cascade=orphan`으로 만들어졌고 **그건 PVC를 지우지 않는다** → PV는 계속
#    `Bound`다. 결과: 1.12GiB가 21일간 누수된 상태에서 이 감사가 **"고아 없음(Released 0건)" + rc=0**을
#    냈다. 게이트가 없는 것보다 나쁘다 — 감사했다는 착각을 만든다.
#    (라이브 확인: storage-vmsingle-0 20Gi 선언/1.0GiB 사용 · vlogs-victorialogs-0 10Gi 선언/118MiB 사용,
#     둘 다 PV phase=Bound. ArgoCD도 못 잡는다 — STS 컨트롤러가 volumeClaimTemplates로 만든 객체라
#     tracking 어노테이션이 없고 앱은 Synced/Healthy다.)
#
# ⇒ 이제 **두 클래스**를 본다:
#   ① Released PV        — PVC 삭제 + Retain 잔존(원래 대상)
#   ② Bound인데 소비자 0 — PVC는 살아 있는데 어떤 파드도 마운트하지 않음(cascade=orphan 잔재)
# 판정은 **소비 여부**로 한다. "phase"는 ②를 원리적으로 볼 수 없다.
set -euo pipefail
command -v kubectl >/dev/null || { echo "ERROR: kubectl 부재" >&2; exit 2; }
command -v yq >/dev/null || { echo "ERROR: yq 부재" >&2; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: 클러스터 접근 불가(KUBECONFIG/RBAC)" >&2; exit 3; }

rc=0

echo "== ① 고아 Released PV (PVC 삭제 + Retain 잔존) =="
pvs="$(kubectl get pv -o json)" || { echo "ERROR: kubectl get pv 실패" >&2; exit 3; }   # 쿼리 실패=비-0
released="$(printf '%s' "$pvs" | yq -r '.items[] | select(.status.phase == "Released") | .metadata.name + "\t" + (.spec.hostPath.path // .spec.local.path // "?") + "\t" + (.spec.storageClassName // "?")')"
if [ -z "$released" ]; then echo "  없음(쿼리 성공, Released 0건)"; else printf '%s\n' "$released"; rc=1; fi

echo "== ② 소비자 없는 PVC (Bound인데 어떤 파드도 마운트하지 않음 — cascade=orphan 잔재) =="
pvcs="$(kubectl get pvc -A -o json)" || { echo "ERROR: kubectl get pvc 실패" >&2; exit 3; }
pods="$(kubectl get pod -A -o json)" || { echo "ERROR: kubectl get pod 실패" >&2; exit 3; }

# 열거 바닥값 — PVC가 0건으로 읽히면 "고아 없음"과 구별할 수 없다(무측정).
n_pvc="$(printf '%s' "$pvcs" | yq -r '.items | length')"
[ "${n_pvc:-0}" -ge "${ORPHAN_PVC_MIN_SCAN:-3}" ] || {
  echo "ERROR: PVC ${n_pvc:-0}건 < 바닥값 ${ORPHAN_PVC_MIN_SCAN:-3} — 열거 붕괴 의심(0건 검사 후 초록이 되는 자리)" >&2
  exit 3
}

# 소비 집합: 파드가 실제로 마운트한 (ns, claimName). ⚠️ **파드 기준**이다 — STS/Deployment 스펙만 보면
# 스케일 0이나 삭제된 컨트롤러의 PVC를 "사용 중"으로 오판한다.
# shellcheck disable=SC2016  # `$ns`는 **yq 변수**다(셸 확장이 아니라 yq의 `as $ns` 바인딩) — 홑따옴표가 맞다.
used="$(printf '%s' "$pods" | yq -r '.items[] | .metadata.namespace as $ns | .spec.volumes[]? | select(.persistentVolumeClaim) | $ns + "/" + .persistentVolumeClaim.claimName' | sort -u)"

unconsumed=""
while IFS= read -r key; do
  [ -n "$key" ] || continue
  printf '%s\n' "$used" | grep -qxF "$key" || unconsumed="${unconsumed}  ${key}"$'\n'
done <<< "$(printf '%s' "$pvcs" | yq -r '.items[] | .metadata.namespace + "/" + .metadata.name')"

if [ -z "$unconsumed" ]; then
  echo "  없음(PVC ${n_pvc}건 전건이 파드에 마운트됨)"
else
  printf '%s' "$unconsumed"
  echo "  ⚠️ PVC가 살아 있으므로 PV는 Bound다 — ①의 phase 검사로는 원리적으로 안 잡힌다."
  rc=1
fi

echo "== reclaim(파괴 — owner 수동, 자동화 금지) =="
echo "   PVC → PV → hostPath 디렉토리 **3단계 전부** 완주할 것. 두 storageClass 모두 Retain이라"
echo "   중간에 멈추면 PV 없는 디스크 잔재가 남는다(실제로 그 상태의 잔재가 관측됐다)."
echo "   절차: docs/runbooks/storage-verify.md"
exit "$rc"
