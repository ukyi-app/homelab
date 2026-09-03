#!/usr/bin/env bats
# apply-storage.sh — 렌더 + apply, 그리고 그 앞의 bulk 게이트.
#
# ⚠️ 이 스위트의 핵심은 렌더가 아니라 **게이트가 apply보다 먼저 돌고, 기본이 거부라는 것**이다.
#    OrbStack 시절 그 증명은 macOS `diskutil` stub이었고(`@test "aborts when the host volume is on
#    an INTERNAL disk"`), 베어메탈에서는 **디바이스 정체성**으로 옮겼다. 국면 A(D4 한시)가 바로 그
#    금지 상태를 한시 허용하므로, 여기서 증명까지 같이 잃기 쉽다 — 그래서 음성 @test가 더 많다.
#
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다. 여기서 특히 중요한 것은 `$RENDERED`가 **kubectl 스텁이
#    만드는** 파일이라는 점이다 — apply가 아예 일어나지 않으면 그 파일이 없어 grep이 rc 2로 죽는데,
#    예전 `-ne 0`은 그것을 "플레이스홀더가 안 남았다"는 렌더 성공으로 읽었다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; RENDERED="$STUBDIR/rendered.yaml"
  BULKDIR="$STUBDIR/bulk"; mkdir -p "$BULKDIR"
  PATH="$STUBDIR:$PATH"; export PATH STUBDIR RENDERED BULKDIR
  # 가짜 /etc/fstab — probe [2](영속 축)의 픽스처. probe는 `BULK_PROBE_ROOT`로 조회 접두를 받고,
  # 여기 `asroot` 대역이 `exec "$@"`라 환경이 그대로 흐른다. 프로덕션의 `sudo`는 env_reset이라
  # 이 시임이 새지 않는다 — 노드에서는 언제나 실제 `/etc/fstab`을 본다.
  mkdir -p "$STUBDIR/froot/etc"
  printf 'UUID=fake-bulk %s ext4 defaults,noatime,nofail 0 2\n' "$BULKDIR" > "$STUBDIR/froot/etc/fstab"
  export BULK_PROBE_ROOT="$STUBDIR/froot"
  cat >"$STUBDIR/kubectl" <<'EOF'
#!/usr/bin/env bash
# '-f -'로 파이프되든 '-f <file>'로 읽히든, apply된 모든 매니페스트를 $RENDERED에
# 누적해 단언이 apply 전체 집합을 보게 한다.
if [ "$1" = "apply" ]; then
  src=""
  while [ $# -gt 0 ]; do
    if [ "$1" = "-f" ]; then src="$2"; shift; fi
    shift
  done
  # `-f -`는 stdin을 **명시** 지정한 것이므로 `cat -`로 받는다. `-f`가 아예 없는 apply 호출은 계약
  # 위반인데, 거기서 fd 0을 읽으면 호출 형태 변경이 red가 아니라 **정지**로 나타난다(호출자의 stdin에서
  # EOF를 기다린다). 계약 위반은 소리내어 죽는다.
  if [ -z "$src" ]; then echo "kubectl stub: apply에 -f가 없다: $*" >&2; exit 64; fi
  if [ "$src" = "-" ]; then cat - >> "$RENDERED"; else cat "$src" >> "$RENDERED"; fi
fi
exit 0
EOF
  chmod +x "$STUBDIR/kubectl"
  # 권한 상승 대역 — 실제 probe가 그대로 돌게 둔다(스텁하지 않는다. probe 로직이 이 게이트의 전부다).
  printf '#!/usr/bin/env bash\nexec "$@"\n' > "$STUBDIR/asroot"; chmod +x "$STUBDIR/asroot"
  # 가짜 findmnt — 기본은 국면 B 형태(bulk가 마운트포인트 + 루트와 다른 디바이스).
  cat >"$STUBDIR/findmnt" <<'EOF'
#!/usr/bin/env sh
col=""; path=""
while [ $# -gt 0 ]; do
  case "$1" in
    -no) col="$2"; shift 2 ;;
    -*) shift ;;
    *) path="$1"; shift ;;
  esac
done
if [ "$path" = "/" ]; then
  if [ "$col" = "TARGET" ]; then echo "/"; else echo "/dev/mapper/vg-root"; fi
  exit 0
fi
[ "${FM_BULK_IS_MP:-1}" = "1" ] || exit 1
if [ "$col" = "TARGET" ]; then echo "$path"; else echo "${FM_BULK_SRC:-/dev/nvme1n1p1}"; fi
EOF
  chmod +x "$STUBDIR/findmnt"
  export KUBECONFIG_PATH="$STUBDIR/kubeconfig"; : > "$KUBECONFIG_PATH"
}
teardown() { rm -rf "$STUBDIR"; }

# versions.env는 무조건 export 하므로 환경으로 덮을 수 없다 — 샌드박스 사본을 만들어 값을 바꾼다.
# ($1 = BULK_MIGRATION_WINDOW_UNTIL 값. 생략 = 빈 창)
#
# ⚠️ 창 값은 **항상 명시적으로 쓴다.** 예전 판은 인자가 없으면 레포 값을 그대로 뒀는데, 그러면
#    owner가 국면 A에 진입하며 versions.env에 날짜를 채우는 순간 "플래그만으로는 안 열린다"
#    @test가 조용히 뒤집힌다 — 테스트가 **레포 상태에 의존**하고 있었던 것이다.
#    (같은 클래스의 선례: `main`을 리터럴로 쓴 테스트가 마이그레이션 브랜치에서 vacuous green이 됐다.)
_sandbox() {
  BS="$BATS_TEST_TMPDIR/bs"; rm -rf "$BS"; cp -R "$BOOTSTRAP_DIR" "$BS"
  sed -i.bak "s#^export BULK_STORAGE_PATH=.*#export BULK_STORAGE_PATH=\"$BULKDIR\"#" "$BS/versions.env"
  sed -i.bak "s#^export BULK_MIGRATION_WINDOW_UNTIL=.*#export BULK_MIGRATION_WINDOW_UNTIL=\"${1:-}\"#" "$BS/versions.env"
  export BS
}
# `run`이 출력을 삼켜 실패 시 진단이 0줄이 되는 자리 — 되울림 근거는 test_02-host-preflight.bats의
# 같은 헬퍼 주석. bats는 실패한 @test의 stdout만 보여주므로 초록 실행은 그대로 조용하다.
_apply() {
  BULK_RUN="$STUBDIR/asroot" KUBECONFIG_PATH="$KUBECONFIG_PATH" run "$BS/apply-storage.sh"
  echo "status=$status"
  echo "$output"
}

# ── 국면 B 형태(별도 디바이스) — 플래그 없이 통과해야 한다 ─────────────────────────────────
@test "renders manifests with the helper image substituted (no literal placeholder)" {
  _sandbox; _apply
  [ "$status" -eq 0 ]
  source "$BS/versions.env"
  run grep -F '${LOCAL_PATH_HELPER_IMAGE}' "$RENDERED"
  [ "$status" -eq 1 ]
  run grep -F "$LOCAL_PATH_HELPER_IMAGE" "$RENDERED"
  [ "$status" -eq 0 ]
}

@test "applies both StorageClasses" {
  _sandbox; _apply
  [ "$status" -eq 0 ]
  grep -q 'name: standard' "$RENDERED"
  grep -q 'name: bulk-ssd' "$RENDERED"
}

@test "renders the bulk mountpoint into the provisioner (no literal placeholder)" {
  _sandbox; _apply
  [ "$status" -eq 0 ]
  run grep -F '${BULK_STORAGE_PATH}' "$RENDERED"
  [ "$status" -eq 1 ]
  run grep -F "$BULKDIR" "$RENDERED"
  [ "$status" -eq 0 ]
}

@test "a separate device needs no phase-A flag (phase B is the normal path)" {
  _sandbox; _apply
  [ "$status" -eq 0 ]
  # ⚠️ 이 @test에는 형제 양성 단언이 없다 — 위 두 렌더 @test는 치환된 실제 값을 되잡아 렌더가
  #    비지 않았음을 함께 증언하지만, 여기는 부정 grep 하나뿐이다. 렌더가 통째로 비면 rc 1이라
  #    `-eq 1`도 통과하므로 비공허 바닥값을 함께 건다.
  [ -s "$RENDERED" ]
  run grep -F -- '국면 A' "$RENDERED"
  [ "$status" -eq 1 ]
}

# ── 기본 거부 — 이 스위트의 존재 이유 ──────────────────────────────────────────────────────
@test "aborts when bulk shares the device with / and no phase-A opt-in (nothing is applied)" {
  _sandbox
  FM_BULK_SRC=/dev/mapper/vg-root _apply
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'SAME device'
  [ ! -s "$RENDERED" ]
}

@test "aborts when the bulk path is not a mountpoint (nothing is applied)" {
  _sandbox
  FM_BULK_IS_MP=0 _apply
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'not a mountpoint'
  [ ! -s "$RENDERED" ]
}

# ── 국면 A 진입은 **둘 다** 있어야 한다 ────────────────────────────────────────────────────
@test "the phase-A flag ALONE does not open the gate (an unbounded window is not temporary)" {
  _sandbox                                   # 창 비움 (레포 값과 무관하게 명시)
  FM_BULK_SRC=/dev/mapper/vg-root BULK_TEMPORARY_ALLOWED=1 BULK_RUN="$STUBDIR/asroot" \
    run "$BS/apply-storage.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '한시 운용에 끝이 없으면'
  [ ! -s "$RENDERED" ]
}

@test "rejects a malformed migration window instead of guessing" {
  _sandbox "2026-8-1"
  FM_BULK_SRC=/dev/mapper/vg-root BULK_TEMPORARY_ALLOWED=1 BULK_RUN="$STUBDIR/asroot" \
    run "$BS/apply-storage.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'YYYY-MM-DD가 아니다'
}

@test "phase A opens with BOTH the flag and the window, and says so loudly" {
  _sandbox "2026-12-31"
  FM_BULK_SRC=/dev/mapper/vg-root BULK_TEMPORARY_ALLOWED=1 BULK_TODAY=2026-08-11 \
    BULK_RUN="$STUBDIR/asroot" run "$BS/apply-storage.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- '국면 A'
  printf '%s' "$output" | grep -qF -- 'WARN: bulk is on the SAME device'
  run grep -F "$BULKDIR" "$RENDERED"
  [ "$status" -eq 0 ]
}

@test "an EXPIRED window barks loudly but does not block bring-up" {
  # 만료 하나로 클러스터가 안 뜨는 것은 이 창의 목적이 아니다(선례: check-credential-expiry.sh).
  _sandbox "2026-08-01"
  FM_BULK_SRC=/dev/mapper/vg-root BULK_TEMPORARY_ALLOWED=1 BULK_TODAY=2026-09-15 \
    BULK_RUN="$STUBDIR/asroot" run "$BS/apply-storage.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- '만료됐다'
  run grep -F "$BULKDIR" "$RENDERED"
  [ "$status" -eq 0 ]
}

@test "a window that has NOT expired does not print the expiry warning" {
  # 양성 대조 — 위 @test가 '항상 짖는' 상태여도 통과하는 것을 막는다.
  _sandbox "2026-12-31"
  FM_BULK_SRC=/dev/mapper/vg-root BULK_TEMPORARY_ALLOWED=1 BULK_TODAY=2026-08-11 \
    BULK_RUN="$STUBDIR/asroot" run "$BS/apply-storage.sh"
  [ "$status" -eq 0 ]
  ! printf '%s' "$output" | grep -qF -- '만료됐다'
}

# ── OrbStack 잔재가 되살아나지 않는다 ──────────────────────────────────────────────────────
@test "no OrbStack or macOS binding remains in the storage layer (code, not prose)" {
  # ⚠️ 전체 파일 grep은 **자기 주석에 걸린다** — 두 파일의 헤더가 무엇이 왜 사라졌는지 설명하며
  #    그 단어들을 그대로 담고 있다(실측: 처음 작성했을 때 이 @test가 거짓 red를 냈다).
  #    레포가 문서화한 함정의 거울상이다: 거기선 vacuous green, 여기선 false red.
  #    단언 대상은 **코드**이므로 비-주석 줄만 본다.
  run grep -n 'BULK_STORAGE_PATH' "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -eq 0 ]                        # 양성 대조: 대상 파일이 실재하고 grep이 동작한다
  # ⚠️ 아래 부정 grep은 **두 파일**에 걸리는데 양성 대조는 오래도록 apply-storage.sh 하나뿐이었다.
  #    probe 쪽은 아무도 대조하지 않아, 그 파일이 사라져도(또는 `^[^#]*` 앵커가 표류해도) 이 @test가
  #    절반만 증언했다. 같은 앵커로 probe에도 대조를 세운다.
  run grep -nE '^[^#]*BULK_STORAGE_PATH' "$BOOTSTRAP_DIR/bulk-gate-probe.sh"
  [ "$status" -eq 0 ]
  run grep -nE '^[^#]*(diskutil|orb -m|virtiofs|/mnt/mac|BULK_ALLOW_VM_DISK)' \
    "$BOOTSTRAP_DIR/apply-storage.sh" "$BOOTSTRAP_DIR/bulk-gate-probe.sh"
  [ "$status" -eq 1 ]
}
