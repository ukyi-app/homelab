#!/usr/bin/env bash
# 샌드박스 프로필의 시험. ci가 부른다. root·AppArmor·Go 없이 돈다.
#   저장소 값: 생성 결과 = 커밋한 프로필(base/ 기준), 이름·peer 규칙, k3s·containerd·go.mod 짝, seccomp 차이.
#   install.sh --sandbox-profiles: 첫 설치·재실행 멱등, 옛 버전 보존, 멈춰야 할 때 아무것도 바꾸지 않음, 적재 실패 판정.
#   verify.sh check_sandbox_profiles: 통과, 해시·적재·판 차이, sudo 없을 때 미검증.
# 가짜 apparmor_parser·systemctl과 임시 경로를 쓴다. "적재"는 가짜 파서가 상태 파일에 적는 것이다.
# 실제 문법 검사와 containerd 기본값 재생성은 tools/sandbox-profiles/regen.sh --check, 실제 적재는 사람이 sudo로 본다.
# 실행 틀은 시험마다 서브셸에서 값을 바꿔 서로 섞이지 않게 한다. 바깥으로 새지 않는 것이 의도다.
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
PROFILES="$ROOT/host/sandbox-profiles"
SECCOMP_NAME=sandbox-worker-v1.json
APPARMOR_NAME=homelab-sandbox-worker-v1

# ------------------------------------------------------------------------------ 저장소 값

if bun "$ROOT/tools/sandbox-profiles/generate.ts" --check >"$TMP/gen.out" 2>&1; then
  pass "생성 결과가 커밋한 프로필과 같다"
else
  fail "생성 결과가 다르다: $(cat "$TMP/gen.out")"
fi

mkdir -p "$TMP/tampered"
cp -r "$PROFILES" "$TMP/tampered/sandbox-profiles"
printf '# 손으로 고침\n' >>"$TMP/tampered/sandbox-profiles/apparmor/$APPARMOR_NAME"
if bun "$ROOT/tools/sandbox-profiles/generate.ts" --check --host-dir "$TMP/tampered" >"$TMP/gen.out" 2>&1; then
  fail "손으로 고친 프로필을 --check가 통과시켰다"
else
  pass "손으로 고친 프로필을 --check가 잡는다"
fi

# base의 줄이 바뀌면 조용히 지나가지 않고 멈춰야 한다. generate.ts를 복사해 base만 바꾼 사본으로 돌린다.
mkdir -p "$TMP/driftgen/base"
cp "$ROOT/tools/sandbox-profiles/generate.ts" "$TMP/driftgen/"
cp "$ROOT/tools/sandbox-profiles/base/seccomp.json" "$TMP/driftgen/base/"
sed 's/^  deny mount,$/  deny mount fstype=tmpfs,/' "$ROOT/tools/sandbox-profiles/base/apparmor.txt" >"$TMP/driftgen/base/apparmor.txt"
if bun "$TMP/driftgen/generate.ts" --check --host-dir "$ROOT/host" >"$TMP/gen.out" 2>&1; then
  fail "containerd 기본값이 바뀌어도 생성기가 멈추지 않았다"
elif grep -q '기대 1' "$TMP/gen.out"; then
  pass "containerd 기본값의 줄이 바뀌면 생성기가 멈춘다"
else
  fail "생성기가 다른 이유로 실패했다: $(cat "$TMP/gen.out")"
fi

want_seccomp='["clone","unshare","mount","umount2","pivot_root","sethostname"]'
got="$(jq -c '.syscalls[-1].names' "$PROFILES/seccomp/$SECCOMP_NAME")"
act="$(jq -r '.syscalls[-1].action' "$PROFILES/seccomp/$SECCOMP_NAME")"
extra="$(jq -n --slurpfile a "$PROFILES/seccomp/$SECCOMP_NAME" --slurpfile b "$ROOT/tools/sandbox-profiles/base/seccomp.json" \
  '$a[0] | del(.syscalls[-1]) == $b[0]')"
if [ "$got" = "$want_seccomp" ] && [ "$act" = SCMP_ACT_ALLOW ] && [ "$extra" = true ]; then
  pass "seccomp: 기본값에 더한 것은 syscall 6개 묶음 하나뿐이다"
else
  fail "seccomp 차이가 기대와 다르다: names=${got} action=${act} 나머지 같음=${extra}"
fi

bad_names=""
for f in "$PROFILES"/apparmor/*; do
  n="$(basename "$f")"
  grep -q "^profile ${n} flags=" "$f" || bad_names+=" ${n}:선언"
  # 주석을 뺀 규칙에서 peer로 자기 이름을 부르는 줄이 모두 이 파일의 이름이어야 한다. 이름을 바꾸다 빠뜨리면 kill·ptrace가 조용히 막힌다.
  others="$(grep -E '^[[:space:]]*(signal|ptrace) ' "$f" | grep -oE 'peer=[^,]*' \
    | grep -vE "^peer=(\*\*)?${n}(\*\*)?\$|^peer=(unconfined|runc|crun)\$" || true)"
  [ -z "$others" ] || bad_names+=" ${n}:peer(${others})"
  # 겹친 라벨과 bwrap의 mount는 userns를 쓰는 worker에만 있다.
  case "$n" in
    homelab-sandbox-worker-*)
      for rule in "signal (send,receive) peer=${n}," "signal (send,receive) peer=**${n}**," \
        "ptrace (trace,tracedby,read,readby) peer=${n}," "ptrace (trace,tracedby,read,readby) peer=**${n}**,"; do
        grep -qF -- "  ${rule}" "$f" || bad_names+=" ${n}:없음(${rule})"
      done
      if grep -q '^[[:space:]]*deny mount' "$f"; then bad_names+=" ${n}:deny-mount"; fi
      ;;
  esac
done
if [ -z "$bad_names" ]; then
  pass "AppArmor: 선언·peer 규칙이 파일 이름과 맞고, worker에 겹친 라벨 규칙이 있고 deny mount가 없다"
else
  fail "AppArmor 이름 규칙:${bad_names}"
fi

# node-exporter 프로필은 호스트 루트가 보이는 파드에 붙으므로 기본값보다 넓어지면 안 된다. 기본값의 줄은 하나도 빠지지 않고,
# 더한 규칙은 시스템 버스의 읽기 호출 셋뿐이어야 한다. 주석 줄과 빈 줄은 판정에서 뺀다.
NE_NAME=homelab-sandbox-node-exporter-v1
ne_file="$PROFILES/apparmor/$NE_NAME"
ne_rules() { grep -vE '^[[:space:]]*(#|$)' "$1" | sed "s/@PROFILE_NAME@/${NE_NAME}/g" | LC_ALL=C sort; }
ne_removed="$(LC_ALL=C comm -23 <(ne_rules "$ROOT/tools/sandbox-profiles/base/apparmor.txt") <(ne_rules "$ne_file"))"
ne_added="$(LC_ALL=C comm -13 <(ne_rules "$ROOT/tools/sandbox-profiles/base/apparmor.txt") <(ne_rules "$ne_file"))"
ne_want="$(LC_ALL=C sort <<'EOF'
  dbus send bus=system path=/org/freedesktop/DBus interface=org.freedesktop.DBus member=Hello peer=(name=org.freedesktop.DBus),
  dbus send bus=system path=/org/freedesktop/systemd1 interface=org.freedesktop.systemd1.Manager member=ListUnits peer=(name=org.freedesktop.systemd1),
  dbus send bus=system path=/org/freedesktop/systemd1{,/unit/*} interface=org.freedesktop.DBus.Properties member=Get peer=(name=org.freedesktop.systemd1),
EOF
)"
if [ -z "$ne_removed" ] && [ "$ne_added" = "$ne_want" ]; then
  pass "node-exporter AppArmor: 기본값에서 빠진 규칙이 없고 더한 것은 dbus 읽기 호출 셋뿐이다"
else
  fail "node-exporter AppArmor 차이가 기대와 다르다. 빠짐: ${ne_removed:-없음} 더함: ${ne_added:-없음}"
fi

# shellcheck source=../host/versions.env
versions="$(. "$ROOT/host/versions.env" && printf '%s|%s|%s' "$INSTALL_K3S_VERSION" "$SANDBOX_PROFILE_K3S" "$SANDBOX_PROFILE_CONTAINERD")"
IFS='|' read -r k3s pair_k3s pair_ctr <<<"$versions"
if [ "$k3s" = "$pair_k3s" ]; then
  pass "k3s 짝: INSTALL_K3S_VERSION = SANDBOX_PROFILE_K3S (${k3s})"
else
  fail "k3s를 ${k3s}로 올렸는데 샌드박스 프로필은 ${pair_k3s} 기준이다. 그 k3s의 containerd로 tools/sandbox-profiles/regen.sh를 돌리고 다시 잰 뒤 SANDBOX_PROFILE_K3S·SANDBOX_PROFILE_CONTAINERD를 옮긴다"
fi
gomod="$(awk '$1 == "github.com/containerd/containerd/v2" { print $2 }' "$ROOT/tools/sandbox-profiles/containerd-defaults/go.mod")"
if [ "v${pair_ctr%%-*}" = "$gomod" ]; then
  pass "containerd 짝: go.mod ${gomod} = SANDBOX_PROFILE_CONTAINERD ${pair_ctr}"
else
  fail "go.mod containerd ${gomod}가 SANDBOX_PROFILE_CONTAINERD ${pair_ctr}와 다르다"
fi

# ------------------------------------------------------------------------------ 가짜 명령
# 상태는 STUB_STATE 아래 파일이다. loaded: 커널 AppArmor 목록, parse_fail: 있으면 -Q 거부, load_fail: 있으면 -r 실패,
# load_mode: 적재 모드(기본 enforce), enabled: systemctl is-enabled 답.
STUB="$TMP/stub"
mkdir -p "$STUB"
cat >"$STUB/apparmor_parser" <<'EOF'
#!/usr/bin/env bash
echo "apparmor_parser $*" >>"$STUB_LOG"
case "$1" in
  -Q) [ ! -e "$STUB_STATE/parse_fail" ] || { echo "syntax error" >&2; exit 1; } ;;
  -r)
    [ ! -e "$STUB_STATE/load_fail" ] || exit 1
    name="$(awk '$1 == "profile" { print $2; exit }' "$2")"
    echo "${name} ($(cat "$STUB_STATE/load_mode" 2>/dev/null || echo enforce))" >>"$STUB_STATE/loaded"
    ;;
  *) exit 9 ;;
esac
EOF
cat >"$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-enabled) cat "$STUB_STATE/enabled"; [ "$(cat "$STUB_STATE/enabled")" = enabled ] ;;
  *) exit 9 ;;
esac
EOF
cat >"$STUB/sudo" <<'EOF'
#!/usr/bin/env bash
[ -e "$STUB_STATE/sudo_ok" ] || exit 1
[ "$1" = -n ] && shift
exec "$@"
EOF
cat >"$STUB/kubectl" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_STATE/runtime"
EOF
chmod +x "$STUB"/*

# new_case <이름>: 임시 호스트 경로와 상태를 만든다. 기본은 조건이 모두 맞는 호스트다.
new_case() {
  local d="$TMP/$1"
  mkdir -p "$d/state" "$d/kubelet" "$d/apparmor.d"
  : >"$d/log"
  printf 'bwrap (enforce)\nunpriv_bwrap (enforce)\ncri-containerd.apparmor.d (enforce)\n' >"$d/state/loaded"
  echo enabled >"$d/state/enabled"
  touch "$d/state/sudo_ok" "$d/apparmor.d/bwrap-userns-restrict"
  printf 'containerd://%s\n' "$pair_ctr" >"$d/state/runtime"
  printf '%s' "$d"
}

# run_install <케이스 디렉터리>: install.sh를 source해 sandbox_profiles만 부른다. 출력은 $D/out, 종료 코드는 $D/rc.
run_install() {
  local d="$1" rc=0
  (
    export PATH="$STUB:$PATH" STUB_STATE="$d/state" STUB_LOG="$d/log"
    # shellcheck source=../host/install.sh
    . "$ROOT/host/install.sh"
    load_cluster prod
    TMPD="$d/tmpd"
    KUBELET_DIR="$d/kubelet" SANDBOX_SECCOMP_DIR="$d/kubelet/seccomp/homelab"
    APPARMOR_DIR="$d/apparmor.d" APPARMOR_KERNEL_PROFILES="$d/state/loaded" SANDBOX_OWNER="$ME"
    sandbox_profiles
  ) >"$d/out" 2>&1 || rc=$?
  echo "$rc" >"$d/rc"
}

# run_verify <케이스 디렉터리>: verify.sh를 source해 check_sandbox_profiles와 finish를 부른다.
run_verify() {
  local d="$1" rc=0
  (
    export PATH="$STUB:$PATH" STUB_STATE="$d/state" STUB_LOG="$d/log"
    # shellcheck source=../host/verify.sh
    . "$ROOT/host/verify.sh"
    load_cluster prod
    # shellcheck disable=SC2034  # lib.sh의 sandbox_* 함수가 읽는다
    KUBELET_DIR="$d/kubelet" SANDBOX_SECCOMP_DIR="$d/kubelet/seccomp/homelab"
    # shellcheck disable=SC2034
    APPARMOR_DIR="$d/apparmor.d" APPARMOR_KERNEL_PROFILES="$d/state/loaded" SANDBOX_OWNER="$ME"
    check_sandbox_profiles
    finish
  ) >"$d/out" 2>&1 || rc=$?
  echo "$rc" >"$d/rc"
}

# expect <설명> <케이스 디렉터리> <조건...>: rc:<n>, out:<글자>, !out:<글자>, log:<글자>, !log:<글자>, nofile(프로필 파일 0개)
expect() {
  local desc="$1" d="$2" c bad="" got
  shift 2
  for c in "$@"; do
    case "$c" in
      rc:*) [ "$(cat "$d/rc")" = "${c#rc:}" ] || bad+=" 종료 $(cat "$d/rc")(기대 ${c#rc:})" ;;
      out:*) grep -qF -- "${c#out:}" "$d/out" || bad+=" 출력에 없음: ${c#out:}" ;;
      '!out:'*) if grep -qF -- "${c#!out:}" "$d/out"; then bad+=" 출력에 있음: ${c#!out:}"; fi ;;
      log:*) grep -qF -- "${c#log:}" "$d/log" || bad+=" 호출 없음: ${c#log:}" ;;
      '!log:'*) if grep -qF -- "${c#!log:}" "$d/log"; then bad+=" 호출 있음: ${c#!log:}"; fi ;;
      nofile)
        got="$(find "$d/kubelet" "$d/apparmor.d" -type f ! -name bwrap-userns-restrict | wc -l)"
        [ "$got" -eq 0 ] || bad+=" 파일이 ${got}개 생겼다"
        ;;
      *) bad+=" 모르는 조건: ${c}" ;;
    esac
  done
  if [ -z "$bad" ]; then
    pass "$desc"
  else
    fail "${desc}:${bad}"$'\n'"$(cat "$d/out")"
  fi
}

mode_of() { stat -c '%a' -- "$1"; }

# ------------------------------------------------------------------------------ 설치

D="$(new_case first)"
run_install "$D"
SECCOMP_DEST="$D/kubelet/seccomp/homelab/$SECCOMP_NAME"
APPARMOR_DEST="$D/apparmor.d/$APPARMOR_NAME"
expect "첫 설치: 문법 검사 뒤 깔린 파일을 -r로 적재" "$D" rc:0 \
  "log:apparmor_parser -Q -K -T $PROFILES/apparmor/$APPARMOR_NAME" "log:apparmor_parser -r $APPARMOR_DEST" "out:샌드박스 프로필 설치 완료"
if cmp -s "$PROFILES/seccomp/$SECCOMP_NAME" "$SECCOMP_DEST" && cmp -s "$PROFILES/apparmor/$APPARMOR_NAME" "$APPARMOR_DEST"; then
  pass "첫 설치: 두 파일이 Git과 같다"
else
  fail "첫 설치: 파일이 Git과 다르거나 없다"
fi
if [ "$(mode_of "$SECCOMP_DEST")" = 644 ] && [ "$(mode_of "$APPARMOR_DEST")" = 644 ] && [ "$(mode_of "$D/kubelet/seccomp/homelab")" = 755 ]; then
  pass "첫 설치: 파일 0644, seccomp 디렉터리 0755"
else
  fail "첫 설치 모드: $(stat -c '%n %a' "$SECCOMP_DEST" "$APPARMOR_DEST" "$D/kubelet/seccomp/homelab" 2>&1)"
fi
if grep -qxF "$APPARMOR_NAME (enforce)" "$D/state/loaded"; then pass "첫 설치: 커널 목록에 enforce"; else fail "첫 설치: 커널 목록에 없다"; fi

# 옛 버전이 깔려 있어도 건드리지 않는다. 재실행은 파일 시각까지 그대로다.
printf 'old\n' >"$D/kubelet/seccomp/homelab/sandbox-worker-v0.json"
printf 'old\n' >"$D/apparmor.d/homelab-sandbox-worker-v0"
touch -d '2026-01-02 03:04:05' "$SECCOMP_DEST" "$APPARMOR_DEST"
before="$(stat -c '%Y' "$SECCOMP_DEST" "$APPARMOR_DEST")"
: >"$D/log"
run_install "$D"
expect "재실행: 통과, 파일은 그대로 두고 적재만 다시" "$D" rc:0 "out:그대로 $SECCOMP_DEST" "out:그대로 $APPARMOR_DEST" "log:apparmor_parser -r $APPARMOR_DEST"
if [ "$(stat -c '%Y' "$SECCOMP_DEST" "$APPARMOR_DEST")" = "$before" ]; then
  pass "재실행: 파일 시각이 그대로다"
else
  fail "재실행: 파일을 다시 썼다"
fi
if [ -e "$D/kubelet/seccomp/homelab/sandbox-worker-v0.json" ] && [ -e "$D/apparmor.d/homelab-sandbox-worker-v0" ]; then
  pass "재실행: 옛 버전 파일을 지우지 않는다"
else
  fail "재실행: 옛 버전 파일이 사라졌다"
fi
FIRST="$D"

D="$(new_case kubelet-absent)"
rmdir "$D/kubelet"
run_install "$D"
if [ "$(cat "$D/rc")" = 0 ] && [ "$(mode_of "$D/kubelet")" = 750 ] && [ "$(mode_of "$D/kubelet/seccomp")" = 755 ]; then
  pass "k3s 전 설치: kubelet 디렉터리를 kubelet과 같은 0750으로 만든다"
else
  fail "k3s 전 설치: rc=$(cat "$D/rc") $(stat -c '%n %a' "$D/kubelet" "$D/kubelet/seccomp" 2>&1)"
fi

D="$(new_case kubelet-mode)"
chmod 0711 "$D/kubelet"
run_install "$D"
if [ "$(cat "$D/rc")" = 0 ] && [ "$(mode_of "$D/kubelet")" = 711 ]; then
  pass "이미 있는 kubelet 디렉터리의 모드를 바꾸지 않는다"
else
  fail "kubelet 디렉터리 모드가 바뀌었다: rc=$(cat "$D/rc") $(mode_of "$D/kubelet")"
fi

# 멈춰야 하는 경우. 모두 아무 파일도 깔지 않고 -r도 부르지 않는다.
D="$(new_case parse-fail)"
touch "$D/state/parse_fail"
run_install "$D"
expect "문법 거부: 멈추고 아무것도 깔지 않음" "$D" rc:1 "out:apparmor_parser가" "!log:apparmor_parser -r" nofile

D="$(new_case service-off)"
echo disabled >"$D/state/enabled"
run_install "$D"
expect "apparmor.service 꺼짐: 멈추고 아무것도 깔지 않음" "$D" rc:1 "out:apparmor.service가 enabled가 아니다" "!log:apparmor_parser -r" nofile

D="$(new_case no-bwrap-profile)"
sed -i '/^bwrap /d' "$D/state/loaded"
run_install "$D"
expect "Ubuntu bwrap 미적재: 멈추고 아무것도 깔지 않음" "$D" rc:1 "out:호스트 프로필 bwrap가" "!log:apparmor_parser -r" nofile

D="$(new_case no-bwrap-file)"
rm "$D/apparmor.d/bwrap-userns-restrict"
run_install "$D"
expect "Ubuntu bwrap 파일 없음: 멈추고 아무것도 깔지 않음" "$D" rc:1 "out:bwrap-userns-restrict가 없다" "!log:apparmor_parser -r" nofile

D="$(new_case apparmor-off)"
rm "$D/state/loaded"
run_install "$D"
expect "커널 목록 못 읽음: 멈추고 아무것도 깔지 않음" "$D" rc:1 "out:AppArmor가 꺼져 있는지" "!log:apparmor_parser -r" nofile

D="$(new_case disabled-link)"
mkdir -p "$D/apparmor.d/disable"
touch "$D/apparmor.d/disable/$APPARMOR_NAME"
run_install "$D"
expect "disable 표시: 멈추고 아무것도 깔지 않음" "$D" rc:1 "out:disable/$APPARMOR_NAME" "!log:apparmor_parser -r"
if [ ! -e "$D/apparmor.d/$APPARMOR_NAME" ]; then pass "disable 표시: 프로필 파일을 깔지 않음"; else fail "disable 표시: 프로필 파일이 깔렸다"; fi

D="$(new_case differs)"
printf 'other\n' >"$D/apparmor.d/$APPARMOR_NAME"
run_install "$D"
expect "같은 이름에 다른 내용: 덮지 않고 멈춤" "$D" rc:1 "out:Git과 다르다" "!log:apparmor_parser -r"
if [ "$(cat "$D/apparmor.d/$APPARMOR_NAME")" = other ] && [ ! -e "$D/kubelet/seccomp/homelab/$SECCOMP_NAME" ]; then
  pass "같은 이름에 다른 내용: 파일이 그대로이고 seccomp도 깔지 않음"
else
  fail "같은 이름에 다른 내용: 무언가 바뀌었다"
fi

# 적재 뒤 판정
D="$(new_case complain)"
echo complain >"$D/state/load_mode"
run_install "$D"
expect "complain으로 올라가면 실패" "$D" rc:1 "out:enforce로 올라와 있지 않다" "!out:설치 완료"

D="$(new_case load-fail)"
touch "$D/state/load_fail"
run_install "$D"
expect "-r 실패: 멈춤" "$D" rc:1 "out:apparmor_parser -r" "!out:설치 완료"

# ------------------------------------------------------------------------------ verify

D="$FIRST"
run_verify "$D"
expect "verify 통과: 판·호스트 조건·파일·enforce" "$D" rc:0 "out:샌드박스 프로필이 Git과 같다" "out:샌드박스 호스트 조건" "!out:FAIL"

copy_case() { cp -r "$FIRST" "$TMP/$1"; printf '%s' "$TMP/$1"; }

D="$(copy_case v-hash)"
printf 'x\n' >>"$D/apparmor.d/$APPARMOR_NAME"
run_verify "$D"
expect "verify: AppArmor 파일 해시가 다르면 실패" "$D" rc:1 "out:$D/apparmor.d/$APPARMOR_NAME: sha256"

D="$(copy_case v-seccomp)"
rm "$D/kubelet/seccomp/homelab/$SECCOMP_NAME"
run_verify "$D"
expect "verify: seccomp 파일이 없으면 실패" "$D" rc:1 "out:$SECCOMP_NAME: 없음"

D="$(copy_case v-mode)"
chmod 0600 "$D/kubelet/seccomp/homelab/$SECCOMP_NAME"
run_verify "$D"
expect "verify: 모드가 다르면 실패" "$D" rc:1 "out:600 regular file (기대 $ME 644 regular file)"

D="$(copy_case v-unloaded)"
sed -i "/^$APPARMOR_NAME /d" "$D/state/loaded"
run_verify "$D"
expect "verify: 커널에 없으면 실패(재부팅 뒤 파일만 남은 경우)" "$D" rc:1 "out:enforce로 올라와 있지 않다"

D="$(copy_case v-disabled)"
mkdir -p "$D/apparmor.d/disable"
touch "$D/apparmor.d/disable/$APPARMOR_NAME"
run_verify "$D"
expect "verify: disable 표시가 있으면 실패" "$D" rc:1 "out:재부팅하면 $APPARMOR_NAME"

D="$(copy_case v-runtime)"
echo 'containerd://2.9.9-k3s1.99' >"$D/state/runtime"
run_verify "$D"
expect "verify: containerd 판이 다르면 실패" "$D" rc:1 "out:라이브 containerd://2.9.9-k3s1.99" "out:regen.sh"

D="$(copy_case v-service)"
echo disabled >"$D/state/enabled"
run_verify "$D"
expect "verify: apparmor.service가 꺼져 있으면 실패" "$D" rc:1 "out:apparmor.service가 enabled가 아니다"

D="$(copy_case v-nosudo)"
rm "$D/state/sudo_ok"
if [ "$(id -u)" -eq 0 ]; then
  pass "verify: sudo 없음 경우는 root로 돌 때 해당 없음"
else
  run_verify "$D"
  expect "verify: sudo 자격이 없으면 미검증(통과 아님)" "$D" rc:2 "out:SKIP 샌드박스 프로필" "!out:샌드박스 프로필이 Git과 같다"
fi

# 0건 통과는 실패다(B.8 E7).
[ "$CASES" -gt 0 ] || { echo "FAIL 시험이 0건이다" >&2; exit 1; }
[ "$FAILS" -eq 0 ] || { echo "host-sandbox-profiles: ${FAILS}/${CASES} 실패" >&2; exit 1; }
echo "host-sandbox-profiles: ${CASES}건 통과"
