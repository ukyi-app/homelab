#!/usr/bin/env bash
# 호스트 포트 배정 프리미티브 **SSOT** — 컨테이너/프로세스를 호스트 포트에 붙이는 게이트가 공유한다.
#
# 왜 lib인가: 이 레포에는 호스트 포트를 잡는 게이트가 여럿인데(AM 렌더 e2e의 AM publish + telegram
# mock, skopeo 타임아웃 스모크의 블랙홀 sink, vmalert 발화 e2e 6종의 vmsingle), PR #521이 만든 처방
# — 밴드 이전 + plain bind 프로브 + 재시도 — 이 `lib/vmalert-e2e.sh` **안에** 갇혀 있었다. 그래서
# 형제 하네스 둘은 같은 함정 위에 리터럴 포트를 그대로 박은 채 남았다(9093·8089·18443). 처방이
# 한 소비자의 사유물이면 **인접 표면은 원리적으로 그 처방을 못 받는다.**
# ⇒ 순수 프리미티브만 여기로 옮기고, vmalert lib은 이걸 source하는 소비자 중 하나가 된다.
# 완전성은 문서가 아니라 `scripts/check-host-ports.sh`가 강제한다(리터럴 호스트 포트 하드제로).
#
# 사용: `. "<repo>/tests/gates/lib/host-port.sh"` 후 `hp_pick_port`.
# ⚠️ **caller가 셸 옵션과 종료 규약을 소유한다.** 이 파일은 `set -e`를 건드리지 않고, trap을 걸지 않고,
#    `exit`하지 않는다 — 실패는 stderr + 비-0 rc로만 알린다. 소비자마다 실패 규약이 다르기 때문이다
#    (vmalert lib은 `vme_fault`의 exit 2, AM 하네스는 exit 1, skopeo 스모크는 자체 `fault`의 exit 2).
#    lib이 exit를 소유하면 그 셋 중 둘의 규약이 조용히 뒤집힌다.

# shellcheck shell=bash

# ── 호스트 포트 밴드 ──────────────────────────────────────────────────────────────
# 밴드는 상수지만 **검사는 라이브다** — 호스트가 예약 범위를 바꾸면 조용한 회귀가 아니라 즉사한다.
# 피해야 하는 예약이 둘이고, 예전 픽 범위(20000-39999)는 **둘 다** 밟았다.
#  ① 커널 ephemeral(`/proc/sys/net/ipv4/ip_local_port_range` — 이 NUC 32768-60999): 7232포트가 겹쳤다.
#     하네스 **자신의** curl(health 폴 60회 + 매 질의)이 그 대역에 아웃바운드 소스 포트를 계속 만든다
#     — 즉 혼자 돌아도 자기 포트를 빼앗겼다. 2026-08-19 실측 실패 포트 35704가 정확히 이 구간이다.
#  ② k8s NodePort(기본 30000-32767): 이 게이트는 k3s가 도는 NUC에서도 돈다. NodePort는 리스너가
#     아니라 **nat 규칙**이라 **어떤 bind 프로브로도 원리적으로 안 보인다**(실측 2026-08-20:
#     30953 = gateway/traefik:443인데 `ss -ltnp` 0건 · connect 프로브 FREE · **plain bind도 FREE** ·
#     그런데 `curl http://127.0.0.1:30953/health`는 Traefik의 `404 page not found`를 받는다).
#     프로브를 아무리 고쳐도 못 잡는다 — **밴드에서 통째로 빼는 것만이 이걸 닫는다.**
HP_PORT_LO="${HP_PORT_LO:-20000}"
HP_PORT_HI="${HP_PORT_HI:-29999}"
HP_NODEPORT_LO="${HP_NODEPORT_LO:-30000}"   # k8s 기본 --service-node-port-range(이 레포에 override 0건 — 실측)
HP_NODEPORT_HI="${HP_NODEPORT_HI:-32767}"
HP_PORT_RANGE_FILE="${HP_PORT_RANGE_FILE:-/proc/sys/net/ipv4/ip_local_port_range}"
HP_PICK_TRIES="${HP_PICK_TRIES:-40}"

hp_err() { echo "host-port: $*" >&2; }

_hp_disjoint() { [ "$HP_PORT_HI" -lt "$1" ] || [ "$HP_PORT_LO" -gt "$2" ]; }

# 밴드가 두 예약 중 하나라도 건드리면 비-0(판정 불가는 '통과'가 아니다).
# ⚠️ 메모이즈하지 않는다 — 소비자가 밴드를 바꿔 다시 부르는 것이 정상 경로이고(테스트·환경변수 주입),
#    상태를 들고 있으면 그 두 번째 호출이 첫 판정을 재사용해 **검사를 건너뛴다**. 비용은 proc 파일
#    한 번 읽기라 아낄 것이 없다.
hp_band_assert() {
  local lo hi
  case "$HP_PORT_LO" in '' | *[!0-9]*) hp_err "포트 밴드 하한 '${HP_PORT_LO}' 비수치"; return 1 ;; esac
  case "$HP_PORT_HI" in '' | *[!0-9]*) hp_err "포트 밴드 상한 '${HP_PORT_HI}' 비수치"; return 1 ;; esac
  [ "$HP_PORT_LO" -lt "$HP_PORT_HI" ] || { hp_err "포트 밴드 역전(${HP_PORT_LO}-${HP_PORT_HI})"; return 1; }
  [ -r "$HP_PORT_RANGE_FILE" ] || {
    hp_err "포트 밴드: ${HP_PORT_RANGE_FILE}를 읽을 수 없다 — ephemeral 범위와의 배타성을 확인할 수 없다."
    return 1
  }
  lo="$(awk 'NR==1{print $1}' "$HP_PORT_RANGE_FILE")"
  hi="$(awk 'NR==1{print $2}' "$HP_PORT_RANGE_FILE")"
  # ⚠️ **밴드는 유효 포트 안이어야 하고, span은 `RANDOM`의 사거리를 넘으면 안 된다.**
  #    `hp_pick_port`는 `HP_PORT_LO + RANDOM % span`으로 뽑는데 bash `RANDOM`은 0..32767이라, span이
  #    32768보다 크면 밴드 윗부분이 **조용히 도달 불가**가 된다(실측: 20000-59999으로 3000회 추첨하면
  #    최대값이 52765에 머문다). 밴드를 넓히는 것은 "포트가 모자란다"에 대한 자연스러운 처방이라
  #    실제로 시도될 수 있고, 그때 침묵하면 밴드 선언과 실제 추첨 범위가 갈린다.
  [ "$HP_PORT_HI" -le 65535 ] || { hp_err "포트 밴드 상한 ${HP_PORT_HI}가 유효 포트 범위(1-65535) 밖이다"; return 1; }
  [ "$HP_PORT_LO" -ge 1 ] || { hp_err "포트 밴드 하한 ${HP_PORT_LO}가 유효 포트 범위(1-65535) 밖이다"; return 1; }
  [ "$(( HP_PORT_HI - HP_PORT_LO + 1 ))" -le 32768 ] || {
    hp_err "포트 밴드 ${HP_PORT_LO}-${HP_PORT_HI}의 span이 32768을 넘는다 — bash RANDOM은 0..32767이라 윗부분이 조용히 도달 불가가 된다. 밴드를 좁히거나 추첨 방식을 바꿔라."
    return 1
  }
  case "$lo" in '' | *[!0-9]*) hp_err "포트 밴드: ephemeral 하한 '${lo}' 비수치"; return 1 ;; esac
  case "$hi" in '' | *[!0-9]*) hp_err "포트 밴드: ephemeral 상한 '${hi}' 비수치"; return 1 ;; esac
  _hp_disjoint "$lo" "$hi" || {
    hp_err "포트 밴드 ${HP_PORT_LO}-${HP_PORT_HI}가 커널 ephemeral ${lo}-${hi}와 겹친다 — 하네스 자신의 curl이 그 대역에서 소스 포트를 만든다. HP_PORT_LO/HP_PORT_HI를 옮겨라."
    return 1
  }
  _hp_disjoint "$HP_NODEPORT_LO" "$HP_NODEPORT_HI" || {
    hp_err "포트 밴드 ${HP_PORT_LO}-${HP_PORT_HI}가 k8s NodePort ${HP_NODEPORT_LO}-${HP_NODEPORT_HI}와 겹친다 — NodePort는 리스너가 아니라 nat 규칙이라 bind 프로브가 원리적으로 못 본다."
    return 1
  }
  return 0
}

# **bind 프로브**(SO_REUSEADDR 없음) — 런타임이 실제로 던지는 질문을 그대로 던진다. $1=포트 $2=바인드 주소.
#
# ⚠️ 예전 connect 프로브(`/dev/tcp`)는 **리스너만** 본다. 아웃바운드 연결의 로컬 소스 포트도, 리스너가
#    닫힌 뒤 살아남은 accepted 소켓도 FREE로 보고하는데 그 포트의 bind는 실패한다
#    (실측 2026-08-20: 두 경우 모두 connect=FREE / plain bind=EADDRINUSE(98)).
# ⚠️ **SO_REUSEADDR를 켜지 마라.** accepted 소켓이 잡은 포트에 대해 성공해버려 프로브가 런타임보다
#    관대해진다(실측: bind+REUSEADDR=FREE(오답), plain bind=BUSY(98)). plain bind는 어떤 런타임보다
#    같거나 엄격해 "못 쓰는 포트를 배정"하는 방향으로는 틀리지 않는다(TIME_WAIT 포트를 가끔 건너뛸 뿐이다).
# ⚠️ 기본 주소가 `0.0.0.0`인 것이 #521 이후 **새로 추가된 축**이다. `127.0.0.1` 프로브는 특정
#    인터페이스에만 있는 리스너를 못 본다 — 실측 2026-08-21, 같은 포트에 대해:
#      점유 주소            127.0.0.1 프로브   0.0.0.0 프로브
#      127.0.0.1            BUSY(98) ✅        BUSY(98) ✅
#      0.0.0.0              BUSY(98) ✅        BUSY(98) ✅
#      192.168.x.x(글로벌)  **FREE ❌**        BUSY(98) ✅
#    `0.0.0.0` 바인드는 그 포트를 **어느 주소로든** 잡고 있으면 실패하므로 셋 다 맞히는 엄격한
#    상위집합이다. 이 레포의 소비자 중 telegram mock과 블랙홀 sink는 실제로 `0.0.0.0`에 바인드한다
#    (컨테이너가 host-gateway로 붙으므로 루프백 전용 바인드가 불가능하다) — 그 둘에 대해
#    `127.0.0.1` 프로브는 런타임보다 **관대**해서 위 표의 세 번째 줄에서 조용히 틀린다.
#    엄격한 쪽으로 틀리는 대가는 "가끔 쓸 수 있는 포트를 건너뛰는 것"뿐이고 그건 재추첨이 흡수한다.
hp_port_free() {
  python3 -c 'import socket, sys
s = socket.socket()
try:
    s.bind((sys.argv[2], int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()' "$1" "${2:-0.0.0.0}"
}

# 밴드 안에서 빈 포트를 하나 골라 stdout에 쓴다. $1.. = **배제할 포트**(이미 뽑아 둔 것).
# ⚠️ 왜 **직접** 고르는가 — 런타임에 맡기는 `-p 127.0.0.1:0:<컨테이너포트>`(호스트 포트 0 = 커널이
#    임의 배정)는 **docker 전용 관용구다.** podman 5는 거부한다:
#    `parsing host port: port numbers must be between 1 and 65535 (inclusive), got 0`.
#    2026-08-19 NUC 이관에서 밟았다 — 맥은 OrbStack이 docker를 제공해 안 밟혔고, 리눅스 노드에는
#    docker 데몬을 올리지 않는다(docker0 브리지와 FORWARD 체인 조작이 k3s 파드 네트워킹을 깨는
#    전형적 경로다). 그래서 rootless podman을 쓰고, 포트 배정을 런타임에 맡기지 않는다.
# ⚠️ 배제 인자가 필요한 이유: `hp_port_free`는 프로브 소켓을 즉시 닫아 **아무것도 붙들지 않는다.**
#    한 하네스가 포트를 둘 뽑으면(AM publish + telegram mock) 두 번째 추첨이 첫 번째와 같은 값을
#    낼 수 있고, 그때 두 프로세스 중 하나가 EADDRINUSE로 죽는다. 확률은 낮지만(1/10000) 이 레포에서
#    낮은 확률의 포트 사고는 이미 두 번 났고 둘 다 원인이 로그에 없었다.
# shellcheck disable=SC2120  # 배제 인자는 **선택적**이다 — 포트를 하나만 쓰는 소비자는 인자 없이 부른다.
hp_pick_port() {
  local p n span tries=0 ex
  hp_band_assert || return 1
  span=$(( HP_PORT_HI - HP_PORT_LO + 1 ))
  while [ "$tries" -lt "$HP_PICK_TRIES" ]; do
    tries=$(( tries + 1 ))
    p=$(( HP_PORT_LO + RANDOM % span ))
    # ⚠️ `[ … ] && continue` 형태를 쓰지 않는다 — 소비자가 `set -e`인 채 이 함수를 명령 치환으로
    #    부르면 좌변이 거짓일 때의 AND-리스트 rc가 셸마다 다르게 읽힌다. 명시적 if가 규약 무관하다.
    ex=0
    for n in "$@"; do
      if [ "$n" = "$p" ]; then ex=1; break; fi
    done
    if [ "$ex" -eq 1 ]; then continue; fi
    if hp_port_free "$p"; then printf '%s' "$p"; return 0; fi
  done
  hp_err "빈 포트를 찾지 못했다(${HP_PORT_LO}-${HP_PORT_HI}에서 ${HP_PICK_TRIES}회) — 판정 불가는 '통과'가 아니다"
  return 1
}
