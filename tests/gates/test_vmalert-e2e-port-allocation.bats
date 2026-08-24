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
# ⇒ 처방은 세 겹이고 이 파일은 셋을 각각 문다: 밴드 이전(①②) · plain bind 프로브(③) ·
#    잔여 TOCTOU 재시도 + health **본문** 확인(오진 방지).
#
# hermetic — 스텁 docker/curl을 쓰고 실 컨테이너는 0개다. 실 소켓은 프로브 증인에서만 쓴다.
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
    if [ -e "$S/c-$name" ]; then
      echo "Error response from daemon: container name \"/$name\" is already in use" >&2
      exit 125
    fi
    if grep -qx "$hostport" "$S/failports" 2>/dev/null; then
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

# 밴드 검사만 따로 부른다. $1 = 검사 전에 끼울 셸 코드.
band_assert() {
  run env PATH="$STUB:$PATH" STUB_STATE="$STATE" bash -c "
    set -euo pipefail
    . '$LIB'
    $1
    _vme_band_assert
    echo BAND-OK
  "
}

@test "firing-e2e harnesses are enumerated and all allocate ports through the shared lib" {
  hs="$(git ls-files 'tests/gates/vmalert-*-firing-e2e.sh')"
  n="$(printf '%s\n' "$hs" | grep -c .)"
  # 열거 붕괴 방어 — 0건이면 아래 루프가 vacuous하게 통과한다(형제 test_vmalert-e2e-replay-timing과 동형).
  [ "$n" -ge 3 ]
  for f in $hs; do
    run grep -q 'vme_start_vmsingle' "$f"
    [ "$status" -eq 0 ]
  done
}

@test "the port band is disjoint from this host's live kernel ephemeral range" {
  # ★ 상수가 아니라 **라이브 커널 값**에 대해 판정한다. 밴드를 되돌리면(29999→39999) 이 lane만 red다.
  band_assert ""
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'BAND-OK'
}

@test "a band overlapping the ephemeral range fails closed instead of picking a port" {
  printf '20000\t60999\n' > "$TMP/eph"
  band_assert "VME_PORT_RANGE_FILE='$TMP/eph'"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF 'ephemeral'
}

@test "a band overlapping the k8s NodePort range fails closed (nat rules are invisible to any bind probe)" {
  # ★ 프로브 개선으로는 원리적으로 못 잡는 축 — 밴드에서 빼는 것이 유일한 처방이라 여기서 문다.
  band_assert "VME_PORT_LO=30000; VME_PORT_HI=30500"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF 'NodePort'
}

@test "an unreadable ephemeral range file fails closed (undecidable is not a pass)" {
  band_assert "VME_PORT_RANGE_FILE='$TMP/nonexistent-range'"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF '읽을 수 없다'
}

@test "the free-port probe reports a port held by a live socket as busy, and an unused port as free" {
  # ★ 프로브 증인 — 양성·음성 대조를 함께 건다. connect 프로브(/dev/tcp)로 되돌리면 양성 쪽이 red고,
  #   항상-BUSY로 망가뜨리면 음성 쪽이 red다. 실 소켓을 쓰는 유일한 lane이다.
  run env PATH="$STUB:$PATH" python3 - "$LIB" <<'PYWITNESS'
import socket, subprocess, sys
lib = sys.argv[1]
# 리스너를 닫고 accepted 소켓만 남긴다 — connect는 refused(FREE)라고 답하지만 bind는 EADDRINUSE다.
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); held = srv.getsockname()[1]; srv.listen(1)
cli = socket.socket(); cli.connect(("127.0.0.1", held))
acc, _ = srv.accept(); srv.close()

def probe(port):
    return subprocess.run(
        ["bash", "-c", f'. "{lib}"; _vme_port_free {port}'],
        capture_output=True).returncode

busy = probe(held)
free_sock = socket.socket(); free_sock.bind(("127.0.0.1", 0))
unused = free_sock.getsockname()[1]; free_sock.close()
free = probe(unused)
acc.close(); cli.close()
print(f"held={held} rc={busy} unused={unused} rc={free}")
if busy == 0:
    print("PROBE-FAILED: 살아있는 소켓이 붙든 포트를 FREE라고 답했다"); sys.exit(1)
if free != 0:
    print("PROBE-FAILED: 안 쓰는 포트를 BUSY라고 답했다(항상-BUSY 프로브는 무측정과 같다)"); sys.exit(1)
print("PROBE-OK")
PYWITNESS
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'PROBE-OK'
}

@test "a transient bind failure is retried on a different port and the retry is announced" {
  printf '21001\n' > "$STATE/failports"
  # 포트 선택을 결정적으로 만든다 — 확률적 단언은 flake의 씨앗이다.
  start_vmsingle "
    _vme_pick_port() { c=\$(cat '$STATE/cursor' 2>/dev/null || echo 1); echo \$((c+1)) > '$STATE/cursor'; printf '2100%s' \"\$c\"; }
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'BASE=http://127.0.0.1:21002'
  # 조용한 재시도 금지 — 발생 사실이 로그에 없으면 경합 빈도가 관측되지 않는다.
  printf '%s' "$output" | grep -qF 'RETRY (bind'
  # 같은 포트를 다시 쓰지 않았다.
  # ⚠️ `LC_ALL=C` 필수 — en_US 콜레이션은 서로 다른 값을 같다고 보고 하나를 버린다(#514의 fail-open).
  #    여기서 그 일이 나면 "서로 다른 포트 N개" 단언이 조용히 약해진다.
  run bash -c "LC_ALL=C sort -u '$STATE/ports' | grep -c ."
  [ "$output" -eq 2 ]
}

@test "the retry removes the Created leftover, otherwise the name collision makes every retry fail" {
  # ★ 실패한 `docker run -d`는 컨테이너를 Created로 남긴다. `docker rm -f`를 빼면 재시도가 전부
  #   "name already in use"로 죽는다 — 재시도가 있는데도 회복하지 못한다. 그 삭제를 여기서 문다.
  # ⚠️ 정규식이 아니라 고정 문자열로 지운다 — 패턴에 `|`·`$`가 들어가면 delimiter/메타문자로 삼켜져
  #    치환이 조용히 실패하고, 그러면 이 lane이 원본 lib을 검사해 vacuous하게 통과한다.
  grep -vF 'docker rm -f "$name"' "$LIB" > "$TMP/lib-norm.sh"
  # lib은 형제 host-port.sh를 BASH_SOURCE 기준으로 찾는다 — 변이 사본 옆에 같이 둬야 한다.
  # (없으면 lib이 fail-closed로 죽어 이 레인이 **아래 단언과 무관한 이유로** red가 된다.)
  cp "$ROOT/tests/gates/lib/host-port.sh" "$TMP/host-port.sh"
  run grep -cF 'docker rm -f "$name"' "$TMP/lib-norm.sh"
  [ "$output" -eq 0 ]
  # cleanup 쪽 `docker rm -f "$c"`는 남아 있어야 한다(지우려던 것만 정확히 지웠다는 대조).
  run grep -cF 'docker rm -f "$c"' "$TMP/lib-norm.sh"
  [ "$output" -eq 1 ]
  printf '21001\n' > "$STATE/failports"
  run env PATH="$STUB:$PATH" STUB_STATE="$STATE" bash -c "
    set -euo pipefail
    . '$TMP/lib-norm.sh'
    VME_NET=testnet
    _vme_pick_port() { c=\$(cat '$STATE/cursor' 2>/dev/null || echo 1); echo \$((c+1)) > '$STATE/cursor'; printf '2100%s' \"\$c\"; }
    vme_start_vmsingle vm-test v1.0.0
  "
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF 'already in use'
}

@test "a permanent bind failure exits 2 after distinct ports and surfaces the runtime stderr verbatim" {
  printf '21001\n21002\n21003\n21004\n' > "$STATE/failports"
  start_vmsingle "
    _vme_pick_port() { c=\$(cat '$STATE/cursor' 2>/dev/null || echo 1); echo \$((c+1)) > '$STATE/cursor'; printf '2100%s' \"\$c\"; }
  "
  [ "$status" -eq 2 ]
  # 원본 stderr를 삼키면 진단이 사라진다.
  printf '%s' "$output" | grep -qF 'STUBFAIL-COOKIE'
  printf '%s' "$output" | grep -qF 'HARNESS FAULT'
  # 같은 포트를 반복한 것이 아니라 **서로 다른** 포트에서 실패했음을 단언한다.
  # ⚠️ `LC_ALL=C` 필수 — en_US 콜레이션은 서로 다른 값을 같다고 보고 하나를 버린다(#514의 fail-open).
  #    여기서 그 일이 나면 "서로 다른 포트 N개" 단언이 조용히 약해진다.
  run bash -c "LC_ALL=C sort -u '$STATE/ports' | grep -c ."
  [ "$output" -eq 3 ]
}

@test "a health body from someone else is a fault, not a not-ready timeout" {
  # ★ NodePort DNAT의 서명이 정확히 이것이다 — run도 port 대조도 통과하는데 남의 답이 온다.
  #   예전 코드는 이 상태를 60×0.5s 태운 뒤 "not ready"로 오진했다.
  printf '404 page not found\n' > "$STATE/health-body"
  start_vmsingle ""
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF '다른 서비스로 라우팅'
  run bash -c "printf '%s' \"$output\" | grep -c 'not ready' || true"
  [ "$output" -eq 0 ]
}
