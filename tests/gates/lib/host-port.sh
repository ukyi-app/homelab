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

# ── 컨테이너 기동 프리미티브 ──────────────────────────────────────────────────────
# publish 컨테이너를 띄우는 **처방 SSOT**. 예전엔 이 6불변식이 두 벌로 손 유지됐다
# (`lib/vmalert-e2e.sh`의 vmsingle · `alertmanager-render-e2e.sh`의 AM) — 출처가 같은 커밋이고
# 그 제목이 "처방이 한 소비자 lib에 갇히면 인접 표면은 원리적으로 그 처방을 못 받는다"였는데,
# 같은 커밋에서 같은 클래스가 한 층 위(포트 배정 → 컨테이너 기동)로 재발했다. AM 사본은 그 사실을
# 주석으로 **3회** 자백했다("형제 vme_start_vmsingle과 같은 처방·같은 판별자").
# 6불변식: `docker rm -f` 선행 · `--rm` 금지 · 실패를 메시지·종료코드로 비판별 · 서로 다른 포트로
#          재추첨 재시도 · 요청↔실제 매핑 대조 · 실패 시 `docker logs … tail -20`.
#
# ⚠️ **seam은 readiness 앞에서 끊는다.** vmsingle의 `/health` 본문 `OK*` 판정과 AM의 `/-/ready`는
#    **하네스-로컬 정책이다**(CONTEXT.md 「판정 어휘」 · ADR-0005가 지킨 축). 이 프리미티브가
#    readiness를 소유하면 그 ADR을 어긴다 — 여기서는 "매핑이 우리가 요청한 대로인가"까지만 본다.
#    그 대조가 통과한 뒤의 응답 해석은 소비자가 각자의 판정 어휘로 한다.
# ⚠️ 헤더 규율 승계: 이 함수도 `exit`하지 않는다. 실패는 stderr + rc 1이고, 종료 규약 번역은
#    소비자가 소유한다(vme = `vme_fault`의 exit 2, AM = exit 1).
HP_BIND_TRIES="${HP_BIND_TRIES:-3}"   # 첫 시도 + 재추첨 2회(판별에 필요한 최소치는 2다)

# $1=컨테이너 이름 $2=컨테이너 포트 $3=배제 포트 목록(공백 구분, 없으면 "")
# $4.. = `docker run`에 그대로 넘길 인자(이미지·이미지 인자 포함). **`-p`는 넣지 않는다** — 호스트
#        포트를 뽑는 주체가 이 함수이므로 publish 인자도 이 함수가 조립한다.
# → 성공 시 stdout에 **실제 배정된 호스트 포트**(재추첨이 일어나면 요청과 다른 값이다), rc 0.
#
# ⚠️ publish는 `127.0.0.1:` 접두로 고정한다. 접두 없는 `-p N:M`은 **전 인터페이스**에 연다 — 이
#    게이트들은 k3s가 도는 NUC에서도 도니 LAN에 포트를 여는 것 자체가 표면이고, 프로브(0.0.0.0
#    bind)가 실제 바인드보다 엄격하다는 관계도 그때만 성립한다. 손잡이를 두지 않는 것이 정책이다.
hp_run_published() {
  local name cport exclude port try=1 log="" err="" got a
  # ⚠️ **인자 검사가 `shift`보다 먼저 온다.** `shift 3`을 먼저 하면 인자가 모자랄 때 bash가 rc 1을
  #    내고, 소비자의 `set -e`가 그 rc로 셸을 통째로 죽인다 — `exit`을 한 줄도 안 썼는데 이 lib이
  #    종료를 소유하게 되는 자리다(헤더 규율 위반). 부족은 stderr + rc 1로만 알린다.
  if [ "$#" -lt 4 ]; then
    hp_err "hp_run_published: 인자가 모자란다(받은 것 $#개) — 사용법: hp_run_published <이름> <컨테이너포트> <배제목록> <docker run 인자…>"
    return 1
  fi
  name="$1"; cport="$2"; exclude="$3"
  shift 3
  case "$name" in '') hp_err "hp_run_published: 컨테이너 이름이 비었다"; return 1 ;; esac
  case "$cport" in '' | *[!0-9]*) hp_err "hp_run_published(${name}): 컨테이너 포트 '${cport}' 비수치"; return 1 ;; esac
  # ⚠️ **`--rm`을 받지 않는다.** 컨테이너가 기동 직후 죽으면(= 이 게이트들이 존재하는 이유인 설정
  #    회귀) `--rm`이 컨테이너를 즉시 지워 `docker port`도 `docker logs`도 실패한다 — 진단이 통째로
  #    사라지고, 남는 것은 "매핑을 확인할 수 없다"뿐인 **오진 서사**다. 정리는 소비자의 EXIT trap과
  #    아래 `docker rm -f`가 이미 소유한다. 인자에 섞이면 조용히 무시하지 않고 거부한다 — 무시하면
  #    호출부는 `--rm`이 걸렸다고 믿은 채 정리 책임을 놓는다.
  for a in "$@"; do
    case "$a" in
      --rm | --rm=*)
        hp_err "hp_run_published(${name}): --rm은 받지 않는다 — 컨테이너가 기동 직후 죽으면 docker port·docker logs가 함께 사라져 진단이 오진으로 둔갑한다. 정리는 호출자의 EXIT trap이 소유하라."
        return 1 ;;
    esac
  done
  # ⚠️ 밴드를 좁혀도 프로브~`docker run` 사이의 창(TOCTOU)은 남는다. 그 **잔여만** 재시도가 흡수한다 —
  #    재시도는 밴드·프로브의 대체재가 아니라 그 둘이 원리적으로 못 닫는 창의 마감재다.
  while :; do
    # ⚠️ 실패한 포트를 **배제 목록에 누적한다.** 재추첨이 같은 값을 다시 낼 수 있으면 "서로 다른
    #    포트에서 모두 실패했다"는 진단이 거짓이 되고, 판별자("서로 다른 포트로 다시 하면 되는가")
    #    자체가 성립하지 않는다. 확률에 기대지 않고 구조로 보장한다.
    # shellcheck disable=SC2086  # exclude는 공백 구분 목록이라 의도적으로 분할한다
    port="$(hp_pick_port $exclude)" || return 1
    # ⚠️ 실패한 `docker run -d`는 컨테이너를 **Created로 남긴다** → 같은 이름 재시도가 "name already
    #    in use"로 죽는다(재시도가 있는데도 회복하지 못한다). podman 전용 `--replace`는 docker
    #    양립성이 없으므로 명시적으로 지운다.
    docker rm -f "$name" >/dev/null 2>&1 || true
    if err="$(docker run -d --name "$name" -p "127.0.0.1:${port}:${cport}" "$@" 2>&1 >/dev/null)"; then
      break
    fi
    log="${log}
--- 시도 ${try} (port=${port}) ---
${err}"
    # ⚠️ 실패를 **메시지·종료코드로 판별하지 않는다** — 같은 podman도 pasta/rootlessport로 문자열이
    #    갈리고 CI dockerd는 또 다르다. venue 의존 판별자는 한 venue에서 조용히 무력해진다.
    #    판별자는 "서로 다른 포트로 다시 하면 되는가" 하나다.
    if [ "$try" -ge "$HP_BIND_TRIES" ]; then
      printf '%s\n' "$log" >&2
      hp_err "${name} 기동이 **서로 다른 포트** ${try}개에서 모두 실패했다 — 포트 경합만으로는 설명되지 않는다(위 런타임 stderr가 원인이다)."
      return 1
    fi
    # ⚠️ 조용한 재시도 금지 — 발생 사실이 로그에 없으면 경합 빈도가 관측되지 않는다.
    echo "RETRY (bind ${try}/${HP_BIND_TRIES}): ${name} port=${port} 기동 실패 — 포트를 새로 뽑아 재시도한다. 런타임 stderr: ${err}" >&2
    exclude="${exclude} ${port}"
    try=$(( try + 1 ))
  done
  [ -z "$err" ] || printf '%s\n' "$err" >&2   # 성공 경로의 런타임 경고도 그대로 흘린다
  [ "$try" -eq 1 ] || echo "RETRY (bind): ${name}이(가) ${try}번째 시도에서 성공했다." >&2
  # 읽어온 포트를 **쓰지 않고 대조한다.** 예전엔 `docker port` 출력을 그대로 믿었는데, 이제는 우리가
  # 고른 값과 다르면 즉시 비-0이다 — 경합으로 매핑이 어긋나면 소비자의 readiness 루프가 30~60초를
  # 통째로 태운 뒤에야 "not ready"로 죽어 원인이 안 보인다.
  # ⚠️ `|| got=""`가 **필요하다.** 소비자가 `set -o pipefail`인 채 이 함수를 부르면 `docker port`
  #    실패(컨테이너가 이미 죽었을 때 rc=125)가 명령 치환 rc로 올라와 **할당 단계에서** 죽는다 —
  #    아래 진단도 `docker logs`도 실행되지 않아 하네스가 stdout·stderr 0줄로 끝난다.
  got="$(docker port "$name" "${cport}/tcp" 2>/dev/null | head -1 | sed 's/.*://')" || got=""
  [ "$got" = "$port" ] || {
    hp_err "포트 매핑을 확인할 수 없다: ${name} 요청 ${port} / 실제 '${got}' — 컨테이너가 기동 직후 죽었거나(설정 회귀) 포트 경합이거나 런타임이 매핑을 바꿨다. 아래가 컨테이너 로그다:"
    docker logs "$name" 2>&1 | tail -20 >&2 || echo "  (컨테이너가 남아 있지 않아 로그를 읽지 못했다)" >&2
    return 1
  }
  printf '%s' "$port"
  return 0
}
