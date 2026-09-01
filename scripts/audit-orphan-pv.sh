#!/usr/bin/env bash
# 고아 스토리지 감사 — hostPath 디스크가 조용히 누수되는 두 경로를 **둘 다** 본다. 나열만(파괴 없음).
# ★fail-closed(F7): 도구·접근 부재=skip(4 — 도메인에 닿을 수 없음), 평가 중 쿼리 실패=비-0 red
#   (깨진 감사를 '고아 없음'으로 위장 금지 — skip 마커는 '평가하지 않았다'라 위장이 아니다).
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
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다 — 개별
# `LC_ALL=C sort` 접두는 떼지 않는다(정적 레인이 런타임 export를 못 보므로 이중이 계약이다).
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init audit-orphan-pv
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 03 — 구 env 폐지).
take_floors "audit-orphan-pv" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
[ $# -eq 0 ] || { echo "unknown arg: $1" >&2; exit 2; }
# 도구·클러스터 부재 = 평가할 라이브 도메인에 닿을 수 없음 — skip 규약(verify-posture 선례).
# CI 러너(ubuntu-arm, setup-toolchain)에는 kubectl이 없다 — 여기서 2로 죽으면 로스터 등식 게이트가
# venue에 따라 갈린다(로컬 초록·CI red — 그 게이트 주석이 실측으로 적어 둔 클래스).
command -v kubectl >/dev/null || guard_skip audit-orphan-pv "kubectl 부재 — 라이브 감사 미평가"
command -v yq >/dev/null || guard_skip audit-orphan-pv "yq 부재 — 라이브 감사 미평가"
# 접근 불가 = 평가할 도메인에 닿을 수 없음 — skip 규약(verify-posture 선례: 라이브 부재는 red가
# 아니라 미평가 신호 + 비-0). 평가 **중** 쿼리 실패는 그대로 3(감사가 깨진 것 — 위장 금지).
kubectl cluster-info >/dev/null 2>&1 || guard_skip audit-orphan-pv "클러스터 접근 불가(KUBECONFIG/RBAC) — 라이브 감사 미평가"

rc=0

echo "== ① 고아 Released PV (PVC 삭제 + Retain 잔존) =="
pvs="$(kubectl get pv -o json)" || { echo "ERROR: kubectl get pv 실패" >&2; exit 3; }   # 쿼리 실패=비-0
released="$(printf '%s' "$pvs" | yq -r '.items[] | select(.status.phase == "Released") | .metadata.name + "\t" + (.spec.hostPath.path // .spec.local.path // "?") + "\t" + (.spec.storageClassName // "?")')"
if [ -z "$released" ]; then echo "  없음(쿼리 성공, Released 0건)"; else printf '%s\n' "$released"; rc=1; fi

echo "== ② 소비자 없는 PVC (Bound인데 어떤 파드도 마운트하지 않음 — cascade=orphan 잔재) =="
pvcs="$(kubectl get pvc -A -o json)" || { echo "ERROR: kubectl get pvc 실패" >&2; exit 3; }
pods="$(kubectl get pod -A -o json)" || { echo "ERROR: kubectl get pod 실패" >&2; exit 3; }

# 열거 바닥값 — PVC가 0건으로 읽히면 "고아 없음"과 구별할 수 없다(무측정). 판정·문구·마커는
# 커널(scan_floor) 소유로 승격(03) — rc는 이 가드의 어휘(3=쿼리 실패 계열)를 콜사이트가 보존한다
# (접근·도구 부재는 위에서 skip(4)으로 갈렸다 — 여긴 연결된 클러스터의 열거가 붕괴한 경우다).
n_pvc="$(printf '%s' "$pvcs" | yq -r '.items | length')"
scan_floor audit-orphan-pv "${n_pvc:-0}" "$(floor_of audit-orphan-pv 3)" || exit 3

# 소비 집합: 파드가 실제로 마운트한 (ns, claimName). ⚠️ **파드 기준**이다 — STS/Deployment 스펙만 보면
# 스케일 0이나 삭제된 컨트롤러의 PVC를 "사용 중"으로 오판한다.
# shellcheck disable=SC2016  # `$ns`는 **yq 변수**다(셸 확장이 아니라 yq의 `as $ns` 바인딩) — 홑따옴표가 맞다.
used="$(printf '%s' "$pods" | yq -r '.items[] | .metadata.namespace as $ns | .spec.volumes[]? | select(.persistentVolumeClaim) | $ns + "/" + .persistentVolumeClaim.claimName' | LC_ALL=C sort -u)"

unconsumed=""
while IFS= read -r key; do
  [ -n "$key" ] || continue
  grep -qxF "$key" <<<"$used" || unconsumed="${unconsumed}  ${key}"$'\n'
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
