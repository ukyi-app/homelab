#!/usr/bin/env bats
# host-config.sh + host-config/ 트리 — `cloud-init.yaml`(삭제)의 후계.
#
# ⚠️ 앞선 `test_03-cloud-init.bats`는 **적용될 수 없는 파일**을 검증하고 있었다: NUC의
#    `cloud-init status`는 `disabled`이고(subiquity가 설치 시 껐다), 그 7건이 전부 초록인 동안
#    호스트에는 zram·journald 상한·storage dir·sshd 하드닝이 **하나도 없었다**(실측 2026-08-11).
#    문자열이 초록인 것과 호스트가 그렇다는 것은 다르다 — 그래서 이 파일은 트리 대조뿐 아니라
#    `--apply` 실행 경로를 시임으로 **실제로 돌린다**.
load test_helper

TREE="$BOOTSTRAP_DIR/host-config"

setup() {
  source "$BOOTSTRAP_DIR/versions.env"
  FX="$BATS_TEST_TMPDIR/root"
  mkdir -p "$FX"
  # 선언 트리를 그대로 픽스처 루트에 복사 = "이미 적용된 호스트".
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$FX/$(dirname "$f")"
    cp "$TREE/$f" "$FX/$f"
  done <<EOF
$( (cd "$TREE" && find . -type f -name '*.conf') | sed 's|^\./||' )
EOF
  export FX
}
run_hc() { HOSTCFG_ROOT="$FX" run "$BOOTSTRAP_DIR/host-config.sh" "$@"; }

# ── 선언 ↔ 디스크 대조 ─────────────────────────────────────────────────────────────────────
@test "check passes when the declared tree matches disk" {
  run_hc --check
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- 'OK: host-config --check'
}

@test "check rejects a content drift in any managed file" {
  printf 'DNSStubListener=yes\n' >> "$FX/etc/systemd/resolved.conf.d/10-k3s-node.conf"
  run_hc --check
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '내용이 선언'
}

@test "check rejects a managed file that is absent (not-applied is drift, not silence)" {
  rm -f "$FX/etc/systemd/journald.conf.d/10-k3s-node.conf"
  run_hc --check
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '없거나 읽을 수 없다'
}

@test "check fails closed when the tree enumerates below the floor (0 files is not 'no drift')" {
  EMPTY="$BATS_TEST_TMPDIR/emptytree"
  mkdir -p "$EMPTY"
  HOSTCFG_ROOT="$FX" HOSTCFG_TREE="$EMPTY" run "$BOOTSTRAP_DIR/host-config.sh" --check
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '열거가 깨졌거나'
}

# ── sshd 우선순위 — systemd 드롭인과 **정반대**다 ──────────────────────────────────────────
@test "check rejects an sshd drop-in that sorts BEFORE ours (sshd takes the first value, not the last)" {
  printf 'PasswordAuthentication yes\n' > "$FX/etc/ssh/sshd_config.d/05-earlier.conf"
  run_hc --check
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '사전순 앞선'
}

@test "check tolerates an sshd drop-in that sorts AFTER ours (50-cloud-init.conf is unreadable but loses)" {
  # NUC 실측: 50-cloud-init.conf는 600 root:root라 내용을 못 읽는다. 그래도 `10-`이 이기므로
  # 이름만으로 불변식이 성립한다 — 내용 열람이 필요 없다는 것이 이 설계의 요점이다.
  printf 'PasswordAuthentication yes\n' > "$FX/etc/ssh/sshd_config.d/50-cloud-init.conf"
  chmod 0600 "$FX/etc/ssh/sshd_config.d/50-cloud-init.conf"
  run_hc --check
  [ "$status" -eq 0 ]
}

# ── versions.env ↔ 트리 정합 (렌더링하지 않으므로 값이 두 곳에 산다) ───────────────────────
@test "the resolved drop-in pins exactly versions.env HOST_UPSTREAM_DNS" {
  [ -n "$HOST_UPSTREAM_DNS" ]
  run grep -qxF "DNS=${HOST_UPSTREAM_DNS}" "$TREE/etc/systemd/resolved.conf.d/10-k3s-node.conf"
  [ "$status" -eq 0 ]
}

@test "check fails when versions.env and the tree disagree on the upstream resolver" {
  BS="$BATS_TEST_TMPDIR/bs"
  cp -R "$BOOTSTRAP_DIR" "$BS"
  sed -i.bak 's/^export HOST_UPSTREAM_DNS=.*/export HOST_UPSTREAM_DNS="10.0.0.1"/' "$BS/versions.env"
  HOSTCFG_ROOT="$FX" run "$BS/host-config.sh" --check
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'HOST_UPSTREAM_DNS'
}

@test "HOST_TIMEZONE is set in versions.env (host-preflight and --apply both read it)" {
  [ -n "$HOST_TIMEZONE" ]
  run grep -qxF 'export HOST_TIMEZONE="Asia/Seoul"' "$BOOTSTRAP_DIR/versions.env"
  [ "$status" -eq 0 ]
}

# ── NVMe ASPM L1 (2026-08-15 A/B 실측) ─────────────────────────────────────────────────────
@test "the tree disables NVMe ASPM L1 through the driver glob, not a pinned PCI address" {
  T="$TREE/etc/tmpfiles.d/10-k3s-node.conf"
  [ -f "$T" ]
  # systemd-tmpfiles `w` = "있으면 쓴다"(생성하지 않는다) — 디스크가 빠져도 실패하지 않는다.
  run grep -qE '^w[[:space:]]+/sys/bus/pci/drivers/nvme/\*/link/l1_aspm[[:space:]].*[[:space:]]0$' "$T"
  [ "$status" -eq 0 ]
  # ⚠️ PCI 주소를 박으면 슬롯 변경·두 번째 M.2에서 조용히 빗나간다.
  #    ⚠️ **비주석 줄만 본다** — 헤더 주석이 "이렇게 하지 말 것"의 예시로 그 경로를 들고 있다.
  #       파일 전체에 부정 grep을 걸면 그 예시에 걸려 red가 난다(이 @test가 실제로 그렇게 잡혔다).
  run sh -c "grep -vE '^[[:space:]]*#' '$T' | grep -qE '/sys/bus/pci/devices/[0-9a-f]{4}:'"
  [ "$status" -ne 0 ]
  # 양성 대조 — 비주석 줄이 실제로 존재하는가(대상 0을 '매치 0'으로 오독하지 않는다).
  run sh -c "grep -vE '^[[:space:]]*#' '$T' | grep -qF 'l1_aspm'"
  [ "$status" -eq 0 ]
}

@test "the tmpfiles drop-in is enumerable by the installer (a .rules/.cfg name would be silently ignored)" {
  # 설치기의 열거는 `find . -type f -name '*.conf'`다 — 확장자가 곧 검사 도메인 편입 조건이다.
  n="$( (cd "$TREE" && find . -type f -name '*.conf') | grep -c 'tmpfiles.d' )"
  [ "$n" -eq 1 ]
  # 바닥값이 트리 증가를 따라왔는가 — 안 따라오면 바닥값이 의미를 잃는다.
  total="$( (cd "$TREE" && find . -type f -name '*.conf') | wc -l | tr -d ' ' )"
  floor="$(grep -oE '^TREE_MIN=[0-9]+' "$BOOTSTRAP_DIR/host-config.sh" | grep -oE '[0-9]+')"
  [ -n "$floor" ]
  [ "$floor" -eq "$total" ] || { echo "TREE_MIN=$floor · 트리 .conf $total건 — 바닥값이 트리를 따라오지 않았다"; false; }
}

# ── 이식 계약: 버려야 할 것이 트리에 되살아나지 않는다 ─────────────────────────────────────
@test "the tree declares no swap or zram (owner decision D-f)" {
  # zram은 OrbStack VM에서 한 번도 적용된 적이 없었고(LXC 드롭인이 유닛을 죽였다), 베어메탈에서
  # 처음으로 효력을 낸다 — 즉 '그대로 이식'이 현행 보존이 아니라 **변경**이었다. nuc-port-g2.md B3.
  # ⚠️ 양성 대조 먼저: 부정 grep은 '매치 0'과 '대상 0'을 구별하지 못한다(traps-detail ③).
  run grep -rn 'DNSStubListener' "$TREE"
  [ "$status" -eq 0 ]
  run grep -rniE 'zram|swap' "$TREE"
  [ "$status" -ne 0 ]
}

@test "the tree declares no dns-forward-trigger (OrbStack LISTEN-forward hack has no bare-metal role)" {
  # 그 더미 유닛은 OrbStack이 **LISTEN 포트만** Mac으로 포워딩하기 때문에 존재했다. 베어메탈에서는
  # svclb hostPort가 노드 실주소에 직접 걸리므로 트리거할 대상이 없다.
  run grep -rn 'k3s-node' "$TREE" "$BOOTSTRAP_DIR/host-config.sh"
  [ "$status" -eq 0 ]
  run grep -rn 'dns-forward-trigger' "$TREE" "$BOOTSTRAP_DIR/host-config.sh"
  [ "$status" -ne 0 ]
}

@test "rejects an unknown argument instead of silently defaulting" {
  run_hc --appply
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '알 수 없는 인자'
}

# ── --apply 실행 경로 ──────────────────────────────────────────────────────────────────────
# 권한 상승 대역을 argv 기록기로 가린다. 파일을 실제로 옮기는 하위 명령만 흉내내어
# **apply → check 왕복**이 성립하는지까지 본다(= 이 계층이 자기가 선언한 상태를 실제로 만든다).
_sandbox() {
  SB="$BATS_TEST_TMPDIR/sb"; mkdir -p "$SB/bin"
  cat > "$SB/bin/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC_LOG"
case "$1" in
  mkdir)   shift; mkdir "$@" ;;
  ln)      shift; ln "$@" ;;
  cp)      shift; cp "$@" ;;
  install)
    # `-o root -g root`는 비-root에서 못 준다 — 소유권을 빼고 나머지는 그대로 수행한다.
    shift; args=""; src=""; dst=""; dirmode=""; isdir=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o|-g) shift 2 ;;
        -d)    isdir=1; shift ;;
        -m)    dirmode="$2"; shift 2 ;;
        *)     if [ -z "$dst" ] && [ -n "$src" ]; then dst="$1"; else src="$1"; fi; shift ;;
      esac
    done
    if [ "$isdir" = "1" ]; then mkdir -p "$src"; chmod "${dirmode:-0755}" "$src";
    else cp "$src" "$dst"; chmod "${dirmode:-0644}" "$dst"; fi
    unset args ;;
  *) : ;;
esac
REC
  chmod +x "$SB/bin/rec"
  export REC_LOG="$SB/argv.log" SB
  : > "$REC_LOG"
  # `--apply`가 손대는 호스트 상태의 픽스처.
  printf '# /etc/fstab\n/dev/mapper/vg-lv / ext4 defaults 0 1\n/swap.img\tnone\tswap\tsw\t0\t0\n' > "$FX/etc/fstab"
  mkdir -p "$FX/run/systemd/resolve"
  ln -sfn ../run/systemd/resolve/stub-resolv.conf "$FX/etc/resolv.conf"
  # tailscale이 PATH에 있어야 [4]가 fail하지 않는다.
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/tailscale"; chmod +x "$SB/bin/tailscale"
}
_apply() { REC_LOG="$REC_LOG" PATH="$SB/bin:$PATH" HOSTCFG_ROOT="$FX" HOSTCFG_RUN="$SB/bin/rec" \
             run "$BOOTSTRAP_DIR/host-config.sh" --apply; }

@test "apply installs every declared file, sets the timezone, and drops swap" {
  _sandbox
  rm -rf "$FX/etc/systemd" "$FX/etc/ssh"        # 아직 적용되지 않은 호스트
  _apply
  [ "$status" -eq 0 ]
  log="$(cat "$REC_LOG")"
  printf '%s' "$log" | grep -qF -- "timedatectl set-timezone ${HOST_TIMEZONE}"
  printf '%s' "$log" | grep -qF -- 'swapoff -a'
  [ -f "$FX/etc/systemd/resolved.conf.d/10-k3s-node.conf" ]
  [ -f "$FX/etc/systemd/journald.conf.d/10-k3s-node.conf" ]
  [ -f "$FX/etc/ssh/sshd_config.d/10-k3s-node.conf" ]
}

@test "apply makes the tmpfiles line effective now (a reboot requirement would make 'applied' a lie)" {
  # 부팅 때는 systemd-tmpfiles-setup.service가 걸지만, --apply가 재부팅을 요구하면
  # "적용 완료"가 거짓이 된다. 설치만 하고 반영을 빠뜨리는 회귀를 이 @test가 막는다.
  _sandbox
  _apply
  [ "$status" -eq 0 ]
  log="$(cat "$REC_LOG")"
  printf '%s' "$log" | grep -qF -- 'systemd-tmpfiles --create'
  printf '%s' "$log" | grep -qF -- '/etc/tmpfiles.d/10-k3s-node.conf'
  [ -f "$FX/etc/tmpfiles.d/10-k3s-node.conf" ]
}

@test "apply detaches the node from tailnet DNS (its upstream is the LIVE Mac AdGuard)" {
  # 실측 2026-08-11: tailscale0의 DNS Domain에 `~.`가 있고 Resolvers는 100.112.20.3 = 맥미니.
  # 즉 지금 NUC의 이름해석은 **이미** 라이브 클러스터에 의존한다. DNSStubListener=no만으로는
  # 안 풀린다 — 스텁을 꺼도 실업스트림 1순위가 100.100.100.100(MagicDNS)이다.
  _sandbox
  _apply
  [ "$status" -eq 0 ]
  printf '%s' "$(cat "$REC_LOG")" | grep -qF -- 'tailscale set --accept-dns=false'
}

@test "apply repoints resolv.conf off the stub (DNSStubListener=no leaves no stub file)" {
  _sandbox
  _apply
  [ "$status" -eq 0 ]
  tgt="$(readlink "$FX/etc/resolv.conf")"
  # 정확 일치로 단언한다 — `grep -qF 'resolv.conf'`는 stub-resolv.conf에도 매치해서 아무것도
  # 증명하지 못한다(바로 이 @test가 갈라내려는 두 상태가 서로의 부분문자열이다).
  printf '%s' "$tgt" | grep -qxF -- '../run/systemd/resolve/resolv.conf'
}

@test "apply removes the fstab swap entry and keeps a backup (swapoff alone comes back on reboot)" {
  _sandbox
  _apply
  [ "$status" -eq 0 ]
  n="$(awk 'NF && $1 !~ /^#/ && $3 == "swap" { c++ } END { print c+0 }' "$FX/etc/fstab")"
  [ "$n" -eq 0 ]
  [ -f "$FX/etc/fstab.pre-host-config.bak" ]
  run grep -qF '/swap.img' "$FX/etc/fstab.pre-host-config.bak"
  [ "$status" -eq 0 ]
  run grep -qF '/dev/mapper/vg-lv' "$FX/etc/fstab"
  [ "$status" -eq 0 ]
}

@test "apply then check is green, and a second apply is idempotent (backup not clobbered)" {
  _sandbox
  rm -rf "$FX/etc/systemd" "$FX/etc/ssh"
  _apply
  [ "$status" -eq 0 ]
  run_hc --check
  [ "$status" -eq 0 ]
  _apply
  [ "$status" -eq 0 ]
  # 두 번째 실행은 fstab에 swap이 없으므로 백업을 다시 쓰지 않는다 — 원본이 보존돼야 한다.
  run grep -qF '/swap.img' "$FX/etc/fstab.pre-host-config.bak"
  [ "$status" -eq 0 ]
}

@test "apply creates the internal storage dir 0700 (nothing else in the repo creates it)" {
  # cloud-init.yaml:108이 유일한 생성 지점이었다. 없으면 local-path helper가 `mkdir -m 0777 -p`로
  # 늦게, 더 느슨한 퍼미션으로 조상까지 만든다.
  _sandbox
  _apply
  [ "$status" -eq 0 ]
  [ -d "${FX}${INTERNAL_STORAGE_PATH}" ]
  printf '%s' "$(cat "$REC_LOG")" | grep -qF -- "install -d -m 0700 -o root -g root ${FX}${INTERNAL_STORAGE_PATH}"
}

@test "apply does NOT create or mount the bulk path (that belongs to the storage layer)" {
  # bulk는 **마운트포인트**여야 하고(versions.env), 그 마운트를 만드는 것은 국면 A 진입 절차다.
  # host-config가 여기서 디렉토리를 만들어 두면 apply-storage의 마운트포인트 검사가 통과할
  # 껍데기를 미리 깔아 주는 셈이라, 정확히 그 게이트를 무력화한다.
  _sandbox
  _apply
  [ "$status" -eq 0 ]
  # 양성 대조: 같은 로그에서 internal은 잡힌다 — 즉 '대상 0'이 아니라 '매치 0'이다.
  run grep -F -- "$INTERNAL_STORAGE_PATH" "$REC_LOG"
  [ "$status" -eq 0 ]
  [ -n "$BULK_STORAGE_PATH" ]
  run grep -F -- "$BULK_STORAGE_PATH" "$REC_LOG"
  [ "$status" -ne 0 ]
}

@test "apply fails loudly when tailscale is absent instead of leaving cluster-dependent DNS" {
  _sandbox
  rm -f "$SB/bin/tailscale"
  REC_LOG="$REC_LOG" PATH="$SB/bin:/usr/bin:/bin" HOSTCFG_ROOT="$FX" HOSTCFG_RUN="$SB/bin/rec" \
    run "$BOOTSTRAP_DIR/host-config.sh" --apply
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'tailscale이 PATH에 없다'
}
