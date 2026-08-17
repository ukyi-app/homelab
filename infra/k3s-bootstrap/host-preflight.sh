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
# CronJob 스케줄 전부의 전제다. 설정 지점은 host-config.sh --apply(timedatectl)이고, 여기서는
# **결과만** 본다.
#
# ⚠️ `/etc/timezone`을 읽으면 안 된다 — Ubuntu 26.04에는 그 파일이 **존재하지 않는다**(어떤
#    패키지도 소유하지 않는다, 실측 2026-08-11). 예전 검사는 타임존이 정상인 호스트에서도
#    "타임존을 읽지 못했다"로 죽었고, 그 진단이 제안하는 timedatectl은 그 파일을 만들지도 않는다
#    — **출구가 없는 게이트**였다. 진실원은 /etc/localtime 심링크와 timedatectl뿐이다.
# ⚠️ 진단 메시지에 백틱을 쓰지 않는다. 음성 @test가 `$output`을 셸 문자열에 보간해 재해석하므로
#    백틱 안의 처방이 **테스트 러너에서 실행된다**(실측으로 재현했다).
lt="${R}/etc/localtime"
[ -L "$lt" ] || fail "${lt}가 심링크가 아니다 — 타임존 진실원이 없다. sudo timedatectl set-timezone ${WANT_TZ}"
lt_target="$(readlink "$lt")"
case "$lt_target" in
  */zoneinfo/*) tz="${lt_target##*/zoneinfo/}" ;;
  *) fail "${lt}의 대상 '${lt_target}'이 zoneinfo 경로가 아니다 — 타임존을 판정할 수 없다" ;;
esac
printf '%s' "$tz" | grep -qxF "$WANT_TZ" \
  || fail "타임존이 '${tz}'다(기대 '${WANT_TZ}') — 모든 CronJob 스케줄이 밀린다. sudo timedatectl set-timezone ${WANT_TZ}"

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

# ── [3] /etc/resolv.conf의 리졸버가 **클러스터 독립**인가 ──────────────────────────────────
# 스텁을 껐어도 resolv.conf가 127.x를 가리키면 같은 DNAT에 걸린다. 두 검사는 **다른 실패**다.
#
# ⚠️ loopback만 거르는 것으로는 부족하다(실측 2026-08-11). tailscale이 `~.` 라우팅 도메인으로
#    **모든** 질의를 가져가고, 실업스트림 1순위가 100.100.100.100(MagicDNS)이다. 그 뒤는 tailnet
#    coordination server가 지정한 100.112.20.3 = **맥미니**, 즉 라이브 클러스터의 AdGuard다
#    (infra/tailscale/acl.tf의 tailscale_dns_nameservers). 100.100.100.100은 LOCAL 주소가 아니라
#    CNI DNAT는 피하지만(ip route get → table 52), 노드 이름해석이 통째로 클러스터에 의존하게 된다
#    — Mac을 끄는 순간 github.com조차 못 푼다(이미지 pull 불가 = §2.4 교착의 두 번째 얼굴).
#    tailnet 대역(CGNAT 100.64.0.0/10 · tailscale ULA fd7a:115c:a1e0::/48)은 그래서 거부한다.
rc="${R}/etc/resolv.conf"
[ -r "$rc" ] || fail "${rc}를 읽지 못했다"
ns_total=0
ns_routable=0
ns_tailnet=0
ns_tailnet_list=""
while IFS= read -r addr; do
  [ -n "$addr" ] || continue
  ns_total=$((ns_total + 1))
  case "$addr" in
    127.*|::1) continue ;;
  esac
  ns_routable=$((ns_routable + 1))
  # 100.64.0.0/10 = 100.64.0.0 ~ 100.127.255.255 을 글롭 4개로 정확히 덮는다.
  case "$addr" in
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|fd7a:115c:a1e0:*)
      ns_tailnet=$((ns_tailnet + 1))
      ns_tailnet_list="${ns_tailnet_list}${addr} " ;;
  esac
done <<EOF
$(grep -E '^[[:space:]]*nameserver[[:space:]]+' "$rc" | awk '{print $2}')
EOF
# ⚠️ 열거 0건은 통과가 아니다 — nameserver 줄이 하나도 없으면 위 루프가 0회 돌고 조용히 지나간다.
[ "$ns_total" -ge 1 ] || fail "${rc}에 nameserver가 하나도 없다"
[ "$ns_routable" -ge 1 ] || fail "${rc}의 nameserver ${ns_total}건이 전부 loopback이다 — hostPort DNAT(--dst-type LOCAL)에 걸려 노드 이름해석이 클러스터에 의존하게 된다"
[ "$ns_tailnet" -eq 0 ] || fail "${rc}의 nameserver ${ns_tailnet}건이 tailnet 대역이다(${ns_tailnet_list% }) — MagicDNS의 업스트림은 tailnet이 정하고 지금 그 값은 라이브 Mac의 AdGuard다. 노드 이름해석이 클러스터에 의존한다. 처방: tailscale set --accept-dns=false"

# ── [4] 핀한 노드 IP가 실제로 인터페이스에 있는가 ──────────────────────────────────────────
case "${K3S_NODE_IP:-}" in "") fail "K3S_NODE_IP 미설정 — versions.env 확인" ;; esac
addrs="$($PREFLIGHT_IP -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)" \
  || fail "인터페이스 주소를 열거하지 못했다(${PREFLIGHT_IP})"
printf '%s\n' "$addrs" | grep -qxF "$K3S_NODE_IP" \
  || fail "핀한 K3S_NODE_IP=${K3S_NODE_IP}가 어느 인터페이스에도 없다 — DHCP 예약(MAC d4:94:a9:26:95:3a)을 확인할 것. 이 주소로 k3s가 기동하지 못한다"

# ── [5] 스왑이 꺼져 있고 **재부팅해도 안 돌아오는가** ──────────────────────────────────────
# owner 확정(D-f): swapoff + /etc/fstab에서 /swap.img 제거. zram도 도입하지 않는다.
# 근거는 nuc-port-g2.md B3 — 요약하면 스왑은 OOM으로 죽어야 할 파드를 **느리게 만들 뿐 죽지 않게**
# 해서 메모리 원장의 fail-loud 경계를 무르게 한다. NUC은 60 GiB에 예산 10240 MiB라 없는 문제였다.
#
# 세 갈래는 **각각 다른 실패**다. 앞을 고쳐도 뒤가 남으면 다음 부팅에 조용히 되돌아온다:
#   (a) 지금 켜져 있는가            → /proc/swaps
#   (b) fstab 경유로 돌아오는가     → /etc/fstab  (systemd-fstab-generator → *.swap 유닛)
#   (c) zram 경유로 돌아오는가      → /etc/systemd/zram-generator.conf
# ⚠️ 여기서는 **열거 0건이 곧 원하는 상태**라 [3]식 "0건은 통과가 아니다" 바닥값을 쓸 수 없다.
#    대신 헤더 존재가 그 역할을 한다 — 파서가 실제 파일에 물렸다는 양성 증거다.
# ✅ **실측 2026-08-11**(D-f를 NUC에 적용한 직후, 스왑 0건 상태): 커널은 스왑이 하나도 없어도
#    헤더 1줄을 낸다 — 정확히 **39바이트 / 1줄**,
#    `Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority`.
#    (`swap_start`가 `*pos==0`에서 항상 `SEQ_START_TOKEN`을 돌려주고 `swap_show`가 그때 헤더를
#     찍는다.) 그러므로 헤더 부재는 "스왑 없음"이 아니라 **"파서가 안 물렸다"**로 읽는 것이 옳다.
#    → 조건 없이 요구한다. 이전 판은 "빈 파일도 허용"했는데, 그 관용은 실측 전의 보험이었고
#      실제로는 도달 불가능한 분기였다(= 죽은 코드).
sw="${R}/proc/swaps"
[ -r "$sw" ] || fail "${sw}를 읽지 못했다 — 스왑 부재를 단언할 수 없다(열거 0건을 '스왑 없음'으로 읽으면 안 된다)"
sw_hdr="$(awk 'NR == 1 && $1 == "Filename" { print 1 }' "$sw")"
[ "${sw_hdr:-0}" = "1" ] \
  || fail "${sw}의 첫 줄이 'Filename …' 헤더가 아니다 — 형식이 예상과 달라 열거를 믿을 수 없다(스왑 0건이어도 커널은 헤더를 낸다 — 실측)"
sw_n="$(awk 'NR == 1 && $1 == "Filename" { next } NF { n++ } END { print n+0 }' "$sw")"
sw_names="$(awk 'NR == 1 && $1 == "Filename" { next } NF { printf "%s ", $1 }' "$sw")"
[ "$sw_n" -eq 0 ] \
  || fail "활성 스왑 ${sw_n}건이 있다(${sw_names% }) — kubelet은 스왑 위에서 메모리 압박 판단을 잃고 원장의 RSS 기준선도 무의미해진다. sudo swapoff -a 후 fstab에서도 지울 것"

fs="${R}/etc/fstab"
[ -r "$fs" ] || fail "${fs}를 읽지 못했다 — 재부팅 시 스왑이 되돌아오는지 단언할 수 없다"
# 3번째 필드(<type>)가 정확히 swap인 **비주석** 줄만 센다.
# ⚠️ `$1 !~ /^#/` 가드가 load-bearing이다: `#/swap.img none swap sw 0 0`(우물정 뒤 공백 없음)은
#    $1="#/swap.img" · $3="swap"이라 가드 없이는 죽은 설정에 대고 실패한다.
# ⚠️ `$0 ~ /swap/` 류의 부분일치로 바꾸면 `tmpfs /tmp tmpfs …,noswap 0 0` 같은 정상 줄에 걸린다.
fs_n="$(awk 'NF && $1 !~ /^#/ && $3 == "swap" { n++ } END { print n+0 }' "$fs")"
[ "$fs_n" -eq 0 ] \
  || fail "${fs}에 swap 항목이 ${fs_n}건 남아 있다 — 지금 swapoff 돼 있어도 재부팅하면 돌아온다. 해당 줄을 지울 것"

# (c) zram은 fstab에 흔적을 남기지 않는다 — 재부팅 **후** (a)로만 잡히므로 선언 파일을 직접 본다.
for zc in "${R}/etc/systemd/zram-generator.conf" "${R}"/etc/systemd/zram-generator.conf.d/*.conf; do
  [ -e "$zc" ] || continue
  fail "${zc}가 있다 — zram은 도입하지 않기로 확정됐다(D-f). 재부팅하면 스왑이 돌아온다"
done

echo "OK: host-preflight (tz=${tz} · DNSStubListener=${stub} · routable nameserver ${ns_routable}/${ns_total}(tailnet ${ns_tailnet}) · node-ip ${K3S_NODE_IP} 존재 · swap 활성 ${sw_n}건/fstab ${fs_n}건)"
