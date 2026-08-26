#!/usr/bin/env bats
# 호스트 포트 위생 가드(scripts/check-host-ports.sh)의 **변별력** 테스트 + 배정 프리미티브
# (tests/gates/lib/host-port.sh)의 계약 증인.
#
# 왜 이 게이트가 필요한가: 검출기가 조용히 죽어도(정규식 드리프트·글롭 붕괴) "리터럴 호스트 포트 0곳
# OK"는 그대로 나온다. 그리고 이 클래스의 결함은 red가 아니라 **오진**으로 나타나므로(30초를 태운 뒤
# 엉뚱한 부분을 가리키는 메시지) 사람이 사후에 알아채지 못한다 — 픽스처 양성·음성 대조를 매 실행 건다.
#
# 픽스처는 전부 hermetic이다. 실 소켓은 프로브 증인 두 레인에서만 쓴다.
# ⚠️ @test 이름은 영어만 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  S="$ROOT/scripts/check-host-ports.sh"
  LIB="$ROOT/tests/gates/lib/host-port.sh"
  FX="$BATS_TEST_TMPDIR"
}

# ── 가드의 변별력 ────────────────────────────────────────────────────────────────

@test "lane A fires on a literal host port in a publish argument and stays quiet on an assigned one" {
  # 실제로 있던 형태 그대로 — 예전 alertmanager-render-e2e.sh:40이 이것이었다.
  printf '#!/usr/bin/env bash\ndocker run -d -p 9093:9093 img\n'                  > "$FX/dirty.sh"
  printf '#!/usr/bin/env bash\ndocker run -d -p 127.0.0.1:9093:9093 img\n'        > "$FX/dirty2.sh"
  printf '#!/usr/bin/env bash\n. lib/host-port.sh\ndocker run -d -p "127.0.0.1:${P}:9093" img\n' > "$FX/clean.sh"
  run bash "$S" "$FX/dirty.sh";  [ "$status" -ne 0 ]; echo "$output" | grep -qF '[A]'
  run bash "$S" "$FX/dirty2.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[A]'
  run bash "$S" "$FX/clean.sh";  [ "$status" -eq 0 ]
}

@test "lane A does not read a non-publish -p flag as a port map (false-positive control)" {
  # ★ `mkdir -p "$tmp/bin"`을 publish로 읽어 그 파일을 [C]로 오탐했다(도입 때 실측).
  #   판별자는 "콜론이 있는가"다 — 이 대조가 없으면 가드가 무관한 파일을 물어 아무도 안 켠다.
  printf '#!/usr/bin/env bash\nmkdir -p "$tmp/bin"\ninstall -p a b\n' > "$FX/mkdir.sh"
  run bash "$S" "$FX/mkdir.sh"; [ "$status" -eq 0 ]
}

@test "lane B fires on a listener helper started with a literal port" {
  # 예전 alertmanager-render-e2e.sh:35이 이것이었다 — background job이라 set -e가 rc를 안 본다.
  printf '#!/usr/bin/env bash\npython3 tests/gates/mock-telegram.py "$T/c.txt" 8089 &\n' > "$FX/dirty.sh"
  printf '#!/usr/bin/env bash\n. lib/host-port.sh\npython3 tests/gates/mock-telegram.py "$T/c.txt" "$MP" &\n' > "$FX/clean.sh"
  run bash "$S" "$FX/dirty.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[B]'
  run bash "$S" "$FX/clean.sh"; [ "$status" -eq 0 ]
}

@test "lane C fires when a port-binding file never reaches the allocation lib" {
  printf '#!/usr/bin/env bash\nSINK=tests/gates/tcp-blackhole-sink.py\npython3 "$SINK" "$P" &\n' > "$FX/dirty.sh"
  run bash "$S" "$FX/dirty.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[C]'
  printf '#!/usr/bin/env bash\n. tests/gates/lib/host-port.sh\nSINK=tests/gates/tcp-blackhole-sink.py\npython3 "$SINK" "$P" &\n' > "$FX/clean.sh"
  run bash "$S" "$FX/clean.sh"; [ "$status" -eq 0 ]
}

@test "lane D fires on a port variable the file fills with a literal itself" {
  # ★ A·B·C가 모두 침묵하는 자리다 — 예전 skopeo-timeout-smoke.sh:64가 `PORT=18443` 뒤에
  #   `"$PORT"`로 썼다. 이 레인이 없으면 lib을 source하기만 하면 고정 포트가 통과한다.
  printf '#!/usr/bin/env bash\n. tests/gates/lib/host-port.sh\nPORT=18443\npython3 s.py "$PORT"\n' > "$FX/dirty.sh"
  run bash "$S" "$FX/dirty.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[D]'
  printf '#!/usr/bin/env bash\n. tests/gates/lib/host-port.sh\nPORT="$(hp_pick_port)"\n' > "$FX/clean.sh"
  run bash "$S" "$FX/clean.sh"; [ "$status" -eq 0 ]
}

@test "lane D exempts the HP_ namespace by name, not by file path" {
  # 밴드 상수의 **정의처**는 리터럴이 정상이다. 면제가 파일 목록이면 lib을 옮기는 순간 갈린다 —
  # 이름공간 규칙이라 어느 파일에 있어도 같은 판정이 나오는지 여기서 문다.
  printf '#!/usr/bin/env bash\nHP_PORT_LO=20000\nHP_NODEPORT_HI=32767\n' > "$FX/ns-ok.sh"
  run bash "$S" "$FX/ns-ok.sh"; [ "$status" -eq 0 ]
  printf '#!/usr/bin/env bash\nMY_PORT=8089\n' > "$FX/ns-bad.sh"
  run bash "$S" "$FX/ns-bad.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[D]'
}

@test "comment lines quoting the forbidden forms are not flagged (self-hit control)" {
  # ★ 이 레포의 하네스는 자기가 고친 함정을 **인용하며 설명**한다. 줄 머리 앵커가 없으면 검출기가
  #   자기 문서를 위반으로 잡고, 그러면 사람이 주석을 지워 근거가 사라진다(형제 게이트가 밟은 자리).
  printf '#!/usr/bin/env bash\n# 예전엔 -p 9093:9093 이었고 PORT=18443 도 있었다\n' > "$FX/cmt.sh"
  run bash "$S" "$FX/cmt.sh"; [ "$status" -eq 0 ]
}

@test "lane A reads publish arguments that are wrapped in quotes (the notation this repo actually uses)" {
  # ★ 적대적 리뷰가 잡은 자리. 한 번의 `gsub(/^["']|["'].*$/, ...)`는 ERE의 leftmost-longest로
  #   따옴표 토큰 **전체**를 먹어 cand를 비우고, 그러면 A가 침묵하며 binds가 안 서서 C까지 꺼졌다.
  #   하필 이 레포의 실제 표기가 따옴표형이라, 그 상태의 hard-zero 보증은 **거짓**이었다.
  #   네 표기를 전부 건다 — 하나만 걸면 다음 표기로 조용히 빠져나간다.
  printf '#!/usr/bin/env bash\ndocker run -d -p "9093:9093" img\n'             > "$FX/q1.sh"
  printf "#!/usr/bin/env bash\ndocker run -d -p '18443:18443' img\n"           > "$FX/q2.sh"
  printf '#!/usr/bin/env bash\ndocker run -d -p "127.0.0.1:9093:9093" img\n'   > "$FX/q3.sh"
  printf '#!/usr/bin/env bash\ndocker run -d --publish="9093:9093" img\n'      > "$FX/q4.sh"
  run bash "$S" "$FX/q1.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[A]'
  run bash "$S" "$FX/q2.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[A]'
  run bash "$S" "$FX/q3.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[A]'
  run bash "$S" "$FX/q4.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[A]'
  # 음성 대조 — 같은 따옴표 표기에 **변수**가 들어가면 조용해야 한다.
  printf '#!/usr/bin/env bash\n. tests/gates/lib/host-port.sh\ndocker run -d -p "127.0.0.1:${P}:9093" img\n' > "$FX/qok.sh"
  run bash "$S" "$FX/qok.sh"; [ "$status" -eq 0 ]
}

@test "a heredoc token quoted inside a comment does not blind the detector to the rest of the file" {
  # ★ heredoc 상태 기계가 주석 규칙보다 먼저 돌아, `# … <<PY …` 한 줄이 inhere=1을 세우면
  #   그 뒤 파일 전체가 검출기에게 투명해졌다. 진짜 종료줄이 있는 파일은 [E]도 침묵해서
  #   어떤 신호도 안 났다(SCAN·READFILES는 **파일 수** 축이라 줄 단위 붕괴를 원리적으로 못 본다).
  #   `<<<`·`$(( << ))`에 이은 같은 클래스의 세 번째 오인원이다.
  printf '#!/usr/bin/env bash\n# 예전엔 `python3 - <<PY` 로 인라인했다\ndocker run -d -p 9093:9093 img\nPY\n' > "$FX/hd.sh"
  run bash "$S" "$FX/hd.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[A]'
  # 음성 대조 — **진짜** heredoc 본문은 명령이 아니므로 여전히 면제다.
  printf '#!/usr/bin/env bash\ncat <<PY\n-p 9093:9093\nPY\necho done\n' > "$FX/hdreal.sh"
  run bash "$S" "$FX/hdreal.sh"; [ "$status" -eq 0 ]
}

@test "the real harnesses that bind host ports are all wired to the lib (tracked enumeration, no hardcoded roster)" {
  # ★ 완전성 레인. 예전 가드는 `vmalert-*-firing-e2e.sh` 글롭만 열거해 형제 표면 셋이 **원리적으로**
  #   안 보였다(열거 붕괴가 아니라 열거 범위가 좁았다). 여기서는 추적 글롭 전체를 돌린다.
  run bash "$S"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-host-ports: [0-9]+$'
  # 바닥값이 실제로 물리는지 — 도메인이 붕괴하면 초록이 아니라 red여야 한다.
  run bash "$S" --floor check-host-ports=99999
  [ "$status" -ne 0 ]
  # 파일 오인("읽을 수 없는 대상")이 아니라 진짜 floor에 닿아야 한다 — 문구가 그 구별이다.
  echo "$output" | grep -q "열거 붕괴"
}

@test "the explicit-file mode emits its own SCAN signal (floor is exempt, the signal is not)" {
  printf '#!/usr/bin/env bash\n' > "$FX/empty.sh"
  run bash "$S" "$FX/empty.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-host-ports: [0-9]+$'
}

# ── 리스너 헬퍼의 readiness 계약 ──────────────────────────────────────────────────

@test "the telegram mock prints a readiness token on success and never prints it when the bind fails" {
  # ★ 이 토큰이 계약이다 — 호출자가 `&`로 띄우므로 rc를 볼 수 없고, 이 줄의 유무만이 판별자다.
  #   양성(바인드 성공 → 토큰) · 음성(바인드 실패 → 비-0이고 토큰 없음) 양쪽을 건다.
  run env MOCK="$ROOT/tests/gates/mock-telegram.py" OUT="$FX/cap.txt" python3 - <<'PYWITNESS'
import os, socket, subprocess, sys

hold = socket.socket()
hold.bind(("0.0.0.0", 0))
port = hold.getsockname()[1]
hold.listen(1)

# 음성: 점유된 포트 → 비-0 + readiness 토큰 없음
r = subprocess.run([sys.executable, os.environ["MOCK"], os.environ["OUT"], str(port)],
                   capture_output=True, text=True, timeout=30)
hold.close()
if r.returncode == 0:
    print("MOCK-FAILED: 점유된 포트에서 0으로 끝났다"); sys.exit(1)
if "listening" in (r.stderr or ""):
    print("MOCK-FAILED: 바인드에 실패했는데 readiness 토큰을 냈다(호출자가 준비됐다고 읽는다)"); sys.exit(1)

# 양성: 빈 포트 → 토큰이 나온다(그 뒤 serve_forever라 토큰을 보면 즉시 죽인다)
free = socket.socket(); free.bind(("0.0.0.0", 0)); free_port = free.getsockname()[1]; free.close()
p = subprocess.Popen([sys.executable, os.environ["MOCK"], os.environ["OUT"], str(free_port)],
                     stderr=subprocess.PIPE, text=True)
line = p.stderr.readline()
p.kill(); p.wait(timeout=10)
if "listening" not in line:
    print(f"MOCK-FAILED: 빈 포트인데 readiness 토큰이 없다(첫 줄='{line.strip()}')"); sys.exit(1)
print("MOCK-OK")
PYWITNESS
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'MOCK-OK'
}

@test "the AM harness waits for that token and escapes on helper death instead of burning the timeout" {
  # ★ 정적 대조(변경 감지기임을 자인한다) — readiness 대기와 **프로세스 사망 탈출**이 둘 다 있어야
  #   한다. 대기만 있고 `kill -0` 탈출이 없으면 이미 죽은 헬퍼를 상대로 타임아웃을 꽉 채워, 오진
  #   시간이 줄어들 뿐 없어지지 않는다.
  # ⚠️ **주석을 세면 안 된다.** 이 레포의 하네스는 자기가 고친 함정을 인용하며 설명하므로, 코드를
  #   지우고 주석으로 옮기는 리팩터가 자연스럽다 — 그러면 오진이 돌아오는데 게이트는 초록이다.
  #   (형제 레인은 주석을 걷는데 이 레인만 안 걷던 비대칭이 곧 갭이었다.)
  H="$ROOT/tests/gates/alertmanager-render-e2e.sh"
  CODE="$BATS_TEST_TMPDIR/am-code.sh"
  grep -vE '^[[:space:]]*#' "$H" > "$CODE"
  run grep -c "grep -q 'listening'" "$CODE"
  [ "$output" -ge 1 ]
  run grep -c 'kill -0 "$MOCK_PID"' "$CODE"
  [ "$output" -ge 1 ]
  # 실패 경로가 헬퍼의 stderr를 실제로 보여 주는가(삼키면 진단이 사라진다).
  run grep -c 'cat "$TMP/mock.log"' "$CODE"
  [ "$output" -ge 1 ]
}

@test "every harness derives its container image from the deployed manifest (no literal tags)" {
  # ★ 예전엔 alertmanager-render-e2e만 `prom/alertmanager:v0.33.0`을 리터럴로 박았다. 매니페스트와
  #   형제 bats를 **함께** 올리고 이 하네스를 놔두면 전 게이트가 초록인 채로, "템플릿이 실제로
  #   렌더된다"는 유일한 증거가 **배포되지 않는 버전에 대해** 성립한다.
  #   추적 열거 — 하드코딩 로스터를 두면 새 하네스가 이 레인 밖에서 태어난다.
  hs="$(git ls-files 'tests/gates/*.sh' 'tests/gates/lib/*.sh' | xargs grep -l 'docker run' || true)"
  n="$(printf '%s\n' "$hs" | grep -c . || true)"
  # ⚠️ xargs는 빈 입력에서 grep을 아예 안 부르고 0을 낸다 → hs가 비면 아래 for가 vacuous하다. 바닥값이 막는다.
  [ "$n" -ge 3 ]
  for f in $hs; do
    CODE="$BATS_TEST_TMPDIR/harness-code.sh"
    # 줄 머리 주석은 걷어낸다 — 하네스가 자기 함정을 인용하며 설명한다.
    grep -vE '^[[:space:]]*#' "$f" > "$CODE"
    # ① 파생이 **존재하는가**.
    run grep -cE '(image|IMAGE|VER)=.*[$][(]' "$CODE"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    # ② ★ 그리고 **리터럴 이미지 참조가 0인가.** 파생 줄이 있어도 `docker run` 호출부에 리터럴을 박으면
    #    ①만으로는 초록이다 — 그 회귀가 정확히 이 PR이 고친 것이다. 하드제로로 그 자리를 막는다.
    #    패턴은 실제 태그(`name:v1.2.3`)만 문다. grep 패턴 안의 `[0-9.]`는 숫자가 아니라 안 걸린다.
    run bash -c "grep -coE '[a-z0-9][a-z0-9._/-]*/[a-z0-9._-]+:v?[0-9]+[.][0-9]+' '$CODE' || true"
    [ "$output" -eq 0 ]
  done
}

# ── 배정 프리미티브의 계약 ────────────────────────────────────────────────────────

@test "the band is disjoint from this host's live kernel ephemeral range and from k8s NodePort" {
  # ★ 상수가 아니라 **라이브 커널 값**에 대해 판정한다.
  run bash -c ". '$LIB'; hp_band_assert && echo BAND-OK"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'BAND-OK'
  run bash -c ". '$LIB'; HP_PORT_LO=30000; HP_PORT_HI=30500; hp_band_assert"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF 'NodePort'
}

@test "the band must stay inside valid ports and inside RANDOM's reach (a wider band would silently lose its top)" {
  # ★ `hp_pick_port`는 `LO + RANDOM % span`으로 뽑는데 bash RANDOM은 0..32767이다. 밴드를 넓히는 것은
  #   "포트가 모자란다"에 대한 자연스러운 처방이라 실제로 시도되는데, span > 32768이면 윗부분이
  #   **조용히 도달 불가**가 된다(실측: 20000-59999에서 3000회 추첨 시 최대값이 52765에 머문다).
  #   선언한 밴드와 실제 추첨 범위가 갈리는 것을 침묵으로 두지 않는다.
  run bash -c ". '$LIB'; HP_PORT_LO=20000; HP_PORT_HI=59999; hp_band_assert"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF 'RANDOM'
  run bash -c ". '$LIB'; HP_PORT_LO=20000; HP_PORT_HI=70000; hp_band_assert"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '65535'
}

@test "an unreadable ephemeral range file fails closed (undecidable is not a pass)" {
  run bash -c ". '$LIB'; HP_PORT_RANGE_FILE='$FX/nope'; hp_band_assert"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '읽을 수 없다'
}

@test "the probe defaults to 0.0.0.0, which sees a listener bound only to a global interface" {
  # ★ #521 이후 **새로 추가된 축**. 127.0.0.1 프로브는 이 경우를 FREE로 오답한다(실측 2026-08-21).
  #   telegram mock과 블랙홀 sink는 실제로 0.0.0.0에 바인드하므로 그 오답이 곧 EADDRINUSE 사고다.
  #   글로벌 IP가 없는 venue에서는 판정 대상이 없으므로 그 사실을 말하고 넘어간다(조용한 통과 금지).
  run env LIB="$LIB" python3 - <<'PYWITNESS'
import os, socket, subprocess, sys

ip = subprocess.run(
    ["sh", "-c", "ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1"],
    capture_output=True, text=True).stdout.strip()
if not ip:
    print("NO-GLOBAL-IP: 이 venue에는 글로벌 IPv4가 없어 이 축을 판정할 수 없다")
    sys.exit(0)

srv = socket.socket()
srv.bind((ip, 0))            # 글로벌 인터페이스 **에만** 바인드한다
held = srv.getsockname()[1]
srv.listen(1)

def probe(addr):
    return subprocess.run(
        ["bash", "-c", f'. "{os.environ["LIB"]}"; hp_port_free {held} {addr}'],
        capture_output=True).returncode

loop = probe("127.0.0.1")
anyaddr = probe("0.0.0.0")
srv.close()
print(f"held={held} on {ip}: 127.0.0.1 rc={loop} / 0.0.0.0 rc={anyaddr}")
if anyaddr == 0:
    print("PROBE-FAILED: 0.0.0.0 프로브가 점유된 포트를 FREE라고 답했다"); sys.exit(1)
if loop != 0:
    print("NOTE: 127.0.0.1 프로브도 BUSY였다 — 이 축의 대조가 성립하지 않는다(venue 특성)")
print("PROBE-OK")
PYWITNESS
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'PROBE-OK|NO-GLOBAL-IP'
}

@test "the probe reports a port held by a live accepted socket as busy, and an unused port as free" {
  # ★ connect 프로브(/dev/tcp)로 되돌리면 양성 쪽이 red고, 항상-BUSY로 망가뜨리면 음성 쪽이 red다.
  run env LIB="$LIB" python3 - <<'PYWITNESS'
import os, socket, subprocess, sys
lib = os.environ["LIB"]
# 리스너를 닫고 accepted 소켓만 남긴다 — connect는 refused(FREE)라고 답하지만 bind는 EADDRINUSE다.
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); held = srv.getsockname()[1]; srv.listen(1)
cli = socket.socket(); cli.connect(("127.0.0.1", held))
acc, _ = srv.accept(); srv.close()

def probe(port):
    return subprocess.run(["bash", "-c", f'. "{lib}"; hp_port_free {port}'], capture_output=True).returncode

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
  echo "$output" | grep -qF 'PROBE-OK'
}

@test "hp_pick_port itself refuses a reserved band — the wiring, not just the assert, is what protects consumers" {
  # ★ 밴드 레인들은 hp_band_assert를 **직접** 부른다. 소비자를 실제로 지키는 것은 hp_pick_port 안의
  #   `hp_band_assert || return 1` 배선인데, 그 한 줄을 지워도 다른 레인은 전부 초록이다. 여기서 문다.
  run bash -c ". '$LIB'; HP_PORT_LO=30000; HP_PORT_HI=32000; hp_pick_port"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF 'NodePort'
  # 음성 대조 — 정상 밴드에서는 실제로 포트를 준다(항상-실패 배선은 무측정과 같다).
  run bash -c ". '$LIB'; hp_pick_port"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^[0-9]+$'
}

@test "hp_pick_port honours the exclusion list so a two-port consumer cannot draw the same port twice" {
  # ★ 프로브는 소켓을 즉시 닫아 아무것도 붙들지 않는다 — 배제가 없으면 AM publish와 telegram mock이
  #   같은 값을 받을 수 있고, 그때 둘 중 하나가 EADDRINUSE로 죽는다.
  #   밴드를 2포트로 좁혀 **결정적으로** 시험한다(확률적 단언은 flake의 씨앗이다).
  # ⚠️ 픽스처 밴드는 프로덕션 밴드(20000-29999) **밖**에 둔다. CI에서 이 스위트는 발화 e2e 6종과
  #   **동시에** 도는데, 프로덕션 밴드 안의 고정 2포트를 잡으면 그 하네스들과 경합해 이 레인이
  #   간헐적으로 red가 된다 — 결정적으로 만들려던 픽스처가 flake의 원인이 되는 자리다.
  run bash -c ". '$LIB'; HP_PORT_LO=19101; HP_PORT_HI=19102; a=\$(hp_pick_port); b=\$(hp_pick_port \"\$a\"); echo \"\$a \$b\""
  [ "$status" -eq 0 ]
  a="$(echo "$output" | awk '{print $1}')"
  b="$(echo "$output" | awk '{print $2}')"
  [ -n "$a" ]
  [ -n "$b" ]
  [ "$a" != "$b" ]
}

@test "hp_pick_port fails closed when every port in the band is excluded (undecidable is not a pass)" {
  run bash -c ". '$LIB'; HP_PORT_LO=19201; HP_PORT_HI=19202; hp_pick_port 19201 19202"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '빈 포트를 찾지 못했다'
}

@test "the lib never exits on its own — the caller owns the exit convention" {
  # ★ 이 lib은 종료 규약이 서로 다른 세 소비자가 공유한다(exit 2 / exit 1 / 자체 fault). lib이
  #   exit를 소유하면 그 셋 중 둘의 규약이 조용히 뒤집힌다. 실패해도 **소스한 셸이 살아 있어야** 한다.
  run bash -c ". '$LIB'; HP_PORT_LO=30000; HP_PORT_HI=30500; hp_band_assert || true; echo STILL-ALIVE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'STILL-ALIVE'
  # 정적 대조 — 함수 본문에 `exit`가 없다(주석은 줄 머리 앵커로 제외).
  run bash -c "grep -vE '^[[:space:]]*#' '$LIB' | grep -c 'exit '"
  [ "$output" -eq 0 ]
}
