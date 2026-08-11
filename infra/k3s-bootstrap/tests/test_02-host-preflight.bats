#!/usr/bin/env bats
# host-preflight.sh — k3s 설치 전 호스트 전제. `orb-guard.sh`(삭제)의 역할 후계.
#
# ⚠️ 검사 하나하나가 **사후 교정이 비싼** 불변식이다. 그래서 음성 @test가 검사 수만큼 있다 —
#    규칙을 지웠을 때 초록이면 그건 지키는 것이 없는 규칙이다.
#
# ⚠️ 여기는 **실효값**만 본다. "커밋된 파일이 디스크에 그대로 있는가"(선언 ↔ 실제)는
#    host-config.sh --check의 몫이다. 두 검사가 겹치면 어느 쪽이 권위인지 흐려진다.
load test_helper

setup() {
  FX="$BATS_TEST_TMPDIR/root"
  mkdir -p "$FX/etc/systemd/resolved.conf.d" "$FX/proc"
  source "$BOOTSTRAP_DIR/versions.env"
  # 건강한 기본값 — 개별 @test가 하나씩 망가뜨린다.
  # ⚠️ 타임존 진실원은 /etc/localtime 심링크다. Ubuntu 26.04에 /etc/timezone은 **없다**(실측).
  ln -sfn "/usr/share/zoneinfo/${HOST_TIMEZONE}" "$FX/etc/localtime"
  printf '[Resolve]\nDNSStubListener=no\n' > "$FX/etc/systemd/resolved.conf.d/10-k3s.conf"
  printf 'nameserver %s\noptions edns0\n' "$HOST_UPSTREAM_DNS" > "$FX/etc/resolv.conf"
  # 스왑 없는 호스트: /proc/swaps는 헤더 1줄, fstab에 swap 항목 없음. (NUC 실측 shape에서 유도)
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n' > "$FX/proc/swaps"
  printf '# /etc/fstab\n/dev/mapper/vg-lv / ext4 defaults 0 1\ntmpfs /tmp tmpfs rw,nosuid,noswap 0 0\n' > "$FX/etc/fstab"
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
  printf '%s' "$output" | grep -qF -- 'OK: host-preflight'
}

# ── [1] 타임존 ─────────────────────────────────────────────────────────────────────────────
@test "rejects a wrong timezone (every CronJob schedule shifts otherwise)" {
  ln -sfn /usr/share/zoneinfo/Etc/UTC "$FX/etc/localtime"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'CronJob'
}

@test "reads the timezone from the localtime symlink, not /etc/timezone (absent on Ubuntu 26.04)" {
  # 예전 검사는 ${FX}/etc/timezone을 읽었다. 그 파일은 26.04에 존재하지 않으므로 정상 호스트에서도
  # '읽지 못했다'로 죽었고, 진단이 제안하는 timedatectl은 그 파일을 만들지도 않았다 — 출구 없는 게이트.
  echo "Etc/UTC" > "$FX/etc/timezone"          # 있어도 무시돼야 한다(심링크가 권위)
  run_pf
  [ "$status" -eq 0 ]
}

@test "rejects an /etc/localtime that is not a symlink (no timezone source of truth)" {
  rm -f "$FX/etc/localtime"
  : > "$FX/etc/localtime"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '심링크가 아니다'
}

@test "rejects a localtime symlink that does not point into zoneinfo" {
  ln -sfn /somewhere/else "$FX/etc/localtime"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'zoneinfo 경로가 아니다'
}

# ── [2] resolved 스텁 ──────────────────────────────────────────────────────────────────────
@test "rejects DNSStubListener=yes (cold-start deadlock via hostPort DNAT)" {
  printf '[Resolve]\nDNSStubListener=yes\n' > "$FX/etc/systemd/resolved.conf.d/10-k3s.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '콜드스타트 교착'
}

@test "rejects a MISSING DNSStubListener setting (default is yes — silence is not consent)" {
  rm -f "$FX/etc/systemd/resolved.conf.d/10-k3s.conf"
  printf '[Resolve]\n' > "$FX/etc/systemd/resolved.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'DNSStubListener 설정이 없다'
}

@test "a drop-in overrides the main conf (last declaration wins, like systemd)" {
  printf '[Resolve]\nDNSStubListener=yes\n' > "$FX/etc/systemd/resolved.conf"
  printf '[Resolve]\nDNSStubListener=no\n' > "$FX/etc/systemd/resolved.conf.d/10-k3s.conf"
  run_pf
  [ "$status" -eq 0 ]
}

# ── [3] resolv.conf 리졸버가 클러스터 독립인가 ─────────────────────────────────────────────
@test "rejects an all-loopback resolv.conf (the stub being off is not enough)" {
  # 스텁을 껐어도 resolv.conf가 127.x를 가리키면 같은 DNAT에 걸린다 — **다른 실패**다.
  printf 'nameserver 127.0.0.53\n' > "$FX/etc/resolv.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '전부 loopback'
}

@test "rejects a resolv.conf with no nameserver at all (0 entries is not a pass)" {
  printf 'options edns0\n' > "$FX/etc/resolv.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'nameserver가 하나도 없다'
}

@test "rejects the tailscale MagicDNS resolver (its upstream is set by the tailnet, today the live Mac)" {
  # 실측 2026-08-11: DNSStubListener=no로 스텁을 꺼도 실업스트림 1순위가 100.100.100.100이고
  # 그 뒤는 100.112.20.3(맥미니 AdGuard)다. routable이라 예전 [3]은 통과시켰다 — 그게 구멍이었다.
  printf 'nameserver 100.100.100.100\nnameserver %s\n' "$HOST_UPSTREAM_DNS" > "$FX/etc/resolv.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'accept-dns=false'
}

@test "rejects a tailnet peer resolver over IPv6 (tailscale ULA)" {
  printf 'nameserver fd7a:115c:a1e0::53\nnameserver %s\n' "$HOST_UPSTREAM_DNS" > "$FX/etc/resolv.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'tailnet 대역'
}

@test "does NOT reject 100.x addresses outside the CGNAT range (100.64.0.0/10 boundaries)" {
  # 100.63.255.254 와 100.128.0.1 은 tailnet이 아니다. 글롭을 `100.*`로 넓히면 이 @test가 잡는다.
  printf 'nameserver 100.63.255.254\nnameserver 100.128.0.1\n' > "$FX/etc/resolv.conf"
  run_pf
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- 'tailnet 0'
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
  printf '%s' "$output" | grep -qF -- 'DHCP 예약'
}

@test "rejects an empty K3S_NODE_IP pin" {
  cp -R "$BOOTSTRAP_DIR" "$BATS_TEST_TMPDIR/bs"
  sed -i.bak 's/^export K3S_NODE_IP=.*/export K3S_NODE_IP=""/' "$BATS_TEST_TMPDIR/bs/versions.env"
  PREFLIGHT_ROOT="$FX" PREFLIGHT_IP="$IPSTUB" run "$BATS_TEST_TMPDIR/bs/host-preflight.sh"
  [ "$status" -ne 0 ]
  # ⚠️ 그냥 'K3S_NODE_IP'만 grep하면 **뒤 검사의 메시지에도 그 문자열이 있어** 이 @test가
  #    빈-값 검사를 지워도 통과한다(역방향 뮤테이션 실측 → 죽은 규칙). 두 실패는 원인도 처방도
  #    다르다 — 빈 값은 versions.env 설정 오류, 불일치는 DHCP 예약 문제다. 진단이 갈려야 한다.
  # ⚠️ 예전엔 `bash -c "printf … \"$output\" …"`로 재해석했다. 진단 메시지에 백틱이나 $(…)가
  #    들어오는 순간 그것이 러너에서 **실행된다**(실측 재현). 마지막 명령 부정으로 대체했다.
  printf '%s' "$output" | grep -qF -- 'K3S_NODE_IP 미설정'
  ! printf '%s' "$output" | grep -qF -- 'DHCP 예약'
}

# ── [5] 스왑 부재 (owner 확정 D-f) ─────────────────────────────────────────────────────────
@test "rejects an active swap" {
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n/swap.img\tfile\t\t8388604\t\t488\t\t-1\n' > "$FX/proc/swaps"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '활성 스왑 1건'
  printf '%s' "$output" | grep -qF -- '/swap.img'
}

@test "rejects a swap line still in fstab even when swap is currently OFF (it returns on reboot)" {
  printf '/dev/mapper/vg-lv / ext4 defaults 0 1\n/swap.img\tnone\tswap\tsw\t0\t0\n' > "$FX/etc/fstab"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '재부팅하면 돌아온다'
  # 두 실패가 실제로 갈리는지 — 지금은 swapoff 상태이므로 활성-스왑 진단이 나오면 안 된다.
  ! printf '%s' "$output" | grep -qF -- '활성 스왑'
}

@test "rejects an unreadable /proc/swaps instead of reading 0 entries as 'no swap'" {
  rm -f "$FX/proc/swaps"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '스왑 부재를 단언할 수 없다'
}

@test "rejects a /proc/swaps whose first line is not the header (the parser did not engage)" {
  printf 'totally unexpected\n' > "$FX/proc/swaps"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '헤더가 아니다'
}

@test "rejects an unreadable /etc/fstab (cannot claim swap stays gone across reboot)" {
  rm -f "$FX/etc/fstab"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '되돌아오는지 단언할 수 없다'
}

@test "rejects a zram-generator config (zram leaves no fstab trace — D-f rules it out entirely)" {
  printf '[zram0]\nzram-size = min(ram / 4, 2048)\n' > "$FX/etc/systemd/zram-generator.conf"
  run_pf
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'zram은 도입하지 않기로'
}

@test "a COMMENTED-OUT swap line does not count, and neither does a noswap mount option" {
  # 세 함정을 한 픽스처에: `# ` 붙은 주석 · `#` 밀착 주석 · 옵션 문자열에 swap이 들어간 정상 줄.
  printf '/dev/mapper/vg-lv / ext4 defaults 0 1\n# /swap.img none swap sw 0 0\n#/swap.img none swap sw 0 0\ntmpfs /tmp tmpfs rw,nosuid,noswap 0 0\n' > "$FX/etc/fstab"
  run_pf
  [ "$status" -eq 0 ]
  # engagement 단언: 카운터가 OK 줄에 실제로 나온다(검사가 돌았다는 증거).
  printf '%s' "$output" | grep -qF -- 'swap 활성 0건/fstab 0건'
}
