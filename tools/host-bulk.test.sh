#!/usr/bin/env bash
# host/install.sh --bulk-ssd와 verify.sh check_bulk_ssd의 시험(삭제 원장 SSD). ci가 부른다.
# root·실제 디스크·마운트 없이 돈다. 가짜 blkid·findmnt·mount·lsblk·systemctl·install·sudo와 임시 디렉터리
# (가짜 fstab, 가짜 마운트 지점)를 쓴다. "마운트됨"은 가짜 findmnt가 상태 파일을 보고 답하는 것이다.
# 실제 장치·fstab·systemd 마운트는 사람이 병합 뒤 sudo host/install.sh --cluster prod --bulk-ssd로 본다.
#   fstab: 없으면 한 줄 더하고 백업, 같은 줄이면 그대로(중복 없음), 같은 지점·같은 라벨의 다른 줄·중복이면 멈춤.
#   장치: 라벨 장치가 정확히 하나이고 ext4, 다른 곳에 마운트돼 있지 않아야 한다. 포맷 명령은 코드에 없다.
#   마운트: findmnt --mountpoint의 원본이 그 장치이고 ext4·rw일 때만 원장 디렉터리를 만든다. 아니면 아무것도 만들지 않는다.
#   마운트 전 루트 쪽 마운트 지점이 비어 있지 않으면 멈춘다.
#   원장: 비었으면 빈 deletions.jsonl과 계약 v1 표식을 0600으로 만든다. 둘 다 있으면 그대로(내용·generation 유지).
#   비어 있지 않은데 하나라도 없으면 멈추고 만들지 않는다. 소유·모드·표식 형식이 다르면 고치지 않고 멈춘다.
#   값: BULK_SSD_LABEL·BULK_MOUNT가 빈 클러스터(vm)는 건너뛴다. 하나만 채우거나 형식이 틀리면 load_cluster가 멈춘다.
# 실행 틀(run_install·run_verify)은 시험마다 서브셸에서 값을 바꿔 서로 섞이지 않게 한다. 바깥으로 새지 않는 것이 의도다.
# verify.sh가 source되며 정의하는 FAILS도 그 서브셸 안의 것이라 이 파일의 FAILS와 별개다.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
CASES=0
pass() { CASES=$((CASES + 1)); printf 'ok   %s\n' "$*"; }
fail() { CASES=$((CASES + 1)); FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$*" >&2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ME="$(id -u):$(id -g)"
DEV=/dev/fake-nvme1n1p1
FAKE_UUID=00000000-0000-4000-8000-000000000000

# ------------------------------------------------------------------------------ 가짜 명령
# 상태는 STUB_STATE 아래 파일이다.
#   devices: 라벨 장치 목록(줄마다 하나), fstype: blkid TYPE, mounted: 마운트 지점의 findmnt 줄(원본 형식 옵션 라벨),
#   mountpoint: 마운트 지점 경로, elsewhere: 같은 장치의 다른 마운트 지점, mount_result: mount 뒤 mounted에 쓸 줄,
#   mount_fail: 있으면 mount 실패, labels: lsblk 라벨 목록
STUB="$TMP/stub"
mkdir -p "$STUB"
cat >"$STUB/blkid" <<'EOF'
#!/usr/bin/env bash
echo "blkid $*" >>"$STUB_LOG"
case " $* " in
  *" -t "*) [ -s "$STUB_STATE/devices" ] || exit 2; cat "$STUB_STATE/devices" ;;
  *" -s TYPE "*) cat "$STUB_STATE/fstype" ;;
  *" -s UUID "*) echo "$FAKE_UUID" ;;
  *) exit 9 ;;
esac
EOF
cat >"$STUB/findmnt" <<'EOF'
#!/usr/bin/env bash
mp="" src=""
while [ "$#" -gt 0 ]; do
  case "$1" in --mountpoint) mp="$2"; shift 2 ;; --source) src="$2"; shift 2 ;; *) shift ;; esac
done
if [ -n "$mp" ]; then
  [ "$mp" = "$(cat "$STUB_STATE/mountpoint")" ] && [ -s "$STUB_STATE/mounted" ] || exit 1
  cat "$STUB_STATE/mounted"
elif [ -n "$src" ]; then
  out=""
  if [ -s "$STUB_STATE/mounted" ] && [ "$(cut -d ' ' -f 1 "$STUB_STATE/mounted" | head -n 1)" = "$src" ]; then
    out="$(cat "$STUB_STATE/mountpoint")"
  fi
  if [ -s "$STUB_STATE/elsewhere" ]; then out="${out:+$out$'\n'}$(cat "$STUB_STATE/elsewhere")"; fi
  [ -n "$out" ] || exit 1
  printf '%s\n' "$out"
else
  exit 9
fi
EOF
cat >"$STUB/mount" <<'EOF'
#!/usr/bin/env bash
echo "mount $*" >>"$STUB_LOG"
[ ! -e "$STUB_STATE/mount_fail" ] || exit 32
cp "$STUB_STATE/mount_result" "$STUB_STATE/mounted"
EOF
cat >"$STUB/lsblk" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_STATE/labels"
EOF
cat >"$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
EOF
# -o·-g를 빼고 진짜 install을 부른다(root가 아니어도 돌게). 소유 판정은 시험이 LEDGER_*OWNER를 자기 uid로 바꿔 본다.
cat >"$STUB/install" <<'EOF'
#!/usr/bin/env bash
args=()
while [ "$#" -gt 0 ]; do case "$1" in -o | -g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
PATH="${PATH#*:}" exec install "${args[@]}"
EOF
# STUB_NO_SUDO면 자격 없음(sudo -n 실패). 아니면 -n을 빼고 그대로 부른다.
cat >"$STUB/sudo" <<'EOF'
#!/usr/bin/env bash
[ -z "${STUB_NO_SUDO:-}" ] || exit 1
[ "${1:-}" != -n ] || shift
exec "$@"
EOF
chmod +x "$STUB"/*

# host/ 사본: 값 형식 시험용 클러스터 파일을 더한다.
cp -R "$ROOT/host" "$TMP/host"
mkenv() { sed -e "s|^BULK_SSD_LABEL=.*|BULK_SSD_LABEL=\"$2\"|" -e "s|^BULK_MOUNT=.*|BULK_MOUNT=\"$3\"|" \
  "$ROOT/host/clusters/prod.env" >"$TMP/host/clusters/$1.env"; }
mkenv t-label-only bulk-ssd ""
mkenv t-root bulk-ssd /
mkenv t-dotdot bulk-ssd /mnt/../etc
mkenv t-space "bulk ssd" /mnt/bulk
mkenv t-long "abcdefghijklmnopq" /mnt/bulk

# ------------------------------------------------------------------------------ 실행 틀
# new_case <이름>: 새 가짜 루트. 장치 1개(ext4), 미마운트, 빈 마운트 지점, 기존 fstab 두 줄(끝 개행 없음).
new_case() {
  D="$TMP/$1"
  mkdir -p "$D/state" "$D/mnt/bulk" "$D/tmpd"
  : >"$D/log"
  printf '%s\n' "$DEV" >"$D/state/devices"
  echo ext4 >"$D/state/fstype"
  printf '%s\n' "$D/mnt/bulk" >"$D/state/mountpoint"
  printf '%s ext4 rw,nosuid,nodev,noexec,relatime bulk-ssd\n' "$DEV" >"$D/state/mount_result"
  printf 'bulk-ssd\n' >"$D/state/labels"
  echo 3f2a8c1e-5b7d-4e9a-8c0f-1a2b3c4d5e6f >"$D/uuid"
  printf '/dev/mapper/vg-root / ext4 defaults 0 1\n/boot/efi vfat umask=0077 0 1' >"$D/fstab"
}

want_line() { printf 'LABEL=bulk-ssd %s ext4 defaults,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=10s 0 2' "$1/mnt/bulk"; }

# mounted_now <케이스 디렉터리>: install 없이 이미 마운트된 상태로 둔다.
mounted_now() { cp "$1/state/mount_result" "$1/state/mounted"; }

# ledger_dirs <케이스 디렉터리>: 원장 디렉터리를 계약 모드로 미리 만든다(기존 원장 시험용).
ledger_dirs() { mkdir -p "$1/mnt/bulk/homelab-bot/deletion-ledger"; chmod 0755 "$1/mnt/bulk/homelab-bot"; chmod 0750 "$1/mnt/bulk/homelab-bot/deletion-ledger"; }
LD() { printf '%s/mnt/bulk/homelab-bot/deletion-ledger' "$1"; }

# run_install <케이스 디렉터리> [클러스터]: install.sh를 source해 bulk_ssd만 부른다. 출력은 $D/out, 종료 코드는 $D/rc.
run_install() {
  local d="$1" cluster="${2:-prod}" rc=0
  (
    export PATH="$STUB:$PATH" STUB_STATE="$d/state" STUB_LOG="$d/log" FAKE_UUID
    # shellcheck source=../host/install.sh
    . "$TMP/host/install.sh"
    load_cluster "$cluster"
    if [ -n "$BULK_MOUNT" ]; then BULK_MOUNT="$d/mnt/bulk"; fi
    FSTAB="$d/fstab" TMPD="$d/tmpd" UUID_SRC="$d/uuid" LEDGER_OWNER="$ME" LEDGER_PARENT_OWNER="$ME"
    bulk_ssd
  ) >"$d/out" 2>&1 || rc=$?
  echo "$rc" >"$d/rc"
}

# expect <설명> <케이스 디렉터리> <조건...>
#   rc:<n>, out:<글자>, !out:<글자>, log:<글자>, !log:<글자>, nodir(원장 상위 디렉터리 없음),
#   fstab=<파일>(fstab이 그 파일과 같음), backups:<n>(fstab 백업 수), want:<n>(기대 줄 수)
expect() {
  local desc="$1" d="$2" c bad="" got
  shift 2
  for c in "$@"; do
    case "$c" in
      rc:*) [ "$(cat "$d/rc")" = "${c#rc:}" ] || bad+=" 종료 $(cat "$d/rc")(기대 ${c#rc:})" ;;
      out:*) grep -qF -- "${c#out:}" "$d/out" || bad+=" 출력에 '${c#out:}' 없음" ;;
      '!out:'*) if grep -qF -- "${c#!out:}" "$d/out"; then bad+=" 출력에 '${c#!out:}' 있음"; fi ;;
      log:*) grep -qF -- "${c#log:}" "$d/log" || bad+=" 로그에 '${c#log:}' 없음" ;;
      '!log:'*) if grep -qF -- "${c#!log:}" "$d/log"; then bad+=" 로그에 '${c#!log:}' 있음"; fi ;;
      nodir) if [ -e "$d/mnt/bulk/homelab-bot" ]; then bad+=" 원장 디렉터리가 생겼다"; fi ;;
      fstab=*) cmp -s "$d/fstab" "${c#fstab=}" || bad+=" fstab이 바뀌었다" ;;
      backups:*)
        got="$(find "$d" -maxdepth 1 -name 'fstab.pre-host-install.*' | grep -c . || true)"
        [ "$got" = "${c#backups:}" ] || bad+=" 백업 ${got}개(기대 ${c#backups:})" ;;
      want:*)
        got="$(grep -cxF -- "$(want_line "$d")" "$d/fstab" || true)"
        [ "$got" = "${c#want:}" ] || bad+=" 기대 줄 ${got}개(기대 ${c#want:})" ;;
      *) bad+=" 모르는 조건 ${c}" ;;
    esac
  done
  if [ -z "$bad" ]; then pass "$desc"; else fail "${desc}:${bad}"$'\n'"$(cat "$d/out")"; fi
}

mode_of() { stat -c '%a' -- "$1"; }

# ------------------------------------------------------------------------------ 첫 실행·재실행
new_case first
cp "$D/fstab" "$D/fstab.orig"
run_install "$D"
expect "첫 실행: fstab 한 줄 더함(백업 1), daemon-reload 뒤 mount, 장치·UUID 출력" "$D" rc:0 want:1 backups:1 \
  "log:systemctl daemon-reload" "log:mount -- $D/mnt/bulk" "out:장치 ${DEV}, ext4, UUID ${FAKE_UUID}" "out:첫 초기화"
if [ "$(head -n 2 "$D/fstab")" = "$(cat "$D/fstab.orig")" ] && [ "$(tail -n 1 "$D/fstab")" = "$(want_line "$D")" ] \
  && [ "$(wc -l <"$D/fstab")" -eq 3 ]; then
  pass "첫 실행: 기존 줄 그대로, 끝 개행 없던 마지막 줄에 붙지 않고 새 줄로 더함"
else
  fail "첫 실행 fstab 모양:"$'\n'"$(cat "$D/fstab")"
fi
L="$(LD "$D")"
if [ "$(mode_of "$D/mnt/bulk/homelab-bot")" = 755 ] && [ "$(mode_of "$L")" = 750 ] \
  && [ "$(mode_of "$L/deletions.jsonl")" = 600 ] && [ "$(mode_of "$L/ledger.json")" = 600 ] && [ ! -s "$L/deletions.jsonl" ]; then
  pass "첫 실행: 상위 0755, 원장 디렉터리 0750, 빈 deletions.jsonl·ledger.json 0600"
else
  fail "첫 실행 모드: $(stat -c '%n %a %s' "$D/mnt/bulk/homelab-bot" "$L" "$L"/* 2>&1)"
fi
MARK="$(cat "$L/ledger.json"; printf .)"
if [[ "$MARK" =~ ^\{\"format\":\"homelab-bot-deletion-ledger\",\"version\":1,\"generation\":\"3f2a8c1e-5b7d-4e9a-8c0f-1a2b3c4d5e6f\",\"initializedAt\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\"\}$'\n'\.$ ]]; then
  pass "첫 실행: 표식이 계약 v1의 정확한 한 줄 + 개행(generation은 UUID 원천)"
else
  fail "첫 실행 표식: ${MARK}"
fi
cp "$L/ledger.json" "$D/marker.first"
cp "$D/fstab" "$D/fstab.after1"

: >"$D/log"
run_install "$D"
expect "재실행: fstab 그대로(줄 1개, 백업 늘지 않음), mount 다시 안 부름, 원장 그대로" "$D" rc:0 want:1 backups:1 \
  "fstab=$D/fstab.after1" "!log:mount --" "out:이미 있다" "out:이미 마운트돼 있다" "out:원장이 이미 있다" "!out:첫 초기화"
if cmp -s "$L/ledger.json" "$D/marker.first"; then pass "재실행: 표식(generation) 그대로"; else fail "재실행: 표식이 바뀌었다"; fi

printf '{"memoryId":"m-1","createdAt":"2026-11-02T00:00:00Z","deletedAt":"2026-11-02T00:01:00Z"}\n' >>"$L/deletions.jsonl"
cp "$L/deletions.jsonl" "$D/jsonl.before"
run_install "$D"
expect "기록이 있는 원장 재실행: 통과" "$D" rc:0 "out:원장이 이미 있다"
if cmp -s "$L/deletions.jsonl" "$D/jsonl.before" && cmp -s "$L/ledger.json" "$D/marker.first"; then
  pass "기록이 있는 원장 재실행: 원장·표식을 덮지 않음"
else
  fail "기록이 있는 원장 재실행: 원장이나 표식이 바뀌었다"
fi

touch "$L/notes.txt"
chmod 0600 "$L/notes.txt"
run_install "$D"
expect "계약 밖 항목이 있어도 두 파일이 맞으면 통과하고 알린다" "$D" rc:0 "out:계약 밖 항목이 있다" "out:notes.txt"
FIRST="$D"

# ------------------------------------------------------------------------------ 건너뜀·값 형식
new_case vm
cp "$D/fstab" "$D/fstab.orig"
run_install "$D" vm
expect "VM(빈 값): 건너뜀, blkid·mount 없음, fstab 그대로" "$D" rc:0 "out:건너뛴다" "!log:blkid" "!log:mount" nodir "fstab=$D/fstab.orig"

for c in "t-label-only:둘 다 비우거나 둘 다 채운다" "t-root:BULK_MOUNT는" "t-dotdot:BULK_MOUNT는" \
  "t-space:BULK_SSD_LABEL 형식" "t-long:BULK_SSD_LABEL 형식"; do
  out="$(cd "$TMP" && bash -c '. "$1/host/lib.sh" && load_cluster "$2"' _ "$TMP" "${c%%:*}" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && grep -qF -- "${c#*:}" <<<"$out"; then pass "값 형식 ${c%%:*}: load_cluster가 멈춤"; else fail "값 형식 ${c%%:*}: rc=${rc} ${out}"; fi
done

# ------------------------------------------------------------------------------ fstab 충돌
fstab_conflict() {
  new_case "$1"
  printf '\n%s\n' "$2" >>"$D/fstab"
  cp "$D/fstab" "$D/fstab.orig"
  run_install "$D"
  expect "$3" "$D" rc:1 "out:다른 줄이 있다" "fstab=$D/fstab.orig" backups:0 "!log:mount" nodir
}
fstab_conflict conflict-uuid "UUID=1111-2222 $TMP/conflict-uuid/mnt/bulk ext4 defaults 0 2" "같은 마운트 지점의 다른 줄(UUID=): 멈춤, 바꾸지 않음"
fstab_conflict conflict-opts "LABEL=bulk-ssd $TMP/conflict-opts/mnt/bulk ext4 defaults,nofail 0 2" "같은 지점·같은 라벨에 옵션만 다른 줄: 멈춤"
fstab_conflict conflict-label "LABEL=bulk-ssd /srv/other ext4 defaults 0 2" "같은 라벨이 다른 지점에: 멈춤"
new_case conflict-dup
printf '\n%s\n%s\n' "$(want_line "$D")" "$(want_line "$D")" >>"$D/fstab"
cp "$D/fstab" "$D/fstab.orig"
run_install "$D"
expect "기대 줄이 이미 둘(중복): 멈춤, 더하지 않음" "$D" rc:1 "out:다른 줄이 있다" "fstab=$D/fstab.orig" want:2 nodir
new_case comment
printf '\n# LABEL=bulk-ssd %s ext4 defaults 0 2\n' "$D/mnt/bulk" >>"$D/fstab"
run_install "$D"
expect "주석 처리한 옛 줄은 충돌로 보지 않음" "$D" rc:0 want:1

# ------------------------------------------------------------------------------ 장치
device_case() {
  new_case "$1"
  cp "$D/fstab" "$D/fstab.orig"
  "$2"
  run_install "$D"
  expect "$3" "$D" rc:1 "out:$4" "fstab=$D/fstab.orig" backups:0 "!log:mount" nodir
}
no_dev() { : >"$D/state/devices"; }
two_dev() { printf '%s\n/dev/fake-sda1\n' "$DEV" >"$D/state/devices"; }
xfs() { echo xfs >"$D/state/fstype"; }
elsewhere() { echo /media/usb >"$D/state/elsewhere"; }
other_mounted() { printf '/dev/fake-sdb1 ext4 rw,relatime other\n' >"$D/state/mounted"; }
ro_mounted() { printf '%s ext4 ro,nosuid,nodev,noexec,relatime bulk-ssd\n' "$DEV" >"$D/state/mounted"; }
stale_root() { touch "$D/mnt/bulk/leftover"; }
device_case dev-none no_dev "라벨 장치 0개: 멈춤" "장치가 0개다"
device_case dev-two two_dev "라벨 장치 2개: 멈춤" "장치가 2개다"
device_case dev-xfs xfs "ext4가 아님: 멈춤, 포맷하지 않음" "포맷하지 않는다"
device_case dev-elsewhere elsewhere "장치가 다른 곳에도 마운트: 멈춤" "밖에도 마운트돼 있다"
device_case mp-other other_mounted "마운트 지점에 다른 장치가 이미 마운트: 멈춤" "원본이 /dev/fake-sdb1다"
device_case mp-ro ro_mounted "이미 읽기 전용으로 마운트: 멈춤" "쓰기 가능(rw)이 아니다"
new_case stale-root
cp "$D/fstab" "$D/fstab.orig"
stale_root
run_install "$D"
expect "미마운트인데 루트 쪽 마운트 지점이 비어 있지 않음: 멈춤, 마운트로 가리지 않음" "$D" rc:1 \
  "out:비어 있지 않다" "out:leftover" "fstab=$D/fstab.orig" "!log:mount" nodir

# ------------------------------------------------------------------------------ 마운트 실패·불일치
new_case mount-fail
touch "$D/state/mount_fail"
run_install "$D"
expect "mount 실패: 원장 디렉터리를 만들지 않음" "$D" rc:1 "out:원장 디렉터리를 만들지 않았다" "log:mount --" nodir
new_case mount-wrong
printf '/dev/fake-sdb1 ext4 rw,relatime bulk-ssd\n' >"$D/state/mount_result"
run_install "$D"
expect "mount 뒤 findmnt 원본이 다른 장치: 원장 디렉터리를 만들지 않음" "$D" rc:1 "out:마운트 확인 실패" nodir
new_case mount-ro
printf '%s ext4 ro,relatime bulk-ssd\n' "$DEV" >"$D/state/mount_result"
run_install "$D"
expect "mount 뒤 읽기 전용: 원장 디렉터리를 만들지 않음" "$D" rc:1 "out:마운트 확인 실패" nodir
new_case mount-silent
: >"$D/state/mount_result"
run_install "$D"
expect "mount가 0으로 끝났는데 findmnt에 없음: 원장 디렉터리를 만들지 않음" "$D" rc:1 "out:마운트가 없다" nodir
new_case mount-nolabel
printf '%s ext4 rw,relatime \n' "$DEV" >"$D/state/mount_result"
run_install "$D"
expect "mount 뒤 라벨이 다름: 원장 디렉터리를 만들지 않음" "$D" rc:1 "out:라벨을 읽지 못했다" nodir

# ------------------------------------------------------------------------------ 기존 원장 디렉터리
existing() {
  new_case "$1"
  mounted_now "$D"
  ledger_dirs "$D"
}
existing only-jsonl
L="$(LD "$D")"
printf '{"memoryId":"m-1","createdAt":"2026-11-02T00:00:00Z","deletedAt":"2026-11-02T00:01:00Z"}\n' >"$L/deletions.jsonl"
chmod 0600 "$L/deletions.jsonl"
run_install "$D"
expect "비어 있지 않은데 표식 없음: 멈춤, restore.md 안내" "$D" rc:1 "out:ledger.json이(가) 없다" "out:restore.md" "out:만들지 않고 멈춘다"
if [ ! -e "$L/ledger.json" ]; then pass "표식 없음: 표식을 만들지 않음"; else fail "표식 없음: 표식이 생겼다"; fi

existing only-marker
L="$(LD "$D")"
printf '{"format":"homelab-bot-deletion-ledger","version":1,"generation":"3f2a8c1e-5b7d-4e9a-8c0f-1a2b3c4d5e6f","initializedAt":"2026-11-02T00:00:00Z"}\n' >"$L/ledger.json"
chmod 0600 "$L/ledger.json"
run_install "$D"
expect "비어 있지 않은데 원장 파일 없음: 멈춤" "$D" rc:1 "out:deletions.jsonl이(가) 없다" "out:restore.md"
if [ ! -e "$L/deletions.jsonl" ]; then pass "원장 파일 없음: 빈 원장을 만들지 않음"; else fail "원장 파일 없음: 빈 원장이 생겼다"; fi

existing other-only
L="$(LD "$D")"
touch "$L/stray"
run_install "$D"
expect "비어 있지 않은데 둘 다 없음(다른 파일만): 멈춤" "$D" rc:1 "out: deletions.jsonl ledger.json이(가) 없다" "out:stray"

existing bad-mode
L="$(LD "$D")"
: >"$L/deletions.jsonl"
cp "$FIRST/marker.first" "$L/ledger.json"
chmod 0644 "$L/deletions.jsonl"
chmod 0600 "$L/ledger.json"
run_install "$D"
expect "둘 다 있고 원장 파일 모드 0644: 멈춤, 고치지 않음" "$D" rc:1 "out:소유·모드가 계약 v1과 다르다" "out:644"
if [ "$(mode_of "$L/deletions.jsonl")" = 644 ]; then pass "모드 다름: chmod하지 않음"; else fail "모드 다름: 모드를 바꿨다"; fi

existing bad-marker
L="$(LD "$D")"
: >"$L/deletions.jsonl"
printf '{"format":"homelab-bot-deletion-ledger","version":1,"generation":"x"}\n' >"$L/ledger.json"
chmod 0600 "$L/deletions.jsonl" "$L/ledger.json"
run_install "$D"
expect "둘 다 있고 표식 형식이 틀림: 멈춤" "$D" rc:1 "out:한 줄 형식이 아니다"

existing two-lines
L="$(LD "$D")"
: >"$L/deletions.jsonl"
{ cat "$FIRST/marker.first"; cat "$FIRST/marker.first"; } >"$L/ledger.json"
chmod 0600 "$L/deletions.jsonl" "$L/ledger.json"
run_install "$D"
expect "표식이 두 줄: 멈춤" "$D" rc:1 "out:한 줄 형식이 아니다"

existing no-newline
L="$(LD "$D")"
: >"$L/deletions.jsonl"
printf '%s' "$(cat "$FIRST/marker.first")" >"$L/ledger.json"
chmod 0600 "$L/deletions.jsonl" "$L/ledger.json"
run_install "$D"
expect "표식 끝 개행 없음: 멈춤" "$D" rc:1 "out:한 줄 형식이 아니다"

existing empty-dir
run_install "$D"
expect "원장 디렉터리가 이미 있고 비어 있음: 초기화" "$D" rc:0 "out:첫 초기화" "!log:mount --"

existing dir-mode
chmod 0755 "$(LD "$D")"
run_install "$D"
expect "원장 디렉터리 모드 0755: 멈춤, 파일 만들지 않음" "$D" rc:1 "out:755 directory (기대 ${ME} 750 directory)"
if [ -z "$(find "$(LD "$D")" -mindepth 1)" ]; then pass "디렉터리 모드 다름: 파일을 만들지 않음"; else fail "디렉터리 모드 다름: 파일이 생겼다"; fi

existing dir-symlink
rm -rf "$(LD "$D")"
mkdir "$D/elsewhere-dir"
ln -s "$D/elsewhere-dir" "$(LD "$D")"
run_install "$D"
expect "원장 디렉터리가 심링크: 멈춤" "$D" rc:1 "out:symbolic link"

new_case bad-uuid
echo not-a-uuid >"$D/uuid"
run_install "$D"
expect "generation 원천이 UUID v4가 아님: 아무 파일도 만들지 않음" "$D" rc:1 "out:아무 파일도 만들지 않았다"
if [ -z "$(find "$(LD "$D")" -mindepth 1 2>/dev/null)" ]; then pass "UUID 이상: 원장 파일 없음"; else fail "UUID 이상: 원장 파일이 생겼다"; fi

# ------------------------------------------------------------------------------ 포맷 명령 없음
# 주석이 아닌 줄에 포맷·파티션·라벨 변경 명령이 나오면 실패한다. 설명 주석의 "mkfs"는 #에서 걸러진다.
if grep -nE '^[^#]*\b(mkfs(\.[a-z0-9]+)?|mke2fs|wipefs|tune2fs|e2label|sgdisk|parted|fdisk|sfdisk|dd)\b' \
  "$ROOT/host/install.sh" "$ROOT/host/lib.sh" "$ROOT/host/verify.sh"; then
  fail "host 스크립트에 포맷·파티션·라벨 변경 명령이 있다"
else
  pass "host 스크립트에 포맷·파티션·라벨 변경 명령이 없다"
fi

# ------------------------------------------------------------------------------ verify.sh check_bulk_ssd
# run_verify <케이스 디렉터리> [클러스터]: verify.sh를 source해 check_bulk_ssd만 부른다. 끝에 FAILS·UNVERIFIED를 낸다.
run_verify() {
  local d="$1" cluster="${2:-prod}"
  (
    export PATH="$STUB:$PATH" STUB_STATE="$d/state" STUB_LOG="$d/log"
    # shellcheck source=../host/verify.sh
    . "$TMP/host/verify.sh"
    load_cluster "$cluster"
    if [ -n "$BULK_MOUNT" ]; then BULK_MOUNT="$d/mnt/bulk"; fi
    FSTAB="$d/fstab" LEDGER_OWNER="$ME" LEDGER_PARENT_OWNER="$ME"
    check_bulk_ssd
    echo "FAILS=${FAILS} UNVERIFIED=${UNVERIFIED}"
  ) 2>&1
}

# vexpect <설명> <출력> <조건...>: 조건은 있어야 할 글자, !없어야 할 글자
vexpect() {
  local desc="$1" out="$2" t bad=""
  shift 2
  for t in "$@"; do
    case "$t" in
      '!'*) if grep -qF -- "${t#!}" <<<"$out"; then bad+=" '${t#!}'가 있다"; fi ;;
      *) grep -qF -- "$t" <<<"$out" || bad+=" '${t}'가 없다" ;;
    esac
  done
  if [ -z "$bad" ]; then pass "$desc"; else fail "verify ${desc}:${bad}"$'\n'"${out}"; fi
}

# 원장 내용은 출력하지 않는다(기억 ID). FIRST의 원장에는 m-1 기록이 있다.
vexpect "정상(install 뒤): 모두 ok, 원장 내용 출력 없음" "$(run_verify "$FIRST")" "FAILS=0 UNVERIFIED=0" \
  "ok   라벨 bulk-ssd 블록 장치 1개" "ok   fstab" "마운트(ext4, rw, 라벨 bulk-ssd)" "표식 형식 v1" '!m-1' '!FAIL '
vexpect "VM(빈 값): 건너뜀" "$(run_verify "$TMP/vm" vm)" "FAILS=0 UNVERIFIED=0" "쓰지 않는다(BULK_SSD_LABEL 빈 값)"

new_case v-unmounted
cp -R "$FIRST/mnt" "$D/"
want_line "$D" >"$D/fstab"
vexpect "미마운트 + 루트 쪽에 원장 경로: FAIL 둘" "$(run_verify "$D")" "FAILS=2" "마운트가 없다" "루트 디스크 쪽에"

new_case v-nofstab
mounted_now "$D"
vexpect "fstab 줄 없음·마운트만 있음: FAIL" "$(run_verify "$D")" "FAIL fstab" "줄이 기대와 다르다"

new_case v-twolabels
cp -R "$FIRST/mnt" "$D/"
want_line "$D" >"$D/fstab"
mounted_now "$D"
printf 'bulk-ssd\nbulk-ssd\n' >"$D/state/labels"
vexpect "라벨 장치 2개: FAIL" "$(run_verify "$D")" "블록 장치가 2개다"

new_case v-badmarker
cp -R "$FIRST/mnt" "$D/"
want_line "$D" >"$D/fstab"
mounted_now "$D"
printf '{"format":"x"}\n' >"$(LD "$D")/ledger.json"
vexpect "표식 형식 틀림: FAIL" "$(run_verify "$D")" "FAILS=1" "한 줄 형식이 아니다"

chmod 0640 "$(LD "$D")/deletions.jsonl"
vexpect "원장 파일 모드 0640: FAIL" "$(run_verify "$D")" "FAILS=1" "원장 파일이 계약 v1과 다르다" "640 regular file"

if [ "$(id -u)" -ne 0 ]; then
  vexpect "sudo 자격 없음: 원장 파일은 SKIP(미검증), 실패 아님" "$(STUB_NO_SUDO=1 run_verify "$FIRST")" \
    "FAILS=0 UNVERIFIED=1" "SKIP 원장 파일"
fi

# ------------------------------------------------------------------------------ 연결
# 출력을 다 받은 뒤 grep에 넘긴다. 파이프로 이으면 grep -q가 먼저 끝날 때 pipefail이 실패로 읽는다.
# shellcheck disable=SC2016
if grep -qw check_bulk_ssd <<<"$(bash -c '. "$1/host/verify.sh" && declare -f main' _ "$TMP")"; then
  pass "verify main이 check_bulk_ssd를 부른다"
else
  fail "verify main에 check_bulk_ssd가 없다"
fi
# shellcheck disable=SC2016
if grep -qw bulk_ssd <<<"$(bash -c '. "$1/host/install.sh" && declare -f main' _ "$TMP")"; then
  pass "install main이 --bulk-ssd를 bulk_ssd로 보낸다"
else
  fail "install main에 bulk_ssd가 없다"
fi
# shellcheck disable=SC2016
got="$(bash -c '. "$1/host/lib.sh" && load_cluster prod && printf "%s|%s;" "$BULK_SSD_LABEL" "$BULK_MOUNT" && load_cluster vm && printf "%s|%s" "$BULK_SSD_LABEL" "$BULK_MOUNT"' _ "$ROOT" 2>&1)" || true
if [ "$got" = "bulk-ssd|/mnt/bulk;|" ]; then
  pass "저장소 값: prod는 bulk-ssd·/mnt/bulk(원장 계약 v1), vm은 둘 다 빈 값"
else
  fail "저장소 값이 계약과 다르다: ${got}"
fi

# 0건 통과는 실패다(B.8 E7).
[ "$CASES" -gt 0 ] || { echo "FAIL 시험이 0건이다" >&2; exit 1; }
[ "$FAILS" -eq 0 ] || { echo "host-bulk: ${FAILS}/${CASES} 실패" >&2; exit 1; }
echo "host-bulk: ${CASES}건 통과"
