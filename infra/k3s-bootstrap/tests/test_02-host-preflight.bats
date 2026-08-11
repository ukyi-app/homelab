#!/usr/bin/env bats
# host-preflight.sh — k3s 설치 전 호스트 전제. `orb-guard.sh`(삭제)의 역할 후계.
#
# ⚠️ 검사 하나하나가 **사후 교정이 비싼** 불변식이다. 그래서 음성 @test가 검사 수만큼 있다 —
#    규칙을 지웠을 때 초록이면 그건 지키는 것이 없는 규칙이다.
load test_helper

setup() {
  FX="$BATS_TEST_TMPDIR/root"
  mkdir -p "$FX/etc/systemd/resolved.conf.d"
  source "$BOOTSTRAP_DIR/versions.env"
  # 건강한 기본값 — 개별 @test가 하나씩 망가뜨린다.
  echo "Asia/Seoul" > "$FX/etc/timezone"
  printf '[Resolve]\nDNSStubListener=no\n' > "$FX/etc/systemd/resolved.conf.d/10-k3s.conf"
  printf 'nameserver 192.168.117.1\noptions edns0\n' > "$FX/etc/resolv.conf"
  # `ip -o -4 addr show` 대역 — 4번째 필드가 CIDR이다.
  IPSTUB="$BATS_TEST_TMPDIR/ipstub"
  cat > "$IPSTUB" <<EOF
#!/usr/bin/env bash
echo "2: wlo1    inet ${K3S_NODE_IP}/24 brd 192.168.117.255 scope global dynamic wlo1"
echo "3: lo      inet 127.0.0.1/8 scope host lo"
EOF
  chmod +x "$IPSTUB"
  export FX IPSTUB
}
run_pf() { PREFLIGHT_ROOT="$FX" PREFLIGHT_IP="$IPSTUB" run "$BOOTSTRAP_DIR/host-preflight.sh"; }

@test "passes on a fully prepared host" {
  run_pf
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'OK: host-preflight'
}

# ── [1] 타임존 ─────────────────────────────────────────────────────────────────────────────
@test "rejects a wrong timezone (every CronJob schedule shifts otherwise)" {
  echo "Etc/UTC" > "$FX/etc/timezone"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'CronJob'
}

@test "rejects an unreadable timezone file instead of assuming it is fine" {
  rm -f "$FX/etc/timezone"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '타임존을 읽지 못했다'
}

# ── [2] resolved 스텁 ──────────────────────────────────────────────────────────────────────
@test "rejects DNSStubListener=yes (cold-start deadlock via hostPort DNAT)" {
  printf '[Resolve]\nDNSStubListener=yes\n' > "$FX/etc/systemd/resolved.conf.d/10-k3s.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '콜드스타트 교착'
}

@test "rejects a MISSING DNSStubListener setting (default is yes — silence is not consent)" {
  rm -f "$FX/etc/systemd/resolved.conf.d/10-k3s.conf"
  printf '[Resolve]\n' > "$FX/etc/systemd/resolved.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'DNSStubListener 설정이 없다'
}

@test "a drop-in overrides the main conf (last declaration wins, like systemd)" {
  printf '[Resolve]\nDNSStubListener=yes\n' > "$FX/etc/systemd/resolved.conf"
  printf '[Resolve]\nDNSStubListener=no\n' > "$FX/etc/systemd/resolved.conf.d/10-k3s.conf"
  run_pf
  [ "$status" -eq 0 ]
}

# ── [3] resolv.conf 업스트림 ───────────────────────────────────────────────────────────────
@test "rejects an all-loopback resolv.conf (the stub being off is not enough)" {
  # 스텁을 껐어도 resolv.conf가 127.x를 가리키면 같은 DNAT에 걸린다 — **다른 실패**다.
  printf 'nameserver 127.0.0.53\n' > "$FX/etc/resolv.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '전부 loopback'
}

@test "rejects a resolv.conf with no nameserver at all (0 entries is not a pass)" {
  printf 'options edns0\n' > "$FX/etc/resolv.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'nameserver가 하나도 없다'
}

# ── [4] 노드 IP ────────────────────────────────────────────────────────────────────────────
@test "rejects a pinned node IP that no interface actually carries (DHCP reservation missing)" {
  cat > "$IPSTUB" <<'EOF'
#!/usr/bin/env bash
echo "2: wlo1    inet 192.168.117.99/24 brd 192.168.117.255 scope global dynamic wlo1"
EOF
  chmod +x "$IPSTUB"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'DHCP 예약'
}

@test "rejects an empty K3S_NODE_IP pin" {
  cp -R "$BOOTSTRAP_DIR" "$BATS_TEST_TMPDIR/bs"
  sed -i.bak 's/^export K3S_NODE_IP=.*/export K3S_NODE_IP=""/' "$BATS_TEST_TMPDIR/bs/versions.env"
  PREFLIGHT_ROOT="$FX" PREFLIGHT_IP="$IPSTUB" run "$BATS_TEST_TMPDIR/bs/host-preflight.sh"
  [ "$status" -ne 0 ]
  # ⚠️ 그냥 'K3S_NODE_IP'만 grep하면 **뒤 검사의 메시지에도 그 문자열이 있어** 이 @test가
  #    빈-값 검사를 지워도 통과한다(역방향 뮤테이션 실측 → 죽은 규칙). 두 실패는 원인도 처방도
  #    다르다 — 빈 값은 versions.env 설정 오류, 불일치는 DHCP 예약 문제다. 진단이 갈려야 한다.
  printf '%s' "$output" | grep -q 'K3S_NODE_IP 미설정'
  run bash -c "printf '%s' \"$output\" | grep -c 'DHCP 예약' || true"
  printf '%s' "$output" | grep -qx '0'
}
