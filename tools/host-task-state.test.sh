#!/usr/bin/env bash
# host/install.sh --task-state-volume과 verify.sh check_task_state_volume의 시험(작업 레인 고정 크기 볼륨). ci가 부른다.
# root·실제 마운트·실제 포맷 없이 돈다. 가짜 mkfs.ext4·blkid·findmnt·losetup·systemctl·install·sudo와 임시 경로를 쓴다.
# fallocate·stat·cmp는 진짜이고 크기만 1MiB로 줄인다. 가짜 mkfs.ext4는 진짜처럼 파일에 구멍을 뚫는다(다시 채우는지 본다).
# 실제 마운트·idmap 쓰기는 사람이 병합 뒤 sudo host/install.sh --cluster <이름> --task-state-volume과 켠 파드로 본다.
#   이미지: 없으면 새 임시 파일에만 포맷하고 옮긴다. 있으면 다시 포맷하지 않는다. 크기·구멍·fs·UUID가 다르거나 기록이 없으면 멈춘다.
#   마운트: 이 이미지의 ext4·rw·nodev·nosuid일 때만 data를 만든다. 아니면 아무것도 만들지 않는다. 마운트 전 자리가 비어 있지 않으면 멈춘다.
#   data: 없으면 2770으로 만들고, 소유·모드가 다르면 고치지 않고 멈춘다.
# 실행 틀(run_install·run_verify)은 시험마다 서브셸에서 값을 바꿔 서로 섞이지 않게 한다. 바깥으로 새지 않는 것이 의도다.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
CASES=0
pass() { CASES=$((CASES + 1)); printf 'ok   %s\n' "$*"; }
fail() { CASES=$((CASES + 1)); FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$*" >&2; }
# check <조건 결과 0|그 밖> <설명> <실패 설명>
check() { if [ "$1" = 0 ]; then pass "$2"; else fail "$3"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ME="$(id -u):$(id -g)"
SIZE=1048576
LOOP=/dev/fake-loop7
UUID=3f2a8c1e-5b7d-4e9a-8c0f-1a2b3c4d5e6f
UNIT_NAME=var-lib-taskstate-mnt.mount

# ------------------------------------------------------------------------------ 가짜 명령
# 상태는 STUB_STATE 아래 파일이다.
#   fstype·uuid: blkid가 답할 값(가짜 mkfs가 쓴다), mounted: findmnt 줄, mount_result: 시작 뒤 mounted에 쓸 줄,
#   backfile: losetup이 답할 파일, start_fail·mkfs_fail·fallocate_fail: 있으면 그 명령 실패, enabled: is-enabled 답
STUB="$TMP/stub"
mkdir -p "$STUB"
cat >"$STUB/mkfs.ext4" <<'EOF'
#!/usr/bin/env bash
echo "mkfs.ext4 $*" >>"$STUB_LOG"
[ ! -e "$STUB_STATE/mkfs_fail" ] || exit 1
target="${*: -1}" uuid=""
while [ "$#" -gt 0 ]; do case "$1" in -U) uuid="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "$uuid" >"$STUB_STATE/uuid"
echo ext4 >"$STUB_STATE/fstype"
PATH="${PATH#*:}" fallocate -p -o 0 -l 65536 -- "$target"
EOF
cat >"$STUB/fallocate" <<'EOF'
#!/usr/bin/env bash
echo "fallocate $*" >>"$STUB_LOG"
[ ! -e "$STUB_STATE/fallocate_fail" ] || exit 1
PATH="${PATH#*:}" exec fallocate "$@"
EOF
cat >"$STUB/blkid" <<'EOF'
#!/usr/bin/env bash
echo "blkid $*" >>"$STUB_LOG"
case " $* " in
  *" -s TYPE "*) cat "$STUB_STATE/fstype" ;;
  *" -s UUID "*) cat "$STUB_STATE/uuid" ;;
  *) exit 9 ;;
esac
EOF
cat >"$STUB/findmnt" <<'EOF'
#!/usr/bin/env bash
[ -s "$STUB_STATE/mounted" ] || exit 1
cat "$STUB_STATE/mounted"
EOF
cat >"$STUB/losetup" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_STATE/backfile"
EOF
cat >"$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
case "$1" in
  start)
    [ ! -e "$STUB_STATE/start_fail" ] || exit 1
    cp "$STUB_STATE/mount_result" "$STUB_STATE/mounted"
    ;;
  enable) echo enabled >"$STUB_STATE/enabled" ;;
  is-enabled) cat "$STUB_STATE/enabled" 2>/dev/null || echo disabled ;;
esac
EOF
# -o·-g를 빼고 진짜 install을 부른다(root가 아니어도 돌게).
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

# 유닛의 What·Where를 시험 경로로 바꿔 쓰려고 host/ 사본을 케이스마다 둔다.
new_case() {
  D="$TMP/$1"
  mkdir -p "$D/state" "$D/var" "$D/etc" "$D/tmpd"
  cp -R "$ROOT/host" "$D/host"
  sed -i -e "s|^What=.*|What=$D/var/volume.img|" -e "s|^Where=.*|Where=$D/var/mnt|" "$D/host/task-state/$UNIT_NAME"
  : >"$D/log"
  echo "$UUID" >"$D/uuidsrc"
  printf '%s ext4 rw,nosuid,nodev,relatime 1000000\n' "$LOOP" >"$D/state/mount_result"
  printf '%s\n' "$D/var/volume.img" >"$D/state/backfile"
}

# 값 덮어쓰기. run_install·run_verify가 함께 쓴다(root 없이, 임시 경로, 1MiB).
override_values() {
  TASK_STATE_IMAGE="$1/var/volume.img" TASK_STATE_UUID_FILE="$1/var/volume.uuid"
  TASK_STATE_MOUNT="$1/var/mnt" TASK_STATE_DATA="$1/var/mnt/data"
  TASK_STATE_UNIT="$1/etc/$UNIT_NAME"
  TASK_STATE_BYTES="$SIZE" TASK_STATE_IMAGE_OWNER="$ME" TASK_STATE_DATA_OWNER="$ME"
}

# run_install <케이스 디렉터리>: install.sh를 source해 task_state_volume만 부른다. 출력은 $D/out, 종료 코드는 $D/rc.
run_install() {
  local d="$1" rc=0
  (
    export PATH="$STUB:$PATH" STUB_STATE="$d/state" STUB_LOG="$d/log"
    # shellcheck source=../host/install.sh
    . "$d/host/install.sh"
    load_cluster prod
    TMPD="$d/tmpd" UUID_SRC="$d/uuidsrc"
    override_values "$d"
    task_state_volume
  ) >"$d/out" 2>&1 || rc=$?
  echo "$rc" >"$d/rc"
}

# expect <설명> <케이스 디렉터리> <조건...>
#   rc:<n>, out:<글자>, !out:<글자>, log:<글자>, !log:<글자>, nodata(data 디렉터리 없음), noimage(이미지 없음)
expect() {
  local desc="$1" d="$2" c bad=""
  shift 2
  for c in "$@"; do
    case "$c" in
      rc:*) [ "$(cat "$d/rc")" = "${c#rc:}" ] || bad+=" 종료 $(cat "$d/rc")(기대 ${c#rc:})" ;;
      out:*) grep -qF -- "${c#out:}" "$d/out" || bad+=" 출력에 '${c#out:}' 없음" ;;
      '!out:'*) if grep -qF -- "${c#!out:}" "$d/out"; then bad+=" 출력에 '${c#!out:}' 있음"; fi ;;
      log:*) grep -qF -- "${c#log:}" "$d/log" || bad+=" 로그에 '${c#log:}' 없음" ;;
      '!log:'*) if grep -qF -- "${c#!log:}" "$d/log"; then bad+=" 로그에 '${c#!log:}' 있음"; fi ;;
      nodata) if [ -e "$d/var/mnt/data" ]; then bad+=" data가 생겼다"; fi ;;
      noimage) if [ -e "$d/var/volume.img" ]; then bad+=" 이미지가 생겼다"; fi ;;
      *) bad+=" 모르는 조건 ${c}" ;;
    esac
  done
  if [ -z "$bad" ]; then pass "$desc"; else fail "${desc}:${bad}"$'\n'"$(cat "$d/out")"; fi
}

# installed <이름>: 첫 실행까지 마친 케이스를 D에 둔다. 표식을 이미지에 넣어 포맷하면 드러나게 한다.
installed() {
  new_case "$1"
  run_install "$D"
  [ "$(cat "$D/rc")" = 0 ] || { echo "준비 실패: $(cat "$D/out")" >&2; exit 1; }
  printf 'keep' | dd of="$D/var/volume.img" bs=1 seek=1024 conv=notrunc status=none
  sha256sum "$D/var/volume.img" >"$D/img.sum"
  : >"$D/log"
}
unchanged() {
  if sha256sum --status -c "$D/img.sum"; then pass "$1: 이미지 그대로"; else fail "$1: 이미지가 바뀌었다"; fi
}

# ------------------------------------------------------------------------------ 첫 실행·재실행
new_case first
run_install "$D"
expect "첫 실행: 임시 파일에만 포맷, 다시 채움, 유닛 enable·start, data 생성" "$D" rc:0 \
  "log:$D/var/volume.img.new" "log:systemctl daemon-reload" "log:systemctl enable $UNIT_NAME" \
  "log:systemctl start $UNIT_NAME" "out:만듦 $D/var/volume.img" "out:UUID ${UUID}"
if [ "$(grep -c '^mkfs.ext4 ' "$D/log")" = 1 ] && [ "$(grep -c "^fallocate -l ${SIZE} -- $D/var/volume.img.new" "$D/log")" = 2 ] \
  && grep -qE '^mkfs\.ext4 .*-m 0 .*nodiscard.* [^ ]+\.img\.new$' "$D/log"; then
  pass "첫 실행: fallocate → mkfs(nodiscard, -m 0, 임시 파일) → fallocate"
else
  fail "첫 실행 명령: $(cat "$D/log")"
fi
got="$(stat -c '%s %a' "$D/var/volume.img") $(($(stat -c '%b*%B' "$D/var/volume.img")))"
if [ "$got" = "$SIZE 600 $SIZE" ] && [ ! -e "$D/var/volume.img.new" ]; then
  pass "첫 실행: 이미지 정확한 크기·0600·구멍 없음(mkfs가 뚫은 구멍을 다시 채움), 임시 파일 없음"
else
  fail "첫 실행 이미지: ${got}"
fi
rc=0; [ "$(cat "$D/var/volume.uuid")" = "$UUID" ] || rc=1
check "$rc" "첫 실행: UUID 기록" "첫 실행 UUID 기록: $(cat "$D/var/volume.uuid")"
rc=0; [ "$(stat -c %a "$D/var/mnt/data" 2>/dev/null)" = 2770 ] || rc=1
check "$rc" "첫 실행: data 2770" "첫 실행 data 모드가 2770이 아니다"
FIRST="$D"

installed rerun
run_install "$D"
expect "재실행: 포맷·fallocate·start 없음" "$D" rc:0 "!log:mkfs.ext4" "!log:fallocate" "!log:systemctl start" "out:포맷하지 않는다" "out:이미 마운트돼 있다"
unchanged "재실행"

# ------------------------------------------------------------------------------ 있는 이미지는 포맷하지 않는다
refuse() {
  run_install "$D"
  expect "$1" "$D" rc:1 "!log:mkfs.ext4" "!log:fallocate" "out:$2"
  unchanged "$1"
}
installed no-record
rm -f "$D/var/volume.uuid"
refuse "이미지는 있고 UUID 기록 없음: 멈춤" "UUID 기록"
installed wrong-uuid
echo 00000000-0000-4000-8000-000000000000 >"$D/state/uuid"
refuse "UUID가 기록과 다름: 멈춤" "UUID가 기록"
installed wrong-fs
echo xfs >"$D/state/fstype"
refuse "ext4 아님: 멈춤" "ext4가 아니다"
installed wrong-size
truncate -s $((SIZE * 2)) "$D/var/volume.img"
sha256sum "$D/var/volume.img" >"$D/img.sum"
refuse "크기가 다름: 멈춤" "크기가"
installed sparse
fallocate -p -o 65536 -l 65536 -- "$D/var/volume.img"
sha256sum "$D/var/volume.img" >"$D/img.sum"
refuse "구멍이 뚫림: 멈춤" "미리 할당되지 않았다"

installed lost-image
rm -f "$D/var/volume.img"
: >"$D/state/mounted"
run_install "$D"
expect "기록은 있고 이미지 없음: 빈 이미지로 대신하지 않고 멈춤" "$D" rc:1 "!log:mkfs.ext4" noimage "out:빈 이미지로 대신하지 않고"

new_case leftover
: >"$D/var/volume.img.new"
run_install "$D"
expect "지난 임시 파일이 남음: 멈춤" "$D" rc:1 "!log:mkfs.ext4" noimage "out:지난 실행이 끊겼다"

# ------------------------------------------------------------------------------ 만들기 실패
new_case mkfs-fail
: >"$D/state/mkfs_fail"
run_install "$D"
expect "mkfs 실패: 이미지 없음, 시작 안 함" "$D" rc:1 noimage nodata "!log:systemctl start" "out:포맷이 실패했다"
rc=0; [ ! -e "$D/var/volume.uuid" ] || rc=1
check "$rc" "mkfs 실패: UUID 기록 없음" "mkfs 실패: UUID 기록이 생겼다"

new_case fallocate-fail
: >"$D/state/fallocate_fail"
run_install "$D"
expect "fallocate 실패: mkfs 안 함" "$D" rc:1 noimage "!log:mkfs.ext4" "out:디스크 공간"

# ------------------------------------------------------------------------------ 마운트
new_case rootside
mkdir -p "$D/var/mnt"
touch "$D/var/mnt/old"
run_install "$D"
expect "마운트 전 자리가 비어 있지 않음: 멈춤, 포맷 안 함" "$D" rc:1 "!log:mkfs.ext4" noimage "out:가리지 않고 멈춘다"

new_case symlink
ln -s /tmp "$D/var/mnt"
run_install "$D"
expect "마운트 지점이 심링크: 멈춤" "$D" rc:1 "!log:mkfs.ext4" "out:디렉터리가 아니다"

new_case start-fail
: >"$D/state/start_fail"
run_install "$D"
expect "유닛 시작 실패: data 안 만듦" "$D" rc:1 nodata "out:시작이 실패했다"

new_case other-back
printf '/somewhere/else.img\n' >"$D/state/backfile"
run_install "$D"
expect "시작 뒤 다른 이미지가 붙음: data 안 만듦" "$D" rc:1 nodata "out:뒤 파일이"

new_case too-big
printf '%s ext4 rw,nosuid,nodev,relatime %s\n' "$LOOP" $((SIZE * 2)) >"$D/state/mount_result"
run_install "$D"
expect "시작 뒤 파일시스템이 상한보다 큼: data 안 만듦" "$D" rc:1 nodata "out:상한"

new_case readonly
printf '%s ext4 ro,nosuid,nodev,relatime 1000000\n' "$LOOP" >"$D/state/mount_result"
run_install "$D"
expect "읽기 전용 마운트: data 안 만듦" "$D" rc:1 nodata "out:쓰기 가능(rw)이 아니다"

new_case no-hardening
printf '%s ext4 rw,nodev,relatime 1000000\n' "$LOOP" >"$D/state/mount_result"
run_install "$D"
expect "nosuid 없음: data 안 만듦" "$D" rc:1 nodata "out:nodev·nosuid가 없다"

installed mounted-other
printf '%s xfs rw,nosuid,nodev,relatime 1000000\n' "$LOOP" >"$D/state/mounted"
refuse "이미 다른 형식이 마운트됨: 멈춤" "기대 ext4"

installed unit-differs
printf '# 손으로 고침\n' >>"$D/etc/$UNIT_NAME"
refuse "깔린 유닛이 Git과 다름: 덮지 않고 멈춤" "덮지 않고"

installed wrong-where
sed -i "s|^Where=.*|Where=/somewhere|" "$D/host/task-state/$UNIT_NAME"
refuse "유닛 Where가 값과 다름: 멈춤" "What·Where"

# ------------------------------------------------------------------------------ data
installed data-mode
chmod 0777 "$D/var/mnt/data"
run_install "$D"
expect "data 모드가 다름: 고치지 않고 멈춤" "$D" rc:1 "out:고치지 않고 멈춘다"
# 숫자 chmod는 디렉터리의 setgid를 지우지 않아 2777로 남는다.
rc=0; [ "$(stat -c %a "$D/var/mnt/data")" = 2777 ] || rc=1
check "$rc" "data 모드: 그대로 둠" "data 모드를 고쳤다"

# ------------------------------------------------------------------------------ verify.sh
# run_verify <케이스 디렉터리>: verify.sh를 source해 check_task_state_volume만 부른다. 끝에 FAILS·UNVERIFIED를 낸다.
run_verify() {
  local d="$1"
  (
    export PATH="$STUB:$PATH" STUB_STATE="$d/state" STUB_LOG="$d/log"
    # shellcheck source=../host/verify.sh
    . "$d/host/verify.sh"
    load_cluster prod
    override_values "$d"
    check_task_state_volume
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

vexpect "정상(install 뒤): 모두 ok" "$(run_verify "$FIRST")" "FAILS=0 UNVERIFIED=0" "이미지 ext4, UUID가 기록과 같다"
if [ "$(id -u)" -ne 0 ]; then
  vexpect "sudo 자격 없음: fs·UUID는 SKIP(미검증), 실패 아님" "$(STUB_NO_SUDO=1 run_verify "$FIRST")" "FAILS=0 UNVERIFIED=1" "SKIP 작업 레인 이미지"
fi

installed v-unmounted
: >"$D/state/mounted"
vexpect "미마운트 + 루트 쪽에 data: FAIL 둘" "$(run_verify "$D")" "FAILS=2" "마운트가 없다" "루트 디스크 쪽에"

installed v-backfile
printf '/somewhere/else.img\n' >"$D/state/backfile"
vexpect "다른 파일이 붙음: FAIL" "$(run_verify "$D")" "FAILS=1" "뒤 파일이"

installed v-big
printf '%s ext4 rw,nosuid,nodev,relatime %s\n' "$LOOP" $((SIZE * 2)) >"$D/state/mounted"
vexpect "상한보다 큼: FAIL" "$(run_verify "$D")" "FAILS=1" "상한"

installed v-disabled
echo disabled >"$D/state/enabled"
vexpect "유닛이 꺼짐: FAIL" "$(run_verify "$D")" "FAILS=1" "enabled가 아니다"

installed v-unit
printf '# 손으로 고침\n' >>"$D/etc/$UNIT_NAME"
vexpect "유닛 내용 다름: FAIL" "$(run_verify "$D")" "FAILS=1" "host/task-state/와 다르다"

installed v-uuid
echo 00000000-0000-4000-8000-000000000000 >"$D/state/uuid"
vexpect "UUID 다름: FAIL" "$(run_verify "$D")" "FAILS=1" "UUID가 기록"

installed v-sparse
fallocate -p -o 65536 -l 65536 -- "$D/var/volume.img"
vexpect "이미지 구멍: FAIL" "$(run_verify "$D")" "FAILS=1" "미리 할당되지 않았다"

installed v-data
chmod 0777 "$D/var/mnt/data"
vexpect "data 모드 다름: FAIL" "$(run_verify "$D")" "FAILS=1" "data 디렉터리가 기대와 다르다"

# ------------------------------------------------------------------------------ 연결·저장소 값
# 출력을 다 받은 뒤 grep에 넘긴다. 파이프로 이으면 grep -q가 먼저 끝날 때 pipefail이 실패로 읽는다.
# shellcheck disable=SC2016
if grep -qw check_task_state_volume <<<"$(bash -c '. "$1/host/verify.sh" && declare -f main' _ "$ROOT")"; then
  pass "verify main이 check_task_state_volume을 부른다"
else
  fail "verify main에 check_task_state_volume이 없다"
fi
# shellcheck disable=SC2016
if grep -qw task_state_volume <<<"$(bash -c '. "$1/host/install.sh" && declare -f main' _ "$ROOT")"; then
  pass "install main이 --task-state-volume을 task_state_volume으로 보낸다"
else
  fail "install main에 task_state_volume이 없다"
fi
# shellcheck disable=SC2016
got="$(bash -c '. "$1/host/lib.sh" && printf "%s %s %s %s" "$TASK_STATE_IMAGE" "$TASK_STATE_MOUNT" "$TASK_STATE_BYTES" "$TASK_STATE_UNIT_NAME"' _ "$ROOT" 2>&1)" || true
if [ "$got" = "/var/lib/taskstate/volume.img /var/lib/taskstate/mnt 2147483648 $UNIT_NAME" ]; then
  pass "저장소 값: 이미지·마운트 경로, 2GiB, 유닛 이름"
else
  fail "저장소 값이 다르다: ${got}"
fi
UNIT="$ROOT/host/task-state/$UNIT_NAME"
if grep -qxF 'What=/var/lib/taskstate/volume.img' "$UNIT" && grep -qxF 'Where=/var/lib/taskstate/mnt' "$UNIT" \
  && grep -qxF 'Before=k3s.service' "$UNIT" && grep -qxF 'WantedBy=local-fs.target' "$UNIT" \
  && ! grep -qE '^Options=.*discard' "$UNIT"; then
  pass "유닛: 값과 같은 What·Where, k3s보다 먼저, discard 없음"
else
  fail "유닛 내용이 계약과 다르다"
fi
if command -v systemd-escape >/dev/null 2>&1; then
  got="$(systemd-escape --suffix=mount --path /var/lib/taskstate/mnt)"
  rc=0; [ "$got" = "$UNIT_NAME" ] || rc=1
  check "$rc" "유닛 이름이 Where와 맞다" "유닛 이름이 Where와 다르다: ${got}"
fi

# 0건 통과는 실패다(B.8 E7).
[ "$CASES" -gt 0 ] || { echo "FAIL 시험이 0건이다" >&2; exit 1; }
[ "$FAILS" -eq 0 ] || { echo "host-task-state: ${FAILS}/${CASES} 실패" >&2; exit 1; }
echo "host-task-state: ${CASES}건 통과"
