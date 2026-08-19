#!/usr/bin/env bash
# 호스트 설정 계층 — `cloud-init.yaml`의 후계다.
#
# NUC은 **이미 설치·부팅된 기계**다(Ubuntu 26.04, 실측 `cloud-init status` → `disabled`).
# 즉 cloud-init이 실행될 기회가 아예 없다. 산출물은 first-boot 데이터가 아니라 **멱등 재실행
# 가능한 host-config**여야 한다 — 그래서 실파일 트리(`host-config/`) + 이 설치기다.
# 트리를 실파일로 두는 이유: `diff`가 곧 리뷰이고, **트리 열거가 곧 검사 도메인**이다.
#
# 모드:
#   --check   (기본) 선언된 트리 ↔ 디스크 **드리프트 검사**. sudo 불요. rc=0/1.
#   --apply   상태를 만든다. 권한 상승 필요(대화형 sudo — 아래 참조).
#
# ⚠️ **역할 분담을 흐리지 말 것.**
#     · 이 스크립트 `--check` = "커밋된 파일이 디스크에 그대로 있는가"(선언 ↔ 실제)
#     · `host-preflight.sh`   = "실효값이 맞는가"(타임존·스텁·리졸버·노드IP·스왑)
#    둘은 다른 실패다. 파일이 맞는데 유닛을 재시작 안 해서 실효값이 틀릴 수 있고, 반대로 누가
#    손으로 고쳐 실효값만 맞을 수도 있다. `host-up.sh`가 부르는 것은 후자다(설치 전 전제).
#
# ⚠️ **`--check`가 sudo-free인 범위는 "이 트리가 관리하는 파일"뿐이다**(실측). 같은 디렉토리의
#    `/etc/ssh/sshd_config.d/50-cloud-init.conf`는 600 root:root라 owner 신원으로 못 읽는다 —
#    그래서 sshd **실효값**은 `--check`가 원리적으로 알 수 없다(`sshd -T`/`-G` 둘 다 그 파일의
#    EACCES로 죽는다). 대신 우선순위 불변식(우리 드롭인이 사전순 최선두)을 검사한다. 아래 [3].
#
# ⚠️ `systemd-analyze verify`는 이 파일들의 검증 도구가 **될 수 없다**(실측): 유닛 파일이 아닌
#    모든 설정 파일을 `Failed to prepare filename …: Invalid argument` rc=1로 거부한다.
#    `.conf` 드롭인만의 한계가 아니라 `/etc/systemd/journald.conf` 본 파일도 마찬가지다.
#
# 시임(테스트용 — 이 스크립트의 실행 절반을 오프라인에서 증명한다):
#   HOSTCFG_ROOT  대상 루트 접두. 기본 `` (= 실제 `/`). 테스트가 픽스처 트리를 준다.
#   HOSTCFG_TREE  선언 트리 경로. 기본 `<이 파일 옆>/host-config`.
#   HOSTCFG_RUN   권한 상승 명령. 기본 `sudo`. 테스트는 argv 기록기를 꽂는다.
#
# bash 3.2 호환 · shellcheck clean · POSIX 교집합 유틸만(오너 머신은 macOS/BSD).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"

TREE="${HOSTCFG_TREE:-$SCRIPT_DIR/host-config}"
R="${HOSTCFG_ROOT:-}"
RUN="${HOSTCFG_RUN:-sudo}"

# sshd 드롭인의 파일명. `10-` 접두가 load-bearing이다 — 트리 파일 헤더 주석 참조.
SSHD_DIR="etc/ssh/sshd_config.d"
SSHD_DROPIN="10-k3s-node.conf"

# 트리가 선언하는 파일 수의 **바닥값**. 열거가 깨져 0건이 되면 "드리프트 없음"으로 조용히
# 통과한다 — 레포가 scan-floor로 도처에서 막는 그 클래스다. 수치는 소비자(=이 파일)가 소유한다.
# ⚠️ 트리에 파일을 더하면 **이 값도 같이 올려야** 바닥값이 계속 의미를 갖는다.
#    (3 → 4: 2026-08-15 `etc/tmpfiles.d/10-k3s-node.conf` 추가 — NVMe ASPM L1 비활성)
#    (4 → 5: 2026-08-18 `etc/systemd/network/10-netplan-wlo1.network.d/10-k3s-node.conf` 추가 —
#           R7이 여는 콜드스타트 교착 차단. DHCP가 광고하는 AdGuard(=노드 자신의 LAN IP)를
#           링크가 받지 않게 해 resolved.conf.d의 `DNS=`가 governing이 되게 한다.)
#    (5 → 7: 2026-08-19 `etc/systemd/system/files-data-backup.{service,timer}` 추가 — files 백업
#           국면 B 선행 배선. 이때 열거 글롭도 `.conf`만 보던 것에서 `.service`/`.timer`까지
#           넓혔다. 바닥값과 글롭을 **함께** 올린 첫 사례다 — 한쪽만 올리면 조용히 어긋난다.)
#    (7 → 8: 2026-08-20 `etc/systemd/system/unit-failure-notify@.service` 추가 — oneshot 실패의
#           **즉시 채널**. 신선도 알림은 원리적으로 주기보다 빨리 울 수 없어 1회 실패가 무성이었다.)
TREE_MIN=8

fail() { echo "FAIL: host-config: $*" >&2; exit 1; }

MODE="--check"
if [ "$#" -gt 0 ]; then MODE="$1"; shift; fi
[ "$#" -eq 0 ] || fail "인자가 너무 많다 — 사용법: host-config.sh [--check|--apply]"
case "$MODE" in
  --check|--apply) : ;;
  *) fail "알 수 없는 인자 '${MODE}' — 사용법: host-config.sh [--check|--apply]" ;;
esac

[ -d "$TREE" ] || fail "선언 트리가 없다(${TREE})"

# ── 트리 열거 ──────────────────────────────────────────────────────────────────────────────
# 상대경로가 곧 대상 절대경로다(`etc/…` → `${R}/etc/…`). find를 서브셸 cd 안에서 돌려 접두를
# 만들지 않는다. 열거 실패는 빈 문자열로 나타나고, 바로 아래 바닥값이 그것을 잡는다.
# ⚠️ 확장자가 곧 **검사 도메인 편입 조건**이다. `.service`/`.timer`를 넣지 않으면 systemd 유닛이
#    트리에 있어도 설치도 드리프트 검사도 안 되고 **조용히 무시된다**(2026-08-19 files 백업
#    배선을 넣으며 발각). 새 확장자를 쓸 때는 여기와 test_03의 미러를 함께 넓힐 것.
TREE_FILES="$( (cd "$TREE" && find . -type f \( -name '*.conf' -o -name '*.service' -o -name '*.timer' \)) | sed 's|^\./||' | LC_ALL=C sort )"
TREE_N="$(printf '%s\n' "$TREE_FILES" | awk 'NF { n++ } END { print n+0 }')"
[ "$TREE_N" -ge "$TREE_MIN" ] \
  || fail "선언 트리에서 ${TREE_N}건만 열거됐다(최소 ${TREE_MIN}) — 열거가 깨졌거나 파일이 사라졌다. 0건을 '드리프트 없음'으로 읽으면 안 된다"

# 🔴 **확장자 화이트리스트의 완전성** — 넓히기만 하면 다음 확장자가 똑같이 조용히 빠진다.
#    바닥값(TREE_MIN)은 이걸 못 잡는다: 열거 수와 바닥값이 **같은 글롭에서 나오므로** `.link` 하나를
#    더해도 둘 다 그대로다 → 통과. 픽스처(test_03의 setup)도 같은 글롭이라 안 들어간다.
#    그래서 **글롭 밖 파일이 존재하는 것 자체를 실패**로 만든다. 새 확장자가 필요하면 위 글롭을
#    넓히라고 여기서 요란하게 알려 준다 — 조용한 탈락이 아니라.
#    (2026-08-19: `.conf`만 보던 글롭 때문에 systemd 유닛이 통째로 빠질 뻔했다. 그 클래스를 닫는다.)
TREE_ALL_N="$( (cd "$TREE" && find . -type f) | awk 'NF { n++ } END { print n+0 }')"
[ "$TREE_N" -eq "$TREE_ALL_N" ] \
  || fail "선언 트리에 파일이 ${TREE_ALL_N}건인데 열거는 ${TREE_N}건이다 — 확장자 화이트리스트 밖의 파일은 **설치도 드리프트 검사도 안 된다**(조용히 탈락, --check는 초록). 위 find의 -name 목록을 넓히거나 그 파일을 트리에서 빼라"

# ── [1] 선언 ↔ 디스크 바이트 대조 ──────────────────────────────────────────────────────────
drift_n=0
drift_list=""
missing_n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  tgt="${R}/${f}"
  if [ ! -r "$tgt" ]; then
    missing_n=$((missing_n + 1))
    drift_n=$((drift_n + 1))
    drift_list="${drift_list}  - ${tgt} : 없거나 읽을 수 없다
"
    continue
  fi
  if ! cmp -s "${TREE}/${f}" "$tgt"; then
    drift_n=$((drift_n + 1))
    drift_list="${drift_list}  - ${tgt} : 내용이 선언(${TREE}/${f})과 다르다
"
  fi
done <<EOF
${TREE_FILES}
EOF

# ── [2] versions.env ↔ 트리 정합 ───────────────────────────────────────────────────────────
# 트리 파일은 렌더링하지 않으므로 값이 두 곳에 산다. 그 둘이 갈라지는 것을 여기서 막는다.
# (같은 대조를 test_03-host-config.bats가 게이트에서도 한다 — 여기 것은 노드 위 실행 경로다.)
resolved_decl="${TREE}/etc/systemd/resolved.conf.d/10-k3s-node.conf"
grep -qxF "DNS=${HOST_UPSTREAM_DNS}" "$resolved_decl" \
  || fail "선언 트리의 resolved 드롭인이 versions.env의 HOST_UPSTREAM_DNS=${HOST_UPSTREAM_DNS}와 다르다(${resolved_decl})"

# ── [3] sshd 드롭인 우선순위 ───────────────────────────────────────────────────────────────
# sshd_config는 **first obtained value wins**이고 드롭인은 본 파일 **앞에** Include된다(man).
# 즉 글롭 사전순으로 먼저 읽힌 파일이 이긴다 — systemd 드롭인(마지막이 이김)과 **정반대**다.
# 내용을 못 읽어도(600) 이름만으로 이 불변식은 검사할 수 있다. 디렉토리는 755라 열람 가능(실측).
earlier=""
earlier_n=0
sshd_abs="${R}/${SSHD_DIR}"
if [ -d "$sshd_abs" ]; then
  for c in "$sshd_abs"/*.conf; do
    [ -e "$c" ] || continue
    b="$(basename "$c")"
    [ "$b" != "$SSHD_DROPIN" ] || continue
    first="$(printf '%s\n%s\n' "$b" "$SSHD_DROPIN" | LC_ALL=C sort | head -1)"
    if [ "$first" != "$SSHD_DROPIN" ]; then
      earlier="${earlier}${b} "
      earlier_n=$((earlier_n + 1))
    fi
  done
fi

if [ "$MODE" = "--check" ]; then
  if [ "$drift_n" -ne 0 ] || [ "$earlier_n" -ne 0 ]; then
    echo "FAIL: host-config: 드리프트 ${drift_n}건 (부재 ${missing_n}건) · sshd 선행 드롭인 ${earlier_n}건" >&2
    [ -z "$drift_list" ] || printf '%s' "$drift_list" >&2
    [ "$earlier_n" -eq 0 ] \
      || echo "  - ${sshd_abs}/ 에 ${SSHD_DROPIN}보다 사전순 앞선 .conf가 있다(${earlier% }) — sshd는 먼저 읽힌 값이 이기므로 하드닝이 무력화된다" >&2
    echo "  적용: sudo가 필요하다 → ${0} --apply" >&2
    exit 1
  fi
  echo "OK: host-config --check (선언 ${TREE_N}건 전건 일치 · sshd 선행 드롭인 0건 · root=${R:-/})"
  echo "    실효값(타임존·resolved 스텁·리졸버·스왑)은 host-preflight.sh가 본다 — 여기서는 검사하지 않는다."
  exit 0
fi

# ── --apply ────────────────────────────────────────────────────────────────────────────────
# ⚠️ 여기부터는 **대화형**이다. owner의 sudo는 패스워드를 요구한다(실측, NOPASSWD 드롭인 없음).
#    그래서 이 경로는 CI/자동화에 배선하지 않는다 — 드리프트 감지(--check)만 무인 실행 가능하다.
echo "==> [1/6] 선언 트리 설치 (${TREE_N}건, 0644 root:root)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  tgt="${R}/${f}"
  $RUN mkdir -p "$(dirname "$tgt")"
  $RUN install -m 0644 -o root -g root "${TREE}/${f}" "$tgt"
  echo "    ${tgt}"
done <<EOF
${TREE_FILES}
EOF

echo "==> [2/6] 타임존 ${HOST_TIMEZONE}"
# 파일 트리로 표현하지 않는다: /etc/timezone은 Ubuntu 26.04에 **존재하지 않고**(어떤 패키지도
# 소유하지 않는다, 실측) 진실원은 /etc/localtime 심링크 + timedatectl이다. 손으로 파일을 만들면
# 두 진실원이 조용히 갈라진다.
$RUN timedatectl set-timezone "$HOST_TIMEZONE"

echo "==> [3/6] 스왑 제거 (owner 확정 D-f — zram 미도입)"
# 근거: 원래 의도(OOM 완충재)는 12 GiB VM에서 성립했다. NUC은 60 GiB에 limit 예산 10240 MiB라
# 없는 문제였고, 스왑은 OOM으로 죽어야 할 파드를 **느리게 만들 뿐 죽지 않게** 해 원장의
# fail-loud 경계를 무르게 한다. 상세는 nuc-port-g2.md B3.
$RUN swapoff -a
fstab="${R}/etc/fstab"
if awk 'NF && $1 !~ /^#/ && $3 == "swap" { found = 1 } END { exit !found }' "$fstab"; then
  _ft="${fstab}.pre-host-config.bak"
  $RUN cp -p "$fstab" "$_ft"
  _tmp="$(mktemp)"
  awk 'NF && $1 !~ /^#/ && $3 == "swap" { next } { print }' "$fstab" > "$_tmp"
  $RUN install -m 0644 -o root -g root "$_tmp" "$fstab"
  rm -f "$_tmp"
  echo "    ${fstab}에서 swap 항목 제거 (백업 ${_ft})"
else
  echo "    ${fstab}에 swap 항목 없음 — 무변경"
fi

echo "==> [4/6] 노드 이름해석을 클러스터 독립으로"
# ⚠️ resolved 드롭인만으로는 부족하다. tailscale이 `~.` 라우팅 도메인으로 **모든** 질의를
#    가져가고(실측: tailscale0 DNS Domain에 `~.`), 그 업스트림은 tailnet coordination server가
#    지정한 100.112.20.3 = **맥미니**, 즉 라이브 클러스터의 AdGuard다. 그대로 두면 Mac을 끄는
#    순간 NUC이 github.com조차 못 푼다 — 이미지 pull 불가.
#    `--accept-dns=false`는 **이 디바이스에만** 걸린다(tailnet 전역 설정 무변경).
command -v tailscale >/dev/null 2>&1 \
  || fail "tailscale이 PATH에 없다 — 노드가 tailnet DNS를 계속 받으면 이름해석이 라이브 Mac에 의존한다"
$RUN tailscale set --accept-dns=false
# DNSStubListener=no면 스텁 파일이 생기지 않는다. resolv.conf가 계속 127.0.0.53을 가리키면
# 이름해석이 통째로 죽으므로 실업스트림 목록으로 갈아끼운다(Ubuntu 기본과 같은 상대 심링크).
$RUN ln -sfn ../run/systemd/resolve/resolv.conf "${R}/etc/resolv.conf"

echo "==> [5/6] 노드 로컬 스토리지 디렉토리"
# bulk는 넣지 않는다 — D4 한시 운용(국면 A)의 경로·만료일이 미결(D-g)이고, 지금 만들면
# 어느 국면의 것인지 모르는 디렉토리가 생긴다.
$RUN install -d -m 0700 -o root -g root "${R}${INTERNAL_STORAGE_PATH}"

echo "==> [6/6] 유닛 반영"
# tmpfiles 줄은 부팅 때 systemd-tmpfiles-setup.service가 걸지만, --apply는 **지금** 상태를
# 만들어야 한다(재부팅을 요구하면 "적용했다"가 거짓이 된다). 대상이 없으면 `w`는 no-op이다.
$RUN systemd-tmpfiles --create "${R}/etc/tmpfiles.d/10-k3s-node.conf"
$RUN systemctl daemon-reload
$RUN systemctl restart systemd-resolved
$RUN systemctl restart systemd-journald
# 소켓 활성화(ssh.socket)면 연결마다 설정을 새로 읽으므로 try-*가 정확히 no-op이다.
$RUN systemctl try-reload-or-restart ssh.service

# 🔴 networkd 드롭인 반영 (2026-08-18 신설 — 그전까지 **설치만 하고 잠들어 있었다**).
#    위 주석의 원칙("재부팅을 요구하면 '적용했다'가 거짓이 된다")을 network 드롭인만 어기고 있었다:
#    `daemon-reload`도 `restart systemd-resolved`도 networkd에는 아무 영향이 없다.
#    그동안 링크는 DHCP가 준 DNS를 계속 쓰고, **링크별 DNS는 전역 `DNS=`보다 우선**하므로
#    resolved.conf.d의 `DNS=`(=HOST_UPSTREAM_DNS)가 무효였다. R7 이후 그 DHCP DNS는 라우터이고
#    라우터는 AdGuard로 포워딩하므로 결과는 **콜드스타트 교착의 부활**이다(#494가 닫은 문).
#    → host-preflight.sh [6]이 이제 실효값(`/run/systemd/netif/links/<ifindex>`)으로 이걸 잡는다.
#    ⚠️ `networkctl reload`만으로는 부족하다 — .network 파일을 다시 읽을 뿐 링크에 재적용하지 않는다.
#       `reconfigure`가 실제 적용이고, 그 사이 **주소가 약 5초 사라졌다 돌아온다**(DHCP 재획득).
#       그 주소는 K3S_NODE_IP이자 AdGuard LoadBalancer VIP다 — 그래서 미리 알린다.
#       `--apply`는 프로비저닝 시 1회 대화형 실행이므로(README) 이 순간 blip은 수용 가능하다.
if ls "$TREE"/etc/systemd/network/*.network.d/*.conf >/dev/null 2>&1; then
  $RUN networkctl reload
  cfg_iface="$(ip -o -4 addr show 2>/dev/null \
    | awk -v ip="${K3S_NODE_IP:-}" 'ip != "" && $4 ~ ("^" ip "/") { print $2; exit }')"
  if [ -n "$cfg_iface" ]; then
    echo "    ⚠️ networkctl reconfigure ${cfg_iface} — ${K3S_NODE_IP}가 약 5초간 사라졌다 돌아온다"
    $RUN networkctl reconfigure "$cfg_iface"
  else
    echo "    ⚠️ K3S_NODE_IP=${K3S_NODE_IP:-미설정}를 가진 인터페이스를 찾지 못했다 —" \
         "네트워크 드롭인이 **비활성인 채로 남았다**. 수동으로: sudo networkctl reconfigure <iface> (또는 재부팅)"
  fi
fi

echo "==> host-config 적용 완료. 다음: ${SCRIPT_DIR}/host-preflight.sh 로 실효값을 확인할 것"
