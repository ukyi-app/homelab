#!/usr/bin/env bats
# bulk 게이트의 노드 측 로직(bulk-gate-probe.sh)을 직접 검증한다 — 라이브 노드 없이.
#
# ⚠️ 이 스위트가 지키는 것은 **단 하나의 불변식**이다: bulk-ssd가 부트 디스크에 조용히 놓이지
#    않는다. OrbStack 시절 그 증명의 권위는 macOS `diskutil`(Device Location=External) stub이었고,
#    베어메탈에서는 **디바이스 정체성**(bulk의 백킹 디바이스 vs `/`)으로 옮겼다.
#    국면 A(D4 한시)가 바로 그 금지 상태를 한시 허용하므로, 여기서 증명까지 같이 잃기 쉽다.
load test_helper

PROBE="$BOOTSTRAP_DIR/bulk-gate-probe.sh"

setup() {
  STUBDIR="$(mktemp -d)"; WORK="$(mktemp -d)"
  PATH="$STUBDIR:$PATH"; export PATH STUBDIR WORK
  # 가짜 findmnt — `-no TARGET <path>` / `-no SOURCE <path>` 두 형태만 흉내낸다.
  #   FM_BULK_IS_MP=0  bulk 경로가 마운트포인트가 아닌 상태(= 루트 위 평범한 디렉토리)
  #   FM_BULK_SRC      bulk의 백킹 디바이스. 기본은 루트와 **다른** 디바이스(국면 B 형태)
  cat >"$STUBDIR/findmnt" <<'EOF'
#!/usr/bin/env sh
col=""; path=""; hasT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -T) hasT=1; shift ;;
    -no) col="$2"; shift 2 ;;
    -*) shift ;;
    *) path="$1"; shift ;;
  esac
done
root_out() { if [ "$col" = "TARGET" ]; then echo "/"; else echo "${FM_ROOT_SRC:-/dev/mapper/vg-root}"; fi; }
[ "$path" = "/" ] && { root_out; exit 0; }
if [ "${FM_BULK_IS_MP:-1}" != "1" ]; then
  # 실제 findmnt 동작: 인자 없이 주면 마운트포인트가 아니라 매치 실패(rc=1). `-T`를 주면
  # **감싸는 마운트로 resolve**되어 `/`를 성공 반환한다 — 즉 `-T`는 "여기가 마운트인가"에
  # 답하지 못한다. 스텁이 이 비대칭을 그대로 모사해야 게이트의 진짜 방어선이 드러난다.
  [ "$hasT" = "1" ] || exit 1
  root_out; exit 0
fi
if [ "$col" = "TARGET" ]; then echo "$path"; else echo "${FM_BULK_SRC:-/dev/nvme1n1p1}"; fi
EOF
  chmod +x "$STUBDIR/findmnt"
}
teardown() { rm -rf "$STUBDIR" "$WORK"; }

@test "passes when bulk is a mountpoint on a DIFFERENT device (phase B shape)" {
  BULK_STORAGE_PATH="$WORK" run sh "$PROBE"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- 'bulk-probe-ok'
  printf '%s' "$output" | grep -qF -- 'dev=/dev/nvme1n1p1'
  [ -z "$(ls -A "$WORK")" ]                 # sentinel이 정리됐다
}

@test "exit 11 when the bulk path is NOT a mountpoint (a plain dir means the boot disk)" {
  # ⚠️ 이 게이트의 진짜 방어선은 "`-T`를 안 쓴다"가 아니라 **TARGET을 경로와 등호 비교한다**는
  #    것이다. `-T`를 쓰더라도 평범한 디렉토리는 TARGET=`/`를 돌려주므로 등호가 깨진다.
  #    반대로 `findmnt -T … >/dev/null`의 **성공 여부**만 보는 순진한 형태는 통과시킨다 —
  #    그 형태는 bats로 표현할 수 없어서 뮤테이션으로 확인했다(PR 본문 참조).
  #    OrbStack 시절엔 `-T`가 **필수**였다(mac 공유 하위 디렉토리는 자체 마운트포인트가 아니다).
  #    이식에서 요구사항이 정반대로 뒤집힌 자리다.
  FM_BULK_IS_MP=0 BULK_STORAGE_PATH="$WORK" run sh "$PROBE"
  [ "$status" -eq 11 ]
  printf '%s' "$output" | grep -qF -- 'not a mountpoint'
}

@test "exit 12 when bulk shares the device with / and phase A is NOT explicitly allowed" {
  # `test_07:77-84`("INTERNAL 디스크면 abort")의 후계. 권위가 macOS diskutil → 디바이스 정체성.
  FM_BULK_SRC=/dev/mapper/vg-root BULK_STORAGE_PATH="$WORK" run sh "$PROBE"
  [ "$status" -eq 12 ]
  printf '%s' "$output" | grep -qF -- 'SAME device'
  printf '%s' "$output" | grep -qF -- 'BULK_TEMPORARY_ALLOWED=1'
}

@test "a bind mount off the root LV is still the same device (bracketed SOURCE is stripped)" {
  # bind 마운트의 SOURCE는 `/dev/…[/sub/path]`다. 대괄호를 안 떼면 문자열이 달라져 **통과한다** —
  # 국면 A가 바로 이 모양이므로 이 한 줄이 게이트 전체의 의미를 좌우한다.
  FM_BULK_SRC='/dev/mapper/vg-root[/var/lib/rancher/k3s-storage/bulk]' \
    BULK_STORAGE_PATH="$WORK" run sh "$PROBE"
  [ "$status" -eq 12 ]
}

@test "phase A opt-in allows the same-device shape but barks loudly" {
  FM_BULK_SRC=/dev/mapper/vg-root BULK_TEMPORARY_ALLOWED=1 BULK_STORAGE_PATH="$WORK" run sh "$PROBE"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- 'WARN: bulk is on the SAME device'
  printf '%s' "$output" | grep -qF -- 'dr-drill'
}

@test "exit 11 when the backing device cannot be resolved (fails closed)" {
  cat >"$STUBDIR/findmnt" <<'EOF'
#!/usr/bin/env sh
for a in "$@"; do case "$a" in TARGET) echo "$3"; exit 0 ;; esac; done
exit 1
EOF
  chmod +x "$STUBDIR/findmnt"
  BULK_STORAGE_PATH="$WORK" run sh "$PROBE"
  [ "$status" -eq 11 ]
  printf '%s' "$output" | grep -qF -- 'could not resolve backing devices'
}

@test "exit 13 when the mountpoint is not writable" {
  chmod 555 "$WORK"
  BULK_STORAGE_PATH="$WORK" run sh "$PROBE"
  chmod 755 "$WORK"
  [ "$status" -eq 13 ]
}

@test "errors when required env is missing" {
  run sh "$PROBE"
  [ "$status" -ne 0 ]
}
