#!/usr/bin/env bash
# tailnet TLS 감시의 시험. ci가 부른다. root·tailscale 없이 돈다.
#   수집기(host/tls-monitor/collect.py): 임시 CA와 실제 TLS 서버로 정상·만료·이름 불일치·모르는 CA·연결 거부를 본다.
#     tailscale status는 가짜 JSON이다. 지표와 로그에 전체 이름·주소가 나오지 않는지도 본다.
#   install.sh --tls-monitor, verify.sh check_tls_monitor: 가짜 명령과 임시 경로로 본다.
# 운영 tailscaled와 systemd 하드닝 아래에서 도는지는 사람이 sudo로 설치할 때 본다(install.sh가 한 번 돌려 결과를 확인한다).
# 실행 틀은 시험마다 서브셸에서 값을 바꿔 서로 섞이지 않게 한다. 바깥으로 새지 않는 것이 의도다.
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECT="$ROOT/host/tls-monitor/collect.py"
FAILS=0
CASES=0
pass() { CASES=$((CASES + 1)); printf 'ok   %s\n' "$*"; }
fail() { CASES=$((CASES + 1)); FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$*" >&2; }

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
ME="$(id -u):$(id -g)"
ME_NAME="$(id -un)"

# ---------------------------------------------------------------------- 임시 CA와 인증서
PKI="$TMP/pki"
mkdir -p "$PKI/other"
ossl() { openssl "$@" >/dev/null 2>&1; }
ossl req -x509 -newkey rsa:2048 -nodes -keyout "$PKI/ca.key" -out "$PKI/ca.crt" -subj /CN=test-ca -days 3 \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign
ossl req -x509 -newkey rsa:2048 -nodes -keyout "$PKI/other/ca.key" -out "$PKI/other/ca.crt" -subj /CN=other-ca -days 3 \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign
: >"$PKI/index.txt"
echo 01 >"$PKI/serial"
cat >"$PKI/ca.cnf" <<EOF
[ca]
default_ca = d
[d]
dir = $PKI
database = $PKI/index.txt
new_certs_dir = $PKI
certificate = $PKI/ca.crt
private_key = $PKI/ca.key
serial = $PKI/serial
default_md = sha256
policy = p
unique_subject = no
[p]
commonName = supplied
EOF
# leaf <파일 이름> <인증서 이름> <시작> <끝> [서명 CA 디렉터리]. openssl ca라서 지난 날짜도 만든다.
leaf() {
  local name="$1" cn="$2" start="$3" end="$4"
  ossl req -new -newkey rsa:2048 -nodes -keyout "$PKI/$name.key" -out "$PKI/$name.csr" -subj "/CN=$cn"
  printf '[x]\nsubjectAltName = DNS:%s\n' "$cn" >"$PKI/$name.ext"
  ossl ca -batch -config "$PKI/ca.cnf" -extfile "$PKI/$name.ext" -extensions x -startdate "$start" -enddate "$end" \
    -in "$PKI/$name.csr" -out "$PKI/$name.crt" -notext
}
NOW_START="$(date -u -d '-1 hour' +%Y%m%d%H%M%SZ)"
GOOD_END="$(date -u -d '+30 days' +%Y%m%d%H%M%SZ)"
leaf good good.tail.test "$NOW_START" "$GOOD_END"
leaf second second.tail.test "$NOW_START" "$GOOD_END"
leaf expired expired.tail.test 20200101000000Z 20200102000000Z
leaf mismatch not-this-name.tail.test "$NOW_START" "$GOOD_END"
GOOD_NOT_AFTER="$(date -u -d "$(openssl x509 -in "$PKI/good.crt" -noout -enddate | cut -d= -f2)" +%s)"

# SNI로 인증서를 고르는 TLS 서버. 이름마다 다른 인증서를 낸다.
cat >"$TMP/server.py" <<'EOF'
import os, socket, ssl, sys, threading
pki, portfile = sys.argv[1], sys.argv[2]
def ctx(name):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.load_cert_chain(f"{pki}/{name}.crt", f"{pki}/{name}.key")
    return c
by_name = {"good.tail.test": ctx("good"), "second.tail.test": ctx("second"), "expired.tail.test": ctx("expired"),
           "mismatch.tail.test": ctx("mismatch")}
default = ctx("good")
def pick(sock, name, _):
    sock.context = by_name.get(name, default)
default.sni_callback = pick
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(16)
with open(portfile + ".tmp", "w") as f:
    f.write(str(s.getsockname()[1]))
os.rename(portfile + ".tmp", portfile)
def serve(conn):
    try:
        with default.wrap_socket(conn, server_side=True) as t:
            t.recv(1)
    except OSError:
        pass
while True:
    conn, _ = s.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
EOF
python3 "$TMP/server.py" "$PKI" "$TMP/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do
  [ -e "$TMP/port" ] && break
  sleep 0.1
done
PORT="$(cat "$TMP/port")"

# ------------------------------------------------------------------------------ 수집기
# status <파일> <이름:주소>...: tag:k8s 기기 목록 JSON을 쓴다.
status() {
  local f="$1" first=1 item name addr
  shift
  {
    printf '{"Peer":{"other":{"DNSName":"laptop.tail.test.","TailscaleIPs":["127.0.0.1"],"Tags":null}'
    for item in "$@"; do
      name="${item%%:*}" addr="${item#*:}"
      printf ',"%s":{"DNSName":"%s.tail.test.","TailscaleIPs":["%s"],"Tags":["tag:k8s"]}' "$name" "$name" "$addr"
      first=0
    done
    printf '}}\n'
  } >"$f"
  : "$first"
}

# collect <케이스>: 수집기를 돌린다. 지표 $D/out.prom, stderr $D/err, 종료 코드 $D/rc.
collect() {
  local d="$TMP/c-$1" rc=0
  mkdir -p "$d"
  shift
  python3 "$COLLECT" --out "$d/out.prom" --port "$PORT" --timeout 5 --cafile "$PKI/ca.crt" "$@" 2>"$d/err" || rc=$?
  echo "$rc" >"$d/rc"
  printf '%s' "$d"
}

# has <설명> <파일> <글자>: 정확히 그 줄이 있어야 한다. hasnot은 그 글자를 포함한 줄이 없어야 한다.
has() {
  if grep -qxF -- "$3" "$2"; then pass "$1"; else fail "$1: 줄 없음: $3 / $(cat "$2")"; fi
}
hasnot() {
  if grep -qF -- "$3" "$2"; then fail "$1: 있으면 안 됨: $3"; else pass "$1"; fi
}

status "$TMP/ok.json" good:127.0.0.1 second:127.0.0.1
D="$(collect ok --status-cmd "cat $TMP/ok.json")"
has "정상: 검증 통과" "$D/out.prom" 'homelab_tailnet_tls_probe_success{tls_host="good"} 1'
has "정상: 만료 시각이 인증서 값이다" "$D/out.prom" "homelab_tailnet_tls_not_after_seconds{tls_host=\"good\"} $GOOD_NOT_AFTER"
has "정상: 두 번째 대상도 본다" "$D/out.prom" 'homelab_tailnet_tls_probe_success{tls_host="second"} 1'
has "정상: 목록 성공" "$D/out.prom" 'homelab_tailnet_tls_collect_success 1'
hasnot "tag:k8s가 아닌 기기는 보지 않는다" "$D/out.prom" 'laptop'
ts="$(awk '$1 == "homelab_tailnet_tls_collect_timestamp_seconds" { print $2 }' "$D/out.prom")"
if [ -n "$ts" ] && [ $(($(date +%s) - ts)) -le 60 ]; then pass "실행 시각을 쓴다"; else fail "실행 시각: ${ts:-없음}"; fi
if [ "$(stat -c %a "$D/out.prom")" = 644 ]; then pass "파일 0644(node-exporter가 다른 uid로 읽는다)"; else fail "파일 모드 $(stat -c %a "$D/out.prom")"; fi
if [ "$(find "$D" -name '.tailnet_tls.*' | wc -l)" = 0 ]; then pass "임시 파일을 남기지 않는다"; else fail "임시 파일이 남았다"; fi
bad_lines="$(grep -vE '^(# (HELP|TYPE) homelab_tailnet_tls_[a-z_]+ .+|homelab_tailnet_tls_[a-z_]+(\{tls_host="[a-z0-9-]+"\})? [0-9]+)$' "$D/out.prom" || true)"
if [ -z "$bad_lines" ]; then pass "textfile 형식이다"; else fail "형식에 맞지 않는 줄: $bad_lines"; fi

status "$TMP/bad.json" expired:127.0.0.1 mismatch:127.0.0.1 refused:127.0.0.2
D="$(collect bad --status-cmd "cat $TMP/bad.json")"
has "만료: 실패로 기록" "$D/out.prom" 'homelab_tailnet_tls_probe_success{tls_host="expired"} 0'
has "이름 불일치: 실패로 기록" "$D/out.prom" 'homelab_tailnet_tls_probe_success{tls_host="mismatch"} 0'
has "연결 거부: 실패로 기록" "$D/out.prom" 'homelab_tailnet_tls_probe_success{tls_host="refused"} 0'
hasnot "실패한 대상은 만료 시각을 쓰지 않는다" "$D/out.prom" 'homelab_tailnet_tls_not_after_seconds'
has "실패해도 목록은 성공" "$D/out.prom" 'homelab_tailnet_tls_collect_success 1'
if [ "$(cat "$D/rc")" = 0 ]; then pass "대상 실패로 유닛을 실패시키지 않는다"; else fail "종료 코드 $(cat "$D/rc")"; fi
for f in out.prom err; do
  hasnot "${f}에 전체 이름이 없다" "$D/$f" 'tail.test'
  hasnot "${f}에 주소가 없다" "$D/$f" '127.0.0'
done

rc=0
python3 "$COLLECT" --out "$TMP/c-ok/ca.prom" --port "$PORT" --timeout 5 --cafile "$PKI/other/ca.crt" --status-cmd "cat $TMP/ok.json" 2>/dev/null || rc=$?
has "모르는 CA: 실패로 기록" "$TMP/c-ok/ca.prom" 'homelab_tailnet_tls_probe_success{tls_host="good"} 0'

status "$TMP/none.json"
D="$(collect none --status-cmd "cat $TMP/none.json")"
has "대상 0개: 목록 성공" "$D/out.prom" 'homelab_tailnet_tls_collect_success 1'
hasnot "대상 0개: 대상 줄 없음" "$D/out.prom" 'tls_host='

printf 'not json' >"$TMP/garbage.json"
printf '[]' >"$TMP/list.json"
printf '{"Peer":{"x":{"DNSName":"","TailscaleIPs":["127.0.0.1"],"Tags":["tag:k8s"]}}}' >"$TMP/noname.json"
printf '{"Peer":{"x":{"DNSName":"Bad_Name.tail.test.","TailscaleIPs":["127.0.0.1"],"Tags":["tag:k8s"]}}}' >"$TMP/badlabel.json"
printf '{"Peer":{"x":{"DNSName":"good.tail.test.","TailscaleIPs":[],"Tags":["tag:k8s"]}}}' >"$TMP/noaddr.json"
for c in "실패 명령:false" "없는 명령:/no/such/tailscale" "JSON 아님:cat $TMP/garbage.json" "객체 아님:cat $TMP/list.json" \
  "이름 없음:cat $TMP/noname.json" "라벨로 못 쓰는 이름:cat $TMP/badlabel.json" "주소 없음:cat $TMP/noaddr.json"; do
  desc="${c%%:*}" cmd="${c#*:}"
  D="$(collect "fail-$CASES" --status-cmd "$cmd")"
  has "${desc}: 목록 실패로 기록" "$D/out.prom" 'homelab_tailnet_tls_collect_success 0'
  hasnot "${desc}: 대상 줄 없음" "$D/out.prom" 'tls_host='
  if [ "$(cat "$D/rc")" = 0 ]; then pass "${desc}: 유닛은 성공"; else fail "${desc}: 종료 코드 $(cat "$D/rc")"; fi
done

rc=0
python3 "$COLLECT" --out "$TMP/no/such/dir/out.prom" --port "$PORT" --cafile "$PKI/ca.crt" --status-cmd "cat $TMP/none.json" 2>/dev/null || rc=$?
if [ "$rc" != 0 ]; then pass "파일을 못 쓰면 실패로 끝난다(NodeSystemdUnitFailed가 본다)"; else fail "파일을 못 썼는데 성공했다"; fi

# --------------------------------------------------------------------------- 가짜 명령
# 상태는 STUB_STATE 아래 파일이다. enabled·active: systemctl 답, start_fail: 있으면 start 실패, prom: start가 결과 파일로 복사할 내용.
STUB="$TMP/stub"
mkdir -p "$STUB"
cat >"$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
case "$1" in
  is-enabled) cat "$STUB_STATE/enabled"; [ "$(cat "$STUB_STATE/enabled")" = enabled ] ;;
  is-active) cat "$STUB_STATE/active"; [ "$(cat "$STUB_STATE/active")" = active ] ;;
  daemon-reload | enable) ;;
  start)
    [ ! -e "$STUB_STATE/start_fail" ] || exit 1
    [ ! -e "$STUB_STATE/prom" ] || cp "$STUB_STATE/prom" "$STUB_PROM"
    ;;
  *) exit 9 ;;
esac
EOF
cat >"$STUB/useradd" <<'EOF'
#!/usr/bin/env bash
echo "useradd $*" >>"$STUB_LOG"
EOF
cat >"$STUB/tailscale" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB"/*

good_prom() {
  printf 'homelab_tailnet_tls_probe_success{tls_host="grafana"} 1\nhomelab_tailnet_tls_collect_success 1\nhomelab_tailnet_tls_collect_timestamp_seconds %s\n' "$(date +%s)"
}

new_case() {
  local d="$TMP/$1"
  mkdir -p "$d/state" "$d/units" "$d/data"
  : >"$d/log"
  echo enabled >"$d/state/enabled"
  echo active >"$d/state/active"
  good_prom >"$d/state/prom"
  printf '%s' "$d"
}

# 부르는 쪽이 정한 클러스터로 경로를 임시로 바꾼다.
set_paths() {
  local d="$1"
  TLS_MONITOR_USER="$ME_NAME"
  TLS_MONITOR_DIR="$d/data/out"
  TLS_MONITOR_DIR_OWNER="$ME"
  TLS_MONITOR_PROM="$d/data/out/tailnet_tls.prom"
  TLS_MONITOR_LIB="$d/lib"
  TLS_MONITOR_UNIT_DIR="$d/units"
  TLS_MONITOR_FILE_OWNER="$ME"
  TLS_MONITOR_PYTHON="$(command -v python3)"
  TMPD="$d/tmpd"
  mkdir -p "$TMPD"
}

run_install() {
  local d="$1" cluster="${2:-prod}" rc=0
  (
    export PATH="$STUB:$PATH" STUB_STATE="$d/state" STUB_LOG="$d/log" STUB_PROM="$d/data/out/tailnet_tls.prom"
    # shellcheck source=../host/install.sh
    . "$ROOT/host/install.sh"
    load_cluster "$cluster"
    set_paths "$d"
    [ -z "${NEW_USER:-}" ] || TLS_MONITOR_USER="$NEW_USER"
    [ -z "${NO_PYTHON:-}" ] || TLS_MONITOR_PYTHON="$d/no-python"
    tls_monitor
  ) >"$d/out" 2>&1 || rc=$?
  echo "$rc" >"$d/rc"
}

run_verify() {
  local d="$1" cluster="${2:-prod}" rc=0
  (
    export PATH="$STUB:$PATH" STUB_STATE="$d/state" STUB_LOG="$d/log"
    # shellcheck source=../host/verify.sh
    . "$ROOT/host/verify.sh"
    load_cluster "$cluster"
    set_paths "$d"
    check_tls_monitor
    finish
  ) >"$d/out" 2>&1 || rc=$?
  echo "$rc" >"$d/rc"
}

expect() {
  local desc="$1" d="$2" c bad=""
  shift 2
  for c in "$@"; do
    case "$c" in
      rc:*) [ "$(cat "$d/rc")" = "${c#rc:}" ] || bad+=" 종료 $(cat "$d/rc")(기대 ${c#rc:})" ;;
      out:*) grep -qF -- "${c#out:}" "$d/out" || bad+=" 출력에 없음: ${c#out:}" ;;
      '!out:'*) if grep -qF -- "${c#!out:}" "$d/out"; then bad+=" 출력에 있음: ${c#!out:}"; fi ;;
      log:*) grep -qF -- "${c#log:}" "$d/log" || bad+=" 호출 없음: ${c#log:}" ;;
      '!log:'*) if grep -qF -- "${c#!log:}" "$d/log"; then bad+=" 호출 있음: ${c#!log:}"; fi ;;
      *) bad+=" 모르는 조건: ${c}" ;;
    esac
  done
  if [ -z "$bad" ]; then pass "$desc"; else fail "${desc}:${bad} / $(cat "$d/out")"; fi
}

# ------------------------------------------------------------------------------ install
D="$(new_case first)"
run_install "$D"
expect "설치: 통과, 타이머를 켜고 한 번 돌린다" "$D" rc:0 "log:systemctl daemon-reload" "log:systemctl enable --now homelab-tls-monitor.timer" \
  "log:systemctl start homelab-tls-monitor.service" "out:설치 완료" "!log:useradd"
if cmp -s "$ROOT/host/tls-monitor/collect.py" "$D/lib/collect.py" \
  && cmp -s "$ROOT/host/tls-monitor/homelab-tls-monitor.service" "$D/units/homelab-tls-monitor.service" \
  && cmp -s "$ROOT/host/tls-monitor/homelab-tls-monitor.timer" "$D/units/homelab-tls-monitor.timer"; then
  pass "설치: 파일이 Git과 같다"
else
  fail "설치: 파일이 Git과 다르다"
fi
if [ "$(stat -c %a "$D/lib/collect.py")" = 755 ] && [ "$(stat -c %a "$D/units/homelab-tls-monitor.service")" = 644 ] && [ "$(stat -c %a "$D/data/out")" = 755 ]; then
  pass "설치: 모드(수집기 0755, 유닛 0644, 출력 디렉터리 0755)"
else
  fail "설치 모드: $(stat -c '%n %a' "$D/lib/collect.py" "$D/units/homelab-tls-monitor.service" "$D/data/out")"
fi
run_verify "$D"
expect "verify: 설치 뒤 통과" "$D" rc:0 "out:homelab-tls-monitor.timer enabled, active" "out:수집 결과가 최근 것이고 실패가 없다" "!out:FAIL"
: >"$D/log"
run_install "$D"
expect "설치: 다시 돌려도 통과" "$D" rc:0 "out:설치 완료"

D="$(new_case newuser)"
NEW_USER=homelab-no-such-user-for-test run_install "$D"
expect "설치: 사용자가 없으면 시스템 사용자로 만든다" "$D" rc:0 \
  "log:useradd --system --user-group --no-create-home --home-dir / --shell /usr/sbin/nologin homelab-no-such-user-for-test"

D="$(new_case vm)"
run_install "$D" vm
expect "설치(VM): 끔 표시만 쓰고 타이머를 켜지 않는다" "$D" rc:0 "out:TAILNET_JOIN=false" "!log:systemctl" "!log:useradd"
has "설치(VM): 끔 표시" "$D/data/out/tailnet_tls.prom" 'homelab_tailnet_tls_disabled 1'
if [ ! -e "$D/lib" ] && [ "$(stat -c %a "$D/data/out/tailnet_tls.prom")" = 644 ]; then pass "설치(VM): 수집기가 없고 표시는 0644다"; else fail "설치(VM): 파일 상태가 다르다"; fi
run_verify "$D" vm
expect "verify(VM): 통과" "$D" rc:0 "out:호스트가 tailnet에 들지 않아 타이머 없음" "!log:is-enabled"

D="$(new_case vm-none)"
run_verify "$D" vm
expect "verify(VM): 끔 표시가 없으면 실패" "$D" rc:1 "out:끔 표시가 없다" "out:--tls-monitor"

D="$(new_case nopython)"
NO_PYTHON=1 run_install "$D"
expect "설치: 파이썬이 없으면 아무것도 깔지 않고 멈춘다" "$D" rc:1 "out:no-python" "!log:systemctl"
if [ ! -e "$D/lib" ]; then pass "설치: 파이썬이 없으면 파일이 없다"; else fail "설치: 파이썬이 없는데 파일이 깔렸다"; fi

D="$(new_case startfail)"
touch "$D/state/start_fail"
run_install "$D"
expect "설치: 수집기가 실패하면 멈춘다" "$D" rc:1 "out:homelab-tls-monitor.service가 실패했다"

D="$(new_case badresult)"
printf 'homelab_tailnet_tls_collect_success 0\nhomelab_tailnet_tls_collect_timestamp_seconds %s\n' "$(date +%s)" >"$D/state/prom"
run_install "$D"
expect "설치: 목록을 못 읽은 결과면 멈춘다" "$D" rc:1 "out:대상 목록을 못 읽었다"

# ------------------------------------------------------------------------------- verify
installed() {
  local d
  d="$(new_case "$1")"
  run_install "$d"
  printf '%s' "$d"
}

D="$(installed v-timer)"
echo disabled >"$D/state/enabled"
run_verify "$D"
expect "verify: 타이머가 꺼져 있으면 실패" "$D" rc:1 "out:enabled·active가 아니다(disabled"

D="$(installed v-inactive)"
echo inactive >"$D/state/active"
run_verify "$D"
expect "verify: 타이머가 멈춰 있으면 실패" "$D" rc:1 "out:enabled·active가 아니다(enabled, inactive)"

D="$(installed v-drift)"
printf '# 손으로 고침\n' >>"$D/lib/collect.py"
run_verify "$D"
expect "verify: 수집기가 Git과 다르면 실패" "$D" rc:1 "out:collect.py가 없거나"

D="$(installed v-unit)"
rm "$D/units/homelab-tls-monitor.timer"
run_verify "$D"
expect "verify: 타이머 파일이 없으면 실패" "$D" rc:1 "out:homelab-tls-monitor.timer가 없거나"

D="$(installed v-stale)"
printf 'homelab_tailnet_tls_collect_success 1\nhomelab_tailnet_tls_collect_timestamp_seconds %s\n' "$(($(date +%s) - 3600))" >"$D/data/out/tailnet_tls.prom"
run_verify "$D"
expect "verify: 결과가 오래되면 실패" "$D" rc:1 "out:오래됐다"

D="$(installed v-noprom)"
rm "$D/data/out/tailnet_tls.prom"
run_verify "$D"
expect "verify: 결과 파일이 없으면 실패" "$D" rc:1 "out:tailnet_tls.prom가 없다"

D="$(installed v-probe)"
{
  printf 'homelab_tailnet_tls_probe_success{tls_host="grafana"} 0\nhomelab_tailnet_tls_probe_success{tls_host="argocd"} 0\n'
  printf 'homelab_tailnet_tls_collect_success 1\nhomelab_tailnet_tls_collect_timestamp_seconds %s\n' "$(date +%s)"
} >"$D/data/out/tailnet_tls.prom"
run_verify "$D"
expect "verify: 검증 실패 대상을 이름으로 알린다" "$D" rc:1 "out:인증서 검증 실패: grafana argocd"

# ------------------------------------------------------------------------- 유닛과 값의 짝
# 유닛에는 경로가 글자로 있다. lib.sh 값과 어긋나면 설치는 되는데 수집기가 못 돈다.
unit_mismatch="$(
  . "$ROOT/host/lib.sh"
  unit="$ROOT/host/tls-monitor/${TLS_MONITOR_SERVICE}"
  grep -qxF "User=${TLS_MONITOR_USER}" "$unit" || echo User
  grep -qxF "Group=${TLS_MONITOR_USER}" "$unit" || echo Group
  grep -qxF "ReadWritePaths=${TLS_MONITOR_DIR}" "$unit" || echo ReadWritePaths
  grep -qxF "ExecStart=${TLS_MONITOR_PYTHON} ${TLS_MONITOR_LIB}/collect.py --out ${TLS_MONITOR_PROM}" "$unit" || echo ExecStart
)"
if [ -z "$unit_mismatch" ]; then
  pass "유닛의 사용자·경로가 lib.sh 값과 같다"
else
  fail "유닛이 lib.sh 값과 다르다: $unit_mismatch"
fi

printf 'host-tls-monitor: '
if [ "$FAILS" -eq 0 ]; then
  echo "${CASES}건 통과"
else
  echo "${FAILS}/${CASES}건 실패" >&2
  exit 1
fi
