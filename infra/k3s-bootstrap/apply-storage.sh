#!/usr/bin/env bash
# 렌더링(고정 helper 이미지 + bulk 노드 경로 치환) 후 듀얼 local-path provisioner와 두
# StorageClass를 클러스터에 apply한다. bulk-ssd를 연결하기 전에, bulk가 **부트 디스크에 조용히
# 놓이지 않았는지** 게이트한다 — 그 상태는 cattle 재구축·재포맷에서 사용자 데이터를 잃는다.
#
# ⚠️ OrbStack 결박 제거(베어메탈 이식): 호스트 측 macOS `diskutil`(Device Location=External)과
#    VM 측 `orb -m k3s -u root … sh -s <probe` 간접이 **둘 다 사라졌다.** 여기가 곧 노드다.
#    판별 권위는 `diskutil`이 아니라 **디바이스 정체성**으로 옮겼다(bulk-gate-probe.sh 참조) —
#    "외장인가"보다 "부트 디스크와 같은가"가 지키려던 불변식에 정확히 대응한다.
#
# ── 국면 A (D4 한시 운용) ──────────────────────────────────────────────────────────────────
# 2TB M.2 장착 전까지 bulk를 노드 내장 디스크에 둔다. **기본은 거부**이고, 진입하려면 둘 다 필요:
#     BULK_TEMPORARY_ALLOWED=1                      명시 플래그(런타임 env — 실수로 켜지지 않게)
#     BULK_MIGRATION_WINDOW_UNTIL=YYYY-MM-DD        만료일(versions.env — git에 보이게)
# 하나만으로는 안 된다. 플래그는 "지금 이 실행에서 의도했다", 만료일은 "언제까지인지 정했다"이고
# 둘은 다른 주장이다. 만료 후에는 **요란하게 짖되 기동은 막지 않는다**(선례: check-credential-expiry.sh).
#
# 시임(테스트용): KUBECONFIG_PATH · BULK_RUN(권한 상승, 기본 sudo) · BULK_TODAY(오늘 날짜)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
export KUBECONFIG="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"
BULK_RUN="${BULK_RUN:-sudo}"
BULK_TODAY="${BULK_TODAY:-$(date +%Y-%m-%d)}"

command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not on PATH." >&2; exit 2; }

gate_fail() {
  {
    echo "FAIL: $1"
    echo "      이 게이트는 bulk-ssd가 부트 디스크에 조용히 놓여 재구축·재포맷에서 유실되는 것을 막는다."
    echo "      국면 A(D4 한시)로 진입하려면 **둘 다** 필요하다:"
    echo "        1) versions.env의 BULK_MIGRATION_WINDOW_UNTIL=YYYY-MM-DD  (지금: '${BULK_MIGRATION_WINDOW_UNTIL:-<비어 있음>}')"
    echo "        2) BULK_TEMPORARY_ALLOWED=1 $0"
  } >&2
  exit 1
}

# ── bulk 게이트 ────────────────────────────────────────────────────────────────────────────
ALLOW="${BULK_TEMPORARY_ALLOWED:-0}"
WINDOW="${BULK_MIGRATION_WINDOW_UNTIL:-}"

if [ "$ALLOW" = "1" ]; then
  # 플래그만으로는 못 연다 — 만료일이 git에 선언돼 있어야 한다(fail-closed).
  case "$WINDOW" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    "") gate_fail "BULK_TEMPORARY_ALLOWED=1 인데 BULK_MIGRATION_WINDOW_UNTIL이 비어 있다 — 한시 운용에 끝이 없으면 한시가 아니다." ;;
    *)  gate_fail "BULK_MIGRATION_WINDOW_UNTIL='${WINDOW}'의 형식이 YYYY-MM-DD가 아니다." ;;
  esac
  # 만료 판정: 대시를 떼고 정수 비교(POSIX 교집합 — `[[ ]]`도 date 연산도 쓰지 않는다).
  _t="$(printf '%s' "$BULK_TODAY" | tr -d '-')"
  _w="$(printf '%s' "$WINDOW" | tr -d '-')"
  echo "==> bulk 국면 A(D4 한시) — 만료 ${WINDOW}, 오늘 ${BULK_TODAY}"
  if [ "$_t" -gt "$_w" ]; then
    {
      echo "############################################################"
      echo "WARN: bulk 한시 운용 창이 ${WINDOW}에 만료됐다(오늘 ${BULK_TODAY})."
      echo "WARN: bulk가 아직 부트 디스크 위에 있다 — 재포맷 한 번에 사용자 데이터가 사라진다."
      echo "WARN: 국면 B(2TB M.2 마운트) 또는 만료일 갱신 중 하나를 지금 하라."
      echo "WARN: 기동은 막지 않는다 — 만료 하나로 클러스터가 안 뜨는 것은 이 창의 목적이 아니다."
      echo "############################################################"
    } >&2
  fi
fi

echo "==> bulk 백킹 스토어 검사: ${BULK_STORAGE_PATH} (권한 상승 ${BULK_RUN})…"
# ⚠️ probe를 권한 상승해 돌리는 이유: 쓰기 가능성 검사는 **local-path helper pod의 신원(root)** 을
#    반영해야 의미가 있다. owner 신원으로 돌리면 0700 root 마운트를 '쓰기 불가'로 오판한다.
$BULK_RUN env \
      BULK_STORAGE_PATH="$BULK_STORAGE_PATH" BULK_TEMPORARY_ALLOWED="$ALLOW" \
      sh "$SCRIPT_DIR/bulk-gate-probe.sh" \
  || gate_fail "bulk 백킹 스토어 검사 실패 — ${BULK_STORAGE_PATH}"

# LOCAL_PATH_HELPER_IMAGE + BULK_STORAGE_PATH 만 템플릿 대상이다; envsubst를 이 두 변수로
# 제한해 다른 것(예: setup 스크립트 내부의 $VOL_DIR)이 덮어써지지 않게 한다.
render() {
  if command -v envsubst >/dev/null 2>&1; then
    # envsubst의 SHELL-FORMAT 인자는 ${VAR} 이름의 리터럴 목록이다 — 작은따옴표 필수.
    # shellcheck disable=SC2016
    envsubst '${LOCAL_PATH_HELPER_IMAGE} ${BULK_STORAGE_PATH}' < "$1"
  else
    sed -e "s#\${LOCAL_PATH_HELPER_IMAGE}#${LOCAL_PATH_HELPER_IMAGE}#g" \
        -e "s#\${BULK_STORAGE_PATH}#${BULK_STORAGE_PATH}#g" "$1"
  fi
}

echo "==> Applying local-path provisioner (helper image: ${LOCAL_PATH_HELPER_IMAGE}; bulk path: ${BULK_STORAGE_PATH})…"
render "$SCRIPT_DIR/storage/local-path-provisioner.yaml" | kubectl apply -f -

echo "==> Applying StorageClasses…"
kubectl apply -f "$SCRIPT_DIR/storage/storageclass-standard.yaml"
kubectl apply -f "$SCRIPT_DIR/storage/storageclass-bulk-ssd.yaml"

echo "==> Storage applied. Verify with: kubectl get sc"
