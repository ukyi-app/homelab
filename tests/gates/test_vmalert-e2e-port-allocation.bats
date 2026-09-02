#!/usr/bin/env bats
# 발화 e2e 하네스의 **호스트 포트 배정** 계약 — 컨테이너를 띄우기 전에 고른 포트가 실제로 쓸 수 있는
# 포트인지, 그리고 못 쓸 때 조용히 오진하지 않는지를 본다.
#
# 왜 이 게이트가 필요한가: 이 계열의 실패는 **RED가 아니라 오진**으로 나타난다. 예전 구현은
# 20000-39999에서 포트를 뽑고 `/dev/tcp` connect로 빈지 확인했는데, 그 범위와 프로브가 각각 틀렸다.
#   ① 밴드가 커널 ephemeral(이 NUC 32768-60999)과 7232포트 겹쳤다 — 하네스 **자신의** curl이 그
#      대역에 아웃바운드 소스 포트를 만들므로 혼자 돌아도 자기 포트를 빼앗겼다(2026-08-19 실측
#      실패 포트 35704가 정확히 이 구간).
#   ② 밴드가 k8s NodePort(30000-32767)를 통째로 포함했다. NodePort는 리스너가 아니라 **nat 규칙**이라
#      connect로도 bind로도 **원리적으로 안 보인다**(실측 2026-08-20: 30953 = gateway/traefik:443인데
#      `ss -ltnp` 0건 · connect FREE · plain bind도 FREE · 그런데 curl은 Traefik의 404를 받는다).
#      컨테이너는 정상 기동하고 `docker port` 대조도 통과하므로, 예전 코드는 30초를 태운 뒤
#      "not ready"로 죽었다 — 원인이 로그 어디에도 없다.
#   ③ connect 프로브는 **리스너만** 본다. 아웃바운드 소스 포트도, 리스너가 닫힌 뒤 남은 accepted
#      소켓도 FREE라고 답하는데 그 포트의 bind는 EADDRINUSE(98)로 실패한다(실측).
#
# ⇒ 처방은 세 겹이고 이 파일이 무는 것은 그중 **이 lib이 아직 소유한 축**이다: 밴드 손잡이(①②)가
#    프리미티브에 실제로 닿는가 · 잔여 TOCTOU 재시도 · health **본문** 확인(오진 방지) ·
#    그리고 프리미티브의 비-0 rc가 이 lib의 종료 규약(HARNESS FAULT = exit 2)으로 번역되는가.
#
# ⚠️ **기동 6불변식과 plain bind 프로브(③)의 증인은 여기가 아니다** — 그 처방의 정의처가
#    `tests/gates/lib/host-port.sh`로 옮겨갔고(`hp_run_published`·`hp_port_free`), 증인도 함께
#    `tests/gates/test_host-ports.bats`로 갔다. 여기에 사본을 남기면 처방이 두 벌이 되던 그 병을
#    테스트 층에서 되풀이한다. 여기 남는 것은 **어댑터**(VME_* 손잡이 · rc 번역 · readiness)뿐이다.
#
# hermetic — 스텁 docker/curl을 쓰고 실 컨테이너는 0개다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  LIB="$ROOT/tests/gates/lib/vmalert-e2e.sh"
  TMP="$(mktemp -d)"
  STUB="$TMP/bin"; STATE="$TMP/state"
  mkdir -p "$STUB" "$STATE"

  # hermetic docker 스텁 — **이름 유일성**과 **포트 bind 실패**를 모델링한다.
  # 이름 유일성이 없으면 `docker rm -f` 삭제 뮤테이션이 조용히 통과한다(그 자리가 실제 결함이었다).
  cat > "$STUB/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
S="$STUB_STATE"
case "$1" in
  network) exit 0 ;;
  logs)    exit 0 ;;
  rm)  shift; while [ "$1" = "-f" ]; do shift; done; rm -f "$S/c-$1"; exit 0 ;;
  port) cat "$S/mapped" 2>/dev/null; exit 0 ;;
  run)
    name=""; hostport=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name="$2"; shift ;;
        -p) hostport="${2#127.0.0.1:}"; hostport="${hostport%%:*}"; shift ;;
      esac
      shift
    done
    printf '%s\n' "$hostport" >> "$S/ports"
    # 시도 **횟수**로도 실패시킨다 — 포트별(failports) 픽스처는 어느 포트가 먼저 뽑힐지에 의존해
    # 밴드를 좁혀도 결정적이지 않다(첫 추첨이 성공 포트를 집으면 재시도 레인이 통째로 vacuous하다).
    n=$(cat "$S/attempts" 2>/dev/null || echo 0); n=$(( n + 1 )); printf '%s\n' "$n" > "$S/attempts"
    if [ -e "$S/c-$name" ]; then
      echo "Error response from daemon: container name \"/$name\" is already in use" >&2
      exit 125
    fi
    if [ "$n" -le "$(cat "$S/failfirst" 2>/dev/null || echo 0)" ] || grep -qx "$hostport" "$S/failports" 2>/dev/null; then
      : > "$S/c-$name"   # ⚠️ 실패한 run도 컨테이너를 Created로 남긴다(docker/podman 공통 의미론)
      echo "STUBFAIL-COOKIE rootlessport listen tcp 127.0.0.1:$hostport: bind: address already in use" >&2
      exit 126
    fi
    : > "$S/c-$name"
    printf '127.0.0.1:%s\n' "$hostport" > "$S/mapped"
    exit 0 ;;
esac
exit 0
DOCKEREOF

  # curl 스텁 — /health 본문을 픽스처가 정한다.
  cat > "$STUB/curl" <<'CURLEOF'
#!/usr/bin/env bash
cat "$STUB_STATE/health-body" 2>/dev/null
exit 0
CURLEOF
  chmod +x "$STUB/docker" "$STUB/curl"
  printf 'OK\n' > "$STATE/health-body"
}

teardown() { rm -rf "$TMP"; }

# lib을 source해 vme_start_vmsingle을 부른다. $1 = source 직후에 끼울 셸 코드(픽스처 주입).
start_vmsingle() {
  run env PATH="$STUB:$PATH" STUB_STATE="$STATE" bash -c "
    set -euo pipefail
    . '$LIB'
    VME_NET=testnet
    $1
    vme_start_vmsingle vm-test v1.0.0
    printf 'BASE=%s\n' \"\$VME_BASE\"
  "
}

# 밴드 손잡이만 따로 부른다(VME_* → HP_* 배선의 **양성 대조**). $1 = 검사 전에 끼울 셸 코드.
band_assert() {
  run env PATH="$STUB:$PATH" STUB_STATE="$STATE" bash -c "
    set -euo pipefail
    . '$LIB'
    $1
    _vme_hp_sync
    hp_band_assert
    echo BAND-OK
  "
}

@test "firing-e2e harnesses boot through vme_leg and never docker-run vmsingle inline (ports stay lib-allocated)" {
  hs="$(git ls-files 'tests/gates/vmalert-*-firing-e2e.sh')"
  n="$(printf '%s\n' "$hs" | grep -c .)"
  # 열거 붕괴 방어 — 0건이면 아래 루프가 vacuous하게 통과한다(형제 test_vmalert-e2e-replay-timing과 동형).
  [ "$n" -ge 6 ]
  for f in $hs; do
    # d5·09 이후 기동은 vme_leg(레그 조립 — start·포트 추첨을 lib 내부에서 한다) 경유가 유일 표준이다.
    run grep -qE '^[[:space:]]*vme_leg ' "$f"
    [ "$status" -eq 0 ]
    # 이 레인의 고유 축: vmsingle을 인라인 docker run으로 띄우면 포트 추첨도 기동 6불변식도
    # (hp_pick_port·hp_run_published) 그 사이트만 빠진다 — 밴드·프로브·재시도·매핑 대조 전부다.
    run grep -c 'docker run.*victoria-metrics' "$f"
    [ "$output" = "0" ]
  done
}

@test "the VME_ band handles reach the primitive and stay disjoint from this host's live kernel ephemeral range" {
  # ★ 상수가 아니라 **라이브 커널 값**에 대해 판정한다. 밴드를 되돌리면(29999→39999) 이 lane만 red다.
  #   동시에 `_vme_hp_sync`(VME_* → HP_*) 배선의 양성 대조다 — 그 줄을 지우면 아래 음성 레인들이
  #   전부 "밴드를 흔들었는데 아무 일도 안 난다"로 조용히 뒤집힌다.
  band_assert ""
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'BAND-OK'
}

@test "a band overlapping the ephemeral range fails closed before any container is started" {
  # ★ 밴드 판정은 **기동 경로에서** 물어야 한다 — 검사 함수를 직접 부르는 레인만 있으면 그 검사가
  #   `vme_start_vmsingle`에서 떨어져 나가도 초록이다. 그래서 실제 start를 태우고,
  #   docker run이 **한 번도** 불리지 않았음을 함께 단언한다(판정 불가는 '통과'가 아니라 기동 금지다).
  printf '20000\t60999\n' > "$TMP/eph"
  start_vmsingle "VME_PORT_RANGE_FILE='$TMP/eph'"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF 'ephemeral'
  [ ! -s "$STATE/ports" ]
}

@test "a band overlapping the k8s NodePort range fails closed (nat rules are invisible to any bind probe)" {
  # ★ 프로브 개선으로는 원리적으로 못 잡는 축 — 밴드에서 빼는 것이 유일한 처방이라 여기서 문다.
  start_vmsingle "VME_PORT_LO=30000; VME_PORT_HI=30500"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF 'NodePort'
  [ ! -s "$STATE/ports" ]
}

@test "an unreadable ephemeral range file fails closed (undecidable is not a pass)" {
  start_vmsingle "VME_PORT_RANGE_FILE='$TMP/nonexistent-range'"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF '읽을 수 없다'
  [ ! -s "$STATE/ports" ]
}

@test "a transient bind failure is retried on a different port and the retry is announced" {
  # ★ 실패는 **시도 횟수**로 주입한다. 포트별 픽스처(failports)는 어느 포트가 먼저 뽑히느냐에
  #   의존해 결정적이지 않다 — 첫 추첨이 성공 포트를 집으면 재시도가 아예 안 일어나 이 레인이
  #   통째로 vacuous하다. 확률적 단언은 flake의 씨앗이다.
  # ⚠️ 픽스처 밴드는 프로덕션 밴드(20000-29999) **밖**에 둔다. CI에서 이 스위트는 발화 e2e 6종과
  #   **동시에** 도는데, 프로덕션 밴드 안의 고정 포트를 잡으면 그 하네스들과 경합해 이 레인이
  #   간헐적으로 red가 된다(형제 test_host-ports.bats의 배제 레인과 같은 규율).
  printf '1\n' > "$STATE/failfirst"
  start_vmsingle "VME_PORT_LO=19401; VME_PORT_HI=19402"
  [ "$status" -eq 0 ]
  out="$output"
  # 조용한 재시도 금지 — 발생 사실이 로그에 없으면 경합 빈도가 관측되지 않는다.
  printf '%s' "$out" | grep -qF 'RETRY (bind'
  # ★ 같은 포트를 다시 쓴 것이 아니라 **서로 다른** 포트로 재시도했다.
  # ⚠️ `LC_ALL=C` 필수 — en_US 콜레이션은 서로 다른 값을 같다고 보고 하나를 버린다(#514의 fail-open).
  #    여기서 그 일이 나면 "서로 다른 포트 N개" 단언이 조용히 약해진다.
  run bash -c "LC_ALL=C sort -u '$STATE/ports' | grep -c ."
  [ "$output" -eq 2 ]
  # ★ 그리고 lib이 쓰는 BASE는 **두 번째** 시도의 포트다 — 프리미티브가 첫 요청값을 그대로 되돌려주면
  #   하네스는 아무도 안 듣는 포트에 질의하고 60×0.5s 뒤 "not ready"로 오진한다.
  second="$(sed -n '2p' "$STATE/ports")"
  [ -n "$second" ]
  printf '%s' "$out" | grep -qF "BASE=http://127.0.0.1:${second}"
}

@test "a permanent bind failure exits 2 after distinct ports and surfaces the runtime stderr verbatim" {
  printf '9\n' > "$STATE/failfirst"   # 모든 시도를 실패시킨다(HP_BIND_TRIES=3보다 크게)
  start_vmsingle "VME_PORT_LO=19411; VME_PORT_HI=19413"
  [ "$status" -eq 2 ]
  # 원본 stderr를 삼키면 진단이 사라진다.
  printf '%s' "$output" | grep -qF 'STUBFAIL-COOKIE'
  # ★ **종료 규약 번역**이 이 어댑터의 유일한 일이다. hp_run_published는 exit하지 않고 rc 1만 내므로,
  #   그 rc를 HARNESS FAULT(exit 2)로 옮기지 않으면 `set -e` 아래에서 rc 1이 그대로 새어 나가
  #   이 lib의 규약(하네스 고장 = 2)이 조용히 뒤집힌다. 형제 AM 하네스는 같은 rc를 exit 1로 옮긴다.
  printf '%s' "$output" | grep -qF 'HARNESS FAULT'
  # 같은 포트를 반복한 것이 아니라 **서로 다른** 포트에서 실패했음을 단언한다.
  # ⚠️ `LC_ALL=C` 필수 — en_US 콜레이션은 서로 다른 값을 같다고 보고 하나를 버린다(#514의 fail-open).
  run bash -c "LC_ALL=C sort -u '$STATE/ports' | grep -c ."
  [ "$output" -eq 3 ]
}

@test "a health body from someone else is a fault, not a not-ready timeout" {
  # ★ NodePort DNAT의 서명이 정확히 이것이다 — run도 port 대조도 통과하는데 남의 답이 온다.
  #   예전 코드는 이 상태를 60×0.5s 태운 뒤 "not ready"로 오진했다.
  #   readiness 판정은 **하네스-로컬 정책**이라 프리미티브로 올리지 않았다(docs/adr/0005) — 그 결정이
  #   실제로 이 lib 안에서 살아 있는지 여기서 문다.
  printf '404 page not found\n' > "$STATE/health-body"
  start_vmsingle ""
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF '다른 서비스로 라우팅'
  run bash -c "printf '%s' \"$output\" | grep -c 'not ready' || true"
  [ "$output" -eq 0 ]
}
