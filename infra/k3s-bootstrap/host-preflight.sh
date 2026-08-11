#!/usr/bin/env bash
# k3s 설치 **전에** 호스트가 갖춰야 할 전제를 단언한다. `orb-guard.sh`의 후계다 —
# 그쪽은 "OrbStack 머신이 정확히 하나 running"(전역 메모리 상한 전제)을 봤는데, 베어메탈에는
# 그 상한 자체가 없다. 남는 것은 **역할**이다: 설치 전에 환경이 온전한가.
#
# 왜 설치 **전**인가 — 아래 셋은 전부 사후 교정 비용이 크거나 불가능하다:
#   · 타임존이 틀리면 모든 CronJob 스케줄이 9시간 밀린다. 현재 이걸 단언하는 것이 레포에 없다.
#   · resolved 스텁이 켜진 채 k3s가 뜨면 **콜드스타트 교착**이다(아래 상세). 부팅 순서 문제라
#     "나중에 고치면 된다"가 성립하지 않는다 — 고치러 들어가려면 이름해석이 필요하다.
#   · 핀한 노드 IP가 실제 인터페이스에 없으면 k3s가 그 주소로 기동하지 못한다.
#
# ⚠️ **콜드스타트 교착의 정확한 기전** (실측으로 확정, 계획서 §2.5의 서술과 다르다):
#    systemd-resolved는 `0.0.0.0:53`이 아니라 `127.0.0.53`/`127.0.0.54`만 잡는다. svclb도 리터럴
#    바인드가 아니라 **hostPort**다. 즉 바인드 충돌은 애초에 없다. 진짜 문제는 CNI portmap이 심는
#    DNAT 규칙이다:
#        -A OUTPUT -m addrtype --dst-type LOCAL -j CNI-HOSTPORT-DNAT
#        -A CNI-DN-… -p udp --dport 53 -j DNAT --to-destination <AdGuard>:53
#    마지막 규칙에 **목적지 IP 제한이 없다.** `127.0.0.53`도 LOCAL이므로 노드 자신의 스텁 질의가
#    전부 AdGuard 파드로 끌려간다 → 부팅 시 AdGuard가 없으면 이미지 pull 불가 → AdGuard 영영 못 뜸.
#    스텁을 끄고 `/etc/resolv.conf`가 **비-loopback** 업스트림을 가리키면 그 패킷은 `--dst-type LOCAL`에
#    안 걸려 DNAT를 피한다.
#
# 시임(테스트용): PREFLIGHT_ROOT(기본 `/`) · PREFLIGHT_IP(기본 `ip`)
# yq 불필요. bash 3.2 호환. shellcheck clean.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
R="${PREFLIGHT_ROOT:-}"          # 파일 조회 접두 (테스트가 픽스처 트리를 준다)
PREFLIGHT_IP="${PREFLIGHT_IP:-ip}"
WANT_TZ="${HOST_TIMEZONE:-Asia/Seoul}"

fail() { echo "FAIL: host-preflight: $*" >&2; exit 1; }

# ── [1] 타임존 ─────────────────────────────────────────────────────────────────────────────
# CronJob 스케줄 전부의 전제다. 이걸 단언하는 것이 지금까지 레포에 **없었다**
# (cloud-init.yaml:7이 유일한 설정 지점이고 대응 테스트가 없다).
tz=""
[ -r "${R}/etc/timezone" ] && tz="$(tr -d '[:space:]' < "${R}/etc/timezone")"
[ -n "$tz" ] || fail "타임존을 읽지 못했다(${R}/etc/timezone) — 설정 전이면 timedatectl set-timezone ${WANT_TZ}"
printf '%s' "$tz" | grep -qxF "$WANT_TZ" \
  || fail "타임존이 '${tz}'다(기대 '${WANT_TZ}') — 모든 CronJob 스케줄이 밀린다. \`sudo timedatectl set-timezone ${WANT_TZ}\`"

# ── [2] systemd-resolved 스텁이 꺼져 있는가 ────────────────────────────────────────────────
# 드롭인이 본 파일을 이기므로 **둘 다** 본다. 마지막으로 선언된 값이 이긴다.
stub=""
for f in "${R}/etc/systemd/resolved.conf" "${R}"/etc/systemd/resolved.conf.d/*.conf; do
  [ -r "$f" ] || continue
  v="$(grep -E '^[[:space:]]*DNSStubListener[[:space:]]*=' "$f" | tail -1 | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]' || true)"
  [ -n "$v" ] && stub="$v"
done
[ -n "$stub" ] || fail "DNSStubListener 설정이 없다 — 기본값(yes)이면 노드 질의가 hostPort DNAT로 AdGuard에 끌려가 콜드스타트 교착이 된다. resolved.conf.d에 DNSStubListener=no를 둘 것"
printf '%s' "$stub" | grep -qxiE 'no|false|0' \
  || fail "DNSStubListener='${stub}'다(기대 no) — 콜드스타트 교착 경로가 열려 있다"

# ── [3] /etc/resolv.conf 업스트림이 비-loopback인가 ────────────────────────────────────────
# 스텁을 껐어도 resolv.conf가 127.x를 가리키면 같은 DNAT에 걸린다. 두 검사는 **다른 실패**다.
rc="${R}/etc/resolv.conf"
[ -r "$rc" ] || fail "${rc}를 읽지 못했다"
ns_total=0
ns_routable=0
while IFS= read -r addr; do
  [ -n "$addr" ] || continue
  ns_total=$((ns_total + 1))
  case "$addr" in 127.*|::1) : ;; *) ns_routable=$((ns_routable + 1)) ;; esac
done <<EOF
$(grep -E '^[[:space:]]*nameserver[[:space:]]+' "$rc" | awk '{print $2}')
EOF
# ⚠️ 열거 0건은 통과가 아니다 — nameserver 줄이 하나도 없으면 위 루프가 0회 돌고 조용히 지나간다.
[ "$ns_total" -ge 1 ] || fail "${rc}에 nameserver가 하나도 없다"
[ "$ns_routable" -ge 1 ] || fail "${rc}의 nameserver ${ns_total}건이 전부 loopback이다 — hostPort DNAT(--dst-type LOCAL)에 걸려 노드 이름해석이 클러스터에 의존하게 된다"

# ── [4] 핀한 노드 IP가 실제로 인터페이스에 있는가 ──────────────────────────────────────────
case "${K3S_NODE_IP:-}" in "") fail "K3S_NODE_IP 미설정 — versions.env 확인" ;; esac
addrs="$($PREFLIGHT_IP -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)" \
  || fail "인터페이스 주소를 열거하지 못했다(${PREFLIGHT_IP})"
printf '%s\n' "$addrs" | grep -qxF "$K3S_NODE_IP" \
  || fail "핀한 K3S_NODE_IP=${K3S_NODE_IP}가 어느 인터페이스에도 없다 — DHCP 예약(MAC d4:94:a9:26:95:3a)을 확인할 것. 이 주소로 k3s가 기동하지 못한다"

echo "OK: host-preflight (tz=${tz} · DNSStubListener=${stub} · routable nameserver ${ns_routable}/${ns_total} · node-ip ${K3S_NODE_IP} 존재)"
