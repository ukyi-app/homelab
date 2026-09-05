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
# ⚠️ 토큰 **부재** 단언은 `run grep -qF … <<<"$out"` + `[ "$status" -eq 1 ]`로만 쓴다.
#    `echo "$out" | grep -qvF TOKEN`은 부재를 재지 않는다 — `-v`는 줄 단위 반전이라 "매치하지
#    않는 줄"이 하나라도 있으면 rc 0이고, 토큰이 출력에 **있어도** 통과하는 항진명제다
#    (여기 6곳이 그 관용구였고 5곳이 실측으로 항진이었다 — 남은 한 곳(`--rm` 거부)은 진단이 마침
#    **1줄**이라 우발적으로만 옳았다: 그 문구가 두 줄이 되는 날 조용히 공허해진다. 형제 실측은
#    infra/tailscale/test_provider_scopes.bats:75).
#    히어스트링은 경로 피연산자가 없어 rc 2 채널이 없으므로 `-eq 1`이 정확한 상수다
#    (docs/traps-detail.md 「처방(bats 부재 단언)」 말미). 부재 단언마다 같은 피연산자 위의
#    양성 단언이 비공허 바닥값을 겸하고, 토큰 자체의 양성 대조는 아래 두 레인이 세운다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  S="$ROOT/scripts/check-host-ports.sh"
  LIB="$ROOT/tests/gates/lib/host-port.sh"
  # ⚠️ **피연산자 실재 증인.** 이 두 파일이 이 스위트 전체의 검사 대상인데, 대상이 사라져도 이 파일은
  #   초록을 낼 수 있다 — `run bash "$S" <픽스처>`에서 `$S`가 없으면 bash가 rc **127**로 죽어
  #   `[ "$status" -ne 0 ]`을 만족하고, 뒤따르는 마커 부재 단언도 당연히 참이 된다(세 겹이 통과한다).
  #   실측(2026-08-31, 둘을 지운 격리 트리): 39건 중 **6건이 초록**이었다 — ①대상을 아예 안 쓰는
  #   레인 셋(telegram mock readiness · AM readiness 정적 대조 · 이미지 파생 완전성. 마지막 것은 로스터를
  #   추적 열거에서 뽑는데 LIB은 정의처 면제로 원래 세지 않아 n=5가 그대로였다), ②`. "$LIB"` 실패의
  #   rc 127을 "BUSY"로 읽어 통과한 0.0.0.0 프로브 레인, ③`command not found` **stderr가 `$output`에
  #   섞여** awk 필드가 비지 않은 배제목록 레인, ④rc 127 + 마커 부재로 통과한 dead-detector 레인.
  #   프로그램 rc는 그 도구의 규약이라 철자 규칙으로 못 닫는다(`bun <없는 파일>`=1인데 그 도구의
  #   **거부**도 1이다 — docs/adr/0007 「기각이 남긴 부채」·scripts/check-bats-style.sh의 [ABS] 분모 근거).
  #   그래서 이 축의 처방은 형태 규칙이 아니라 **대상이 거기 있다**는 한 줄이다(선례:
  #   tests/gates/test_app-token-sha-ssot.bats의 `[ -d .github ]`).
  [ -f "$S" ]
  [ -f "$LIB" ]
  FX="$BATS_TEST_TMPDIR"
  STUB="$FX/bin"; STATE="$FX/state"
  mkdir -p "$STUB" "$STATE"

  # hermetic docker 스텁 — 기동 프리미티브가 무는 네 가지를 모델링한다:
  #   ⓐ **이름 유일성**(실패한 run이 Created를 남긴다 → `docker rm -f`를 빼면 재시도가 전부 죽는다)
  #   ⓑ 시도 **횟수** 기반 bind 실패(포트별 픽스처는 어느 포트가 먼저 뽑히느냐에 의존해 비결정적이다)
  #   ⓒ `docker port`가 **다른** 포트를 답하는 경합(매핑 대조 레인)
  #   ⓓ `docker logs`의 식별 가능한 본문(실패 진단이 실제로 로그를 보여 주는가)
  cat > "$STUB/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
S="$STUB_STATE"
case "$1" in
  rm)   shift; while [ "$1" = "-f" ]; do shift; done; rm -f "$S/c-$1"; exit 0 ;;
  port) cat "$S/mapped" 2>/dev/null; exit 0 ;;
  logs) echo "STUBLOG-COOKIE last lines of the container log"; exit 0 ;;
  network) exit 0 ;;
  run)
    name=""; hostport=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name="$2"; shift ;;
        -p) hostport="${2#127.0.0.1:}"; hostport="${hostport%%:*}"; shift ;;
      esac
      shift
    done
    printf '%s\n' "$hostport" >> "$S/ports"
    n=$(cat "$S/attempts" 2>/dev/null || echo 0); n=$(( n + 1 )); printf '%s\n' "$n" > "$S/attempts"
    if [ -e "$S/c-$name" ]; then
      echo "Error response from daemon: container name \"/$name\" is already in use" >&2
      exit 125
    fi
    if [ "$n" -le "$(cat "$S/failfirst" 2>/dev/null || echo 0)" ]; then
      : > "$S/c-$name"   # ⚠️ 실패한 run도 컨테이너를 Created로 남긴다(docker/podman 공통 의미론)
      echo "STUBFAIL-COOKIE rootlessport listen tcp 127.0.0.1:$hostport: bind: address already in use" >&2
      exit 126
    fi
    : > "$S/c-$name"
    if [ -s "$S/mismatch" ]; then printf '127.0.0.1:%s\n' "$(cat "$S/mismatch")" > "$S/mapped"
    else printf '127.0.0.1:%s\n' "$hostport" > "$S/mapped"; fi
    exit 0 ;;
esac
exit 0
DOCKEREOF
  chmod +x "$STUB/docker"
}

# 프리미티브를 스텁 런타임 위에서 부른다. $1 = 호출 전에 끼울 셸 코드, $2 = hp_run_published 인자열.
# ⚠️ 호출 뒤에 `AFTER-CALL`을 찍는다 — 실패 레인에서 이 토큰이 **없어야** 한다. rc를 흘리면
#    `set -e` 아래에서도 통과해 버리는 자리라 "죽었는가"를 출력으로도 함께 문다.
run_published() {
  run env PATH="$STUB:$PATH" STUB_STATE="$STATE" bash -c "
    set -euo pipefail
    . '$LIB'
    $1
    p=\"\$(hp_run_published $2)\"
    printf 'PORT=%s\n' \"\$p\"
    echo AFTER-CALL
  "
}

# AM 하네스를 **격리 루트**에서 돌린다 — 뮤테이션 사본을 실 트리에 쓰지 않기 위해서다.
# 하네스가 ROOT를 `dirname $0/../..`로 잡으므로 그 모양만 만들어 주고 나머지 자산은 심링크로 빌린다.
# $1=루트 경로 $2=하네스에 걸 sed 스크립트("" = 무변경) $3=host-port.sh에서 지울 고정 문자열("" = 무변경)
# ⚠️ 뮤테이션은 정규식이 아니라 **고정 문자열**로 지운다 — 패턴에 `|`·`$`가 들어가면 메타문자로
#    삼켜져 치환이 조용히 실패하고, 그러면 그 레인이 원본을 검사해 vacuous하게 통과한다.
am_root() {
  local r="$1" hsed="${2:-}" hpdrop="${3:-}"
  mkdir -p "$r/tests/gates/lib" "$r/platform/victoria-stack/prod/alertmanager-config"
  ln -s "$ROOT/tests/gates/mock-telegram.py" "$r/tests/gates/mock-telegram.py"
  ln -s "$ROOT/tests/gates/fixtures"         "$r/tests/gates/fixtures"
  # 하네스가 읽는 두 자리를 격리 루트에 그대로 비춘다: 매니페스트(이미지 digest 파생)와
  # **설정 본문**(configMapGenerator가 굽는 파일). 후자가 빠지면 하네스가 `[ -s ]` 앵커에서
  # 즉사해 아래 docker 축 레인들이 자기 축 대신 그 즉사를 재게 된다(전환 당시 실측 red 1건).
  ln -s "$ROOT/platform/victoria-stack/prod/alertmanager.yaml" \
        "$r/platform/victoria-stack/prod/alertmanager.yaml"
  ln -s "$ROOT/platform/victoria-stack/prod/alertmanager-config/alertmanager.yml" \
        "$r/platform/victoria-stack/prod/alertmanager-config/alertmanager.yml"
  if [ -n "$hpdrop" ]; then grep -vF "$hpdrop" "$LIB" > "$r/tests/gates/lib/host-port.sh"
  else cp "$LIB" "$r/tests/gates/lib/host-port.sh"; fi
  if [ -n "$hsed" ]; then
    sed "$hsed" "$ROOT/tests/gates/alertmanager-render-e2e.sh" > "$r/tests/gates/alertmanager-render-e2e.sh"
  else cp "$ROOT/tests/gates/alertmanager-render-e2e.sh" "$r/tests/gates/alertmanager-render-e2e.sh"; fi
}

run_am() { # $1=격리 루트
  run env PATH="$STUB:$PATH" STUB_STATE="$STATE" bash "$1/tests/gates/alertmanager-render-e2e.sh"
}

# ── 가드의 변별력 ────────────────────────────────────────────────────────────────

@test "lane A fires on a literal host port in a publish argument and stays quiet on an assigned one" {
  # 실제로 있던 형태 그대로 — 예전 alertmanager-render-e2e.sh:40이 이것이었다.
  printf '#!/usr/bin/env bash\ndocker run -d -p 9093:9093 img\n'                  > "$FX/dirty.sh"
  printf '#!/usr/bin/env bash\ndocker run -d -p 127.0.0.1:9093:9093 img\n'        > "$FX/dirty2.sh"
  # ⚠️ 음성 대조는 **모든 레인에 대해** 깨끗해야 한다 — publish 인자가 있는 파일은 레인 E도 보므로
  #   기동 프리미티브 사용이 함께 요구된다. 그 줄을 빼면 이 대조가 [A]가 아닌 [P]로 red가 돼
  #   "레인 A가 변수 포트에 침묵한다"는 축을 더 이상 재지 못한다.
  printf '#!/usr/bin/env bash\n. lib/host-port.sh\nQ="$(hp_run_published c 9093 "" img)"\ndocker run -d -p "127.0.0.1:${P}:9093" img\n' > "$FX/clean.sh"
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

@test "lane C and P do not treat an error-hint string mentioning the lib names as wiring (active-string control)" {
  # ★ 적대적 리뷰가 잡은 자리 — nocomment()는 주석만 걷고 **문자열 리터럴**은 안 걷는다. 실패 힌트
  #   echo 한 줄에 "host-port.sh"·"hp_pick_port"·"hp_run_published"를 적기만 해도(호출/소스가 아니라
  #   언급만) 예전 판은 그것을 배정·기동 프리미티브 사용의 증인으로 오인했다 — 마지막 방어선이
  #   활성 코드의 문자열 한 줄로 무너졌다. 증인은 호출/소스 표기만 인정해야 한다.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'AM_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind((\"\",0)); print(s.getsockname()[1])")' \
    'docker run -d --name am -p "127.0.0.1:${AM_PORT}:9093" img' \
    'echo "힌트: 포트는 hp_pick_port로 배정받고 컨테이너는 hp_run_published(tests/gates/lib/host-port.sh)로 띄워라" >&2' \
    > "$FX/hintonly.sh"
  run bash "$S" "$FX/hintonly.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '[C]'
  echo "$output" | grep -qF '[P]'
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

@test "lane E fires when a file publishes a container without going through the run primitive" {
  # ★ A·B·C·D가 **전부 침묵하는** 자리다 — 배정은 lib에서 받고(hp_pick_port) 기동만 손으로 인라인하면
  #   `docker rm -f` 선행·`--rm` 금지·비판별 재시도·매핑 대조·logs tail 6불변식이 그 사이트만 빠진다.
  #   그게 이 가드를 태어나게 한 병(처방이 한 소비자에 갇힘)이 **한 층 위**에서 재발한 모양이었다.
  printf '#!/usr/bin/env bash\n. tests/gates/lib/host-port.sh\nP="$(hp_pick_port)"\ndocker run -d --name x -p "127.0.0.1:${P}:9093" img\n' > "$FX/inline.sh"
  run bash "$S" "$FX/inline.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[P]'
  # 음성 대조 — publish 인자가 있어도 프리미티브를 쓰면 조용하다(항상-발화 레인은 무측정과 같다).
  printf '#!/usr/bin/env bash\n. tests/gates/lib/host-port.sh\nP="$(hp_run_published c 9093 "" img)"\ndocker run -d -p "127.0.0.1:${P}:9093" other\n' > "$FX/viaprim.sh"
  run bash "$S" "$FX/viaprim.sh"; [ "$status" -eq 0 ]
  # ★ 그리고 **행간 주석은 사용으로 치지 않는다** — 이름을 적기만 해도 통과하면 마지막 방어선이
  #   주석 한 줄로 무너진다([C]와 같은 규율).
  printf '#!/usr/bin/env bash\n. tests/gates/lib/host-port.sh\nP="$(hp_pick_port)"\ndocker run -d -p "127.0.0.1:${P}:9093" img   # hp_run_published 로 바꿀 것\n' > "$FX/cmtonly.sh"
  run bash "$S" "$FX/cmtonly.sh"; [ "$status" -ne 0 ]; echo "$output" | grep -qF '[P]'
}

@test "lane E exempts the definition site by name and refuses a second definition (the exemption is not a bypass)" {
  # 정의처는 소비자가 아니다 — 파일 목록이 아니라 "이 파일이 그 함수를 정의하는가"라는 규칙이라
  # (레인 D의 HP_ 이름공간 면제와 같은 형태) lib을 옮겨도 판정이 갈리지 않는다.
  def='#!/usr/bin/env bash\nhp_pick_port() { echo 1; }\nhp_run_published() {\n  docker run -d --name "$1" -p "127.0.0.1:${port}:${2}" "$@"\n}\n'
  printf "$def" > "$FX/def1.sh"
  run bash "$S" "$FX/def1.sh"; [ "$status" -eq 0 ]
  # ★ 그 면제가 **우회 통로**가 되면 안 된다 — 프리미티브를 자기 파일로 복사하면 그만이기 때문이다.
  #   기동 처방의 SSOT는 하나이므로 사본의 존재 자체가 위반이다.
  printf "$def" > "$FX/def2.sh"
  run bash "$S" "$FX/def1.sh" "$FX/def2.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '[P]'
  echo "$output" | grep -qF 'SSOT'
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
  printf '#!/usr/bin/env bash\n. tests/gates/lib/host-port.sh\nQ="$(hp_run_published c 9093 "" img)"\ndocker run -d -p "127.0.0.1:${P}:9093" img\n' > "$FX/qok.sh"
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

@test "every ampersand-launched helper harness waits for its readiness token (the AM one also escapes on helper death)" {
  # ★ 정적 대조(변경 감지기임을 자인한다) — readiness 대기가 있어야 한다. 옛 레인은 AM 하네스
  #   한 파일에만 못박혀 있었다 — 형제 표면 skopeo-timeout-smoke.sh(sink readiness :89-95)의
  #   삭제는 전건 초록이었다(2026-09-03 뮤테이션 실측: :91-95 삭제 → 39 ok/0 not ok, AM 쪽
  #   동일 뮤테이션은 6건 red — 비대칭 그 자체가 갭이었다). 열거 키는 `=$!`(백그라운드 pid
  #   포획) — "`&`로 띄운 헬퍼"라는 도메인 자체라 python→다른 헬퍼 표기 드리프트에 안 깨진다.
  # ⚠️ **주석을 세면 안 된다.** 이 레포의 하네스는 자기가 고친 함정을 인용하며 설명하므로, 코드를
  #   지우고 주석으로 옮기는 리팩터가 자연스럽다 — 그러면 오진이 돌아오는데 게이트는 초록이다.
  hs="$(git ls-files 'tests/gates/*.sh' 'tests/gates/lib/*.sh' | xargs grep -lE '=\$!' || true)"
  n=0
  for f in $hs; do
    n=$(( n + 1 ))
    CODE="$BATS_TEST_TMPDIR/h-code.sh"
    grep -vE '^[[:space:]]*#' "$f" > "$CODE"
    run grep -c "grep -q 'listening'" "$CODE"
    [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
  done
  [ "$n" -ge 2 ]   # 열거 붕괴 바닥값 — 현재 AM·skopeo 둘

  # AM 하네스 전용 — 대기만 있고 `kill -0` 탈출이 없으면 이미 죽은 헬퍼를 상대로 타임아웃을 꽉
  # 채워, 오진 시간이 줄어들 뿐 없어지지 않는다. skopeo 쪽은 10초 상한 + 정확한 fault라 별도다.
  H="$ROOT/tests/gates/alertmanager-render-e2e.sh"
  CODE="$BATS_TEST_TMPDIR/am-code.sh"
  grep -vE '^[[:space:]]*#' "$H" > "$CODE"
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
  # ⚠️ 열거 키가 `docker run`**만**이면 안 된다. 기동이 `hp_run_published`로 접힌 뒤 publish 하네스
  #   둘(AM 렌더 e2e · vmalert lib)에는 `docker run` 줄이 아예 없어 — 정작 이미지를 **파생하는**
  #   그 둘이 이 레인 밖으로 조용히 빠져나간다. 키는 "컨테이너를 띄우는가"이지 표기가 아니다.
  hs="$(git ls-files 'tests/gates/*.sh' 'tests/gates/lib/*.sh' | xargs grep -lE 'docker run|hp_run_published' || true)"
  n=0
  for f in $hs; do
    CODE="$BATS_TEST_TMPDIR/harness-code.sh"
    # 프리미티브의 **정의처**는 이미지를 인자로 받을 뿐 이름을 대지 않는다 — 파생을 요구할 대상이
    # 아니다(파일 목록이 아니라 "그 함수를 정의하는가" 규칙 — 가드 레인 E와 같은 형태).
    if grep -qE '^[[:space:]]*hp_run_published[[:space:]]*\(\)' "$f"; then continue; fi
    n=$(( n + 1 ))
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
  # ⚠️ 바닥값은 루프 **뒤**에 온다 — xargs는 빈 입력에서 grep을 아예 안 부르고 0을 내므로 hs가 비면
  #   위 for가 통째로 vacuous하다. 실제로 검사한 건수를 세어 막는다(면제 스킵도 여기서 반영된다).
  [ "$n" -ge 5 ]
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
  # ★ `exit`만 없으면 되는 게 아니다. **인자 부족**에서 `shift 3`이 먼저 돌면 bash가 rc 1을 내고
  #   소비자의 `set -e`가 셸을 죽인다 — 한 줄의 exit도 없이 lib이 종료를 소유하는 자리다.
  run env PATH="$STUB:$PATH" STUB_STATE="$STATE" bash -c "
    set -euo pipefail
    . '$LIB'
    hp_run_published c 8080 || echo \"RC=\$?\"
    echo STILL-ALIVE
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'RC=1'
  echo "$output" | grep -qF 'STILL-ALIVE'
}

@test "a dead detector emits no marker (a run that could not scan must not claim it did)" {
  # 형제 check-locale-collation·check-bats-style와 같은 규율.
  run bash "$ROOT/scripts/check-host-ports.sh" "$BATS_TEST_TMPDIR/does-not-exist.sh"
  [ "$status" -ne 0 ]
  out="$output"
  # ★ **양성 대조 — 가드가 실제로 돌아서 거부했다.** `-ne 0` + 마커 부재만 물면 이 레인은 가드가
  #   사라진 트리에서도 초록이다: bash가 없는 스크립트에 rc **127**을 내 첫 단언을 만족시키고,
  #   돌지 않은 프로그램은 당연히 마커도 안 낸다(실측 — 이 레인이 그 6건 중 하나였다).
  #   자기 진단 문구를 함께 물어 "죽은 검출기"와 "없는 검출기"를 갈라낸다(guard.sh detect_run의
  #   읽기 검증 경로 — 문구가 바뀌면 여기가 red로 알린다).
  printf '%s' "$out" | grep -qF '읽을 수 없는 대상'
  run grep -q '^SCAN: check-host-ports:' <<<"$out"
  [ "$status" -ne 0 ]
}

# ── 기동 프리미티브(hp_run_published)의 계약 ──────────────────────────────────────
# 이 여섯 축은 예전에 `lib/vmalert-e2e.sh`와 `alertmanager-render-e2e.sh`에 **두 벌로** 살았고,
# AM 사본에 대한 증인은 0건이었다. 정의처가 하나가 됐으므로 증인도 여기 하나로 모은다.

@test "the run primitive refuses --rm before it starts anything (the flag that erases the diagnosis)" {
  # ★ 오진 서사를 되살리는 **유일한 편집**이다. 컨테이너가 기동 직후 죽으면(= 이 게이트들이 존재하는
  #   이유인 설정 회귀) `--rm`이 컨테이너를 즉시 지워 `docker port`도 `docker logs`도 실패한다 —
  #   남는 것은 "매핑을 확인할 수 없다" 한 줄뿐이고 원인은 어디에도 없다.
  run_published "" 'c 8080 "" --rm img'
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF -- '--rm은 받지 않는다'
  # ★ **띄우기 전에** 거부한다 — 조용히 무시하면 호출부는 정리가 걸렸다고 믿은 채 책임을 놓는다.
  [ ! -s "$STATE/ports" ]
  run grep -qF 'AFTER-CALL' <<<"$output"
  [ "$status" -eq 1 ]
  # 음성 대조 — 같은 인자에서 `--rm`만 빼면 통과한다(항상-거부는 무측정과 같다).
  run_published "" 'c 8080 "" img'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^PORT=[0-9]+$'
  # ★ 그리고 이것이 `AFTER-CALL` 부재 단언 네 곳(이 파일의 실패 레인)의 **양성 대조**다 — 성공
  #   경로에서 토큰이 실제로 나온다. run_published에서 `echo AFTER-CALL` 한 줄이 사라지면 네 레인이
  #   전부 조용히 공허해지는데, 그것을 무는 자리가 여기 하나뿐이다.
  echo "$output" | grep -qF 'AFTER-CALL'
}

@test "a transient bind failure is retried on a different port, announced, and the returned port is the new one" {
  # ⚠️ 픽스처 밴드는 프로덕션 밴드(20000-29999) **밖**에 둔다 — CI에서 이 스위트는 발화 e2e와
  #   동시에 도는데, 프로덕션 밴드 안의 고정 포트를 잡으면 그 하네스들과 경합해 간헐 red가 된다.
  # 실패는 **시도 횟수**로 주입한다. 포트별 픽스처는 어느 포트가 먼저 뽑히느냐에 의존해 비결정적이라,
  # 첫 추첨이 성공 포트를 집으면 재시도가 아예 안 일어나 이 레인이 통째로 vacuous하다.
  printf '1\n' > "$STATE/failfirst"
  run_published "HP_PORT_LO=19501; HP_PORT_HI=19502" 'c 8080 "" img'
  [ "$status" -eq 0 ]
  out="$output"
  # 조용한 재시도 금지 — 발생 사실이 로그에 없으면 경합 빈도가 관측되지 않는다.
  # ⚠️ 고정 문자열 `RETRY (bind`로 세면 안 된다 — 성공 요약줄(`RETRY (bind): …번째 시도에서 성공`)도
  #   같은 접두라, **시도별** 줄을 통째로 지워도 이 단언이 통과한다(실측 뮤테이션). 카운터 형태를 문다.
  printf '%s' "$out" | grep -qE 'RETRY \(bind [0-9]+/[0-9]+\)'
  # ★ **서로 다른** 포트다. 프리미티브가 실패 포트를 배제 목록에 누적하므로 확률이 아니라 구조다 —
  #   누적을 지우면 2포트 밴드에서 같은 값이 다시 나와 "서로 다른 포트" 진단이 거짓이 된다.
  # ⚠️ `LC_ALL=C` 필수 — en_US 콜레이션은 서로 다른 값을 같다고 보고 하나를 버린다(#514의 fail-open).
  run bash -c "LC_ALL=C sort -u '$STATE/ports' | grep -c ."
  [ "$output" -eq 2 ]
  # ★ 그리고 stdout으로 돌려주는 값은 **두 번째** 포트다. 첫 요청값을 그대로 되돌려주면 호출자는
  #   아무도 안 듣는 포트에 readiness를 걸고 타임아웃을 통째로 태운 뒤 엉뚱한 곳을 가리킨다.
  second="$(sed -n '2p' "$STATE/ports")"
  [ -n "$second" ]
  printf '%s' "$out" | grep -qF "PORT=${second}"
}

@test "the retry draws from a shrinking pool — a two-port band cannot serve a third attempt" {
  # ★ "서로 다른 포트로 재시도한다"를 **결정적으로** 문다. 앞 레인의 `sort -u` 카운트는 배제 누적을
  #   지워도 재추첨이 우연히 다른 값을 낼 확률이 남아 있어(2포트 밴드에서 50%) 뮤테이션을 절반만
  #   잡는다 — 확률적 증인은 회귀를 통과시키는 쪽으로 틀린다.
  #   2포트 밴드에서 앞 두 시도가 실패하면 세 번째 추첨은 **원리적으로 불가능**해야 한다:
  #   누적이 있으면 밴드 고갈(빈 포트를 찾지 못했다), 없으면 이미 쓴 포트를 다시 뽑아 **성공**한다.
  printf '2\n' > "$STATE/failfirst"
  run_published "HP_PORT_LO=19531; HP_PORT_HI=19532" 'c 8080 "" img'
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '빈 포트를 찾지 못했다'
  run grep -qF 'AFTER-CALL' <<<"$output"
  [ "$status" -eq 1 ]
}

@test "the retry removes the Created leftover, otherwise every retry dies of the name collision" {
  # ★ 실패한 `docker run -d`는 컨테이너를 Created로 남긴다. `docker rm -f`를 빼면 재시도가 전부
  #   "name already in use"로 죽는다 — 재시도가 있는데도 회복하지 못한다. 그 삭제를 여기서 문다.
  # ⚠️ 정규식이 아니라 고정 문자열로 지운다 — 패턴에 `|`·`$`가 들어가면 메타문자로 삼켜져 치환이
  #   조용히 실패하고, 그러면 이 레인이 원본 lib을 검사해 vacuous하게 통과한다.
  run grep -cF 'docker rm -f "$name"' "$LIB"
  [ "$output" -eq 1 ]
  grep -vF 'docker rm -f "$name"' "$LIB" > "$FX/lib-norm.sh"
  run grep -cF 'docker rm -f "$name"' "$FX/lib-norm.sh"
  [ "$output" -eq 0 ]
  printf '1\n' > "$STATE/failfirst"
  run env PATH="$STUB:$PATH" STUB_STATE="$STATE" bash -c "
    set -euo pipefail
    . '$FX/lib-norm.sh'
    HP_PORT_LO=19511; HP_PORT_HI=19512
    hp_run_published c 8080 '' img
  "
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF 'already in use'
}

@test "a permanent bind failure returns non-zero after distinct ports and surfaces the runtime stderr verbatim" {
  printf '9\n' > "$STATE/failfirst"   # 모든 시도를 실패시킨다(HP_BIND_TRIES=3보다 크게)
  run_published "HP_PORT_LO=19521; HP_PORT_HI=19523" 'c 8080 "" img'
  [ "$status" -ne 0 ]
  out="$output"
  # ⚠️ 실패를 **메시지·종료코드로 판별하지 않는다** — 같은 podman도 pasta/rootlessport로 문자열이
  #   갈리고 CI dockerd는 또 다르다. 판별자는 "서로 다른 포트로 다시 하면 되는가" 하나이므로,
  #   원본 stderr는 삼키지 않고 그대로 흘려야 진단이 남는다.
  printf '%s' "$out" | grep -qF 'STUBFAIL-COOKIE'
  printf '%s' "$out" | grep -qF '서로 다른 포트'
  run grep -qF 'AFTER-CALL' <<<"$out"
  [ "$status" -eq 1 ]
  run bash -c "LC_ALL=C sort -u '$STATE/ports' | grep -c ."
  [ "$output" -eq 3 ]
}

@test "a mapping mismatch kills the call before readiness and shows the container log" {
  # ★ 예전엔 `docker port` 출력을 그대로 믿었다. 경합으로 매핑이 어긋나면 호출자의 readiness 루프가
  #   30~60초를 통째로 태운 뒤에야 "not ready"로 죽어 원인이 안 보였다.
  printf '19999\n' > "$STATE/mismatch"
  run_published "" 'c 8080 "" img'
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '포트 매핑을 확인할 수 없다'
  # 실패 진단이 실제로 컨테이너 로그를 보여 준다(삼키면 설정 회귀의 원인이 사라진다).
  echo "$output" | grep -qF 'STUBLOG-COOKIE'
  # ★ 호출자에게 **돌아가지 않는다** — 이 대조가 없으면 rc를 흘리는 구현도 통과한다.
  run grep -qF 'AFTER-CALL' <<<"$output"
  [ "$status" -eq 1 ]
}

@test "the run primitive stops before readiness — judging a response body stays each harness's own policy" {
  # ★ docs/adr/0005가 지킨 축(CONTEXT.md 「판정 어휘」). 프리미티브가 readiness를 삼키면 vmsingle의
  #   `/health` 본문 `OK*` 판정과 AM의 `/-/ready`가 하나로 접히는데, 그 둘은 서로 다른 하네스-로컬
  #   정책이고 진단 문구("NodePort DNAT 등")의 절반이 거기 있다. 정적 대조 — 주석은 걷어낸다.
  # ⚠️ 판정 토큰은 **엔드포인트와 대기 상태 변수**로 잡는다. `curl`을 토큰에 넣으면 이 lib의 밴드
  #   진단 문구("하네스 자신의 curl이 그 대역에서 소스 포트를 만든다")가 걸려, 근거를 적은 주석을
  #   지우게 만드는 오탐이 된다 — 이 레포가 이미 형제 게이트에서 밟은 자리다.
  CODE="$FX/hp-code.sh"
  grep -vE '^[[:space:]]*#' "$LIB" > "$CODE"
  run bash -c "grep -coE '/health|/-/ready|ready=[0-9]' '$CODE' || true"
  [ "$output" -eq 0 ]
  # 음성 대조 — 두 소비자는 각자 자기 readiness를 **가지고 있다**. 양쪽이 0이면 위 단언은 무측정이다.
  run bash -c "grep -coE '/health|ready=[0-9]' '$ROOT/tests/gates/lib/vmalert-e2e.sh'"
  [ "$output" -ge 2 ]
  run bash -c "grep -coE '/-/ready|ready=[0-9]' '$ROOT/tests/gates/alertmanager-render-e2e.sh'"
  [ "$output" -ge 2 ]
}

@test "both publishing harnesses consume the primitive and none of them docker-runs a published container inline" {
  # ★ 완전성 레인. 로스터를 박으면 새 하네스가 이 레인 밖에서 태어나므로 추적 열거에서 파생한다.
  #   `consumers(publish) ⊂ consumers(port)`가 이 처방의 배치 근거였다 — 그 포함 관계가 유지되는지
  #   여기서 잰다(프리미티브를 쓰는 파일은 반드시 lib을 source한다).
  hs="$(git ls-files 'tests/gates/*.sh' 'tests/gates/lib/*.sh' \
        | xargs grep -l 'hp_run_published' || true)"
  n=0
  for f in $hs; do
    if grep -qE '^[[:space:]]*hp_run_published[[:space:]]*\(\)' "$f"; then continue; fi   # 정의처
    n=$(( n + 1 ))
    run grep -c 'host-port\.sh' "$f"
    [ "$output" -ge 1 ]
    # 인라인 publish가 남아 있으면 6불변식이 그 사이트만 빠진다. 판정은 **가드가 소유한다** —
    # 여기에 두 번째 판정자를 두면 둘이 갈리고, 갈린 쪽이 조용히 약한 쪽이 된다(레인 E의 동적 형제).
    # ⚠️ `docker run` 존재 자체를 세면 안 된다 — vmalert lib은 publish 없는 vmalert replay 컨테이너를
    #   정당하게 띄운다(`docker run --rm --network …`). 금지 대상은 **publish 컨테이너**뿐이다.
    run bash "$S" "$f"
    [ "$status" -eq 0 ]
  done
  # 소비자가 0이면 위 for가 vacuous하다 — 오늘 둘(AM 렌더 e2e · vmalert lib의 vmsingle)이다.
  [ "$n" -ge 2 ]
}

# ── AM 하네스가 그 처방을 실제로 **받는가** ────────────────────────────────────────
# 오늘까지 AM 사본에 대한 동적 증인은 0건이었다(그 사본이 6불변식을 손으로 들고 있었는데도).
# 격리 루트에서 실제로 하네스를 태워, 프리미티브의 rc가 **이 하네스의 종료 규약(exit 1)** 으로
# 번역되는지와 세 불변식이 그대로 도착하는지를 함께 문다.

@test "the AM harness retries on distinct ports and translates the primitive rc into its own exit 1" {
  printf '9\n' > "$STATE/failfirst"
  am_root "$FX/r1"
  run_am "$FX/r1"
  # ★ 형제 vmalert lib은 **같은 rc**를 HARNESS FAULT(exit 2)로 옮긴다. 소비자마다 규약이 다르므로
  #   프리미티브가 exit를 소유하면 둘 중 하나가 조용히 뒤집힌다 — 그래서 rc 번역이 소비자 몫이다.
  [ "$status" -eq 1 ]
  out="$output"
  printf '%s' "$out" | grep -qF 'STUBFAIL-COOKIE'
  printf '%s' "$out" | grep -qF 'RETRY (bind'
  # readiness를 태우지 않았다 — 예전 오진의 서명이 "30초 뒤 AM not ready"였다.
  run grep -qF 'AM not ready' <<<"$out"
  [ "$status" -eq 1 ]
  run bash -c "LC_ALL=C sort -u '$STATE/ports' | grep -c ."
  [ "$output" -eq 3 ]
}

@test "the AM harness dies on a mapping mismatch before entering its readiness loop" {
  printf '19999\n' > "$STATE/mismatch"
  am_root "$FX/r2"
  run_am "$FX/r2"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF '포트 매핑을 확인할 수 없다'
  echo "$output" | grep -qF 'STUBLOG-COOKIE'
  # ★ 30초를 태운 뒤 "AM not ready"로 죽는 것이 예전의 오진이었다 — 그 문구가 나오면 seam이 뒤로 밀렸다.
  run grep -qF 'AM not ready' <<<"$output"
  [ "$status" -eq 1 ]
}

@test "the AM harness still says AM not ready when it does reach readiness (positive control for that token)" {
  # ★ 위 두 레인(재시도 소진 · 매핑 불일치)의 **양성 대조**다. 둘은 "readiness에 들어가기 전에
  #   죽는다"를 `AM not ready` 부재로 재는데, 그 문구가 하네스에서 사라지거나 이름이 바뀌면 두 레인이
  #   조용히 공허해진다 — 부재 단언은 자기 술어가 살아 있음을 스스로 증명하지 못한다.
  #   여기서는 프리미티브를 **성공시켜** 실제로 readiness 루프에 들어가게 하고, 그 문구가 나오는지를
  #   본다. 즉 seam이 정확히 어디에서 끊기는지를 두 극성으로 함께 못 박는다.
  # ⚠️ 루프를 1회로 줄인다 — 원본은 0.5초 × 60회라 이 대조 하나가 스위트를 30초 늘린다.
  #   스텁 docker 위에는 아무것도 listen하지 않으므로 curl은 매번 빈 본문을 받는다.
  # ⚠️ 줄 끝 `do$`로 앵커한다 — 같은 `$(seq 60)` 루프가 아래 telegram 캡처 대기에도 있어서,
  #   앵커가 없으면 둘 다 바뀌어 이 스위트가 무는 대상이 흐려진다(실측: 치환 2건).
  am_root "$FX/r5" 's|in $(seq 60); do$|in $(seq 1); do|'
  # 뮤테이션이 실제로 걸렸는지 먼저 확인한다(치환이 조용히 실패하면 이 레인이 원본을 30초 태운다).
  run grep -cF 'in $(seq 1); do' "$FX/r5/tests/gates/alertmanager-render-e2e.sh"
  [ "$output" -eq 1 ]
  run_am "$FX/r5"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'AM not ready'
  # 여기까지 온 것 자체가 프리미티브가 성공했다는 뜻이다 — 매핑 대조를 통과했고 포트도 하나뿐이다.
  run bash -c "LC_ALL=C sort -u '$STATE/ports' | grep -c ."
  [ "$output" -eq 1 ]
}

@test "the AM harness receives the --rm refusal (a mutation that would erase its own diagnosis)" {
  am_root "$FX/r3" 's|--add-host=host.docker.internal:host-gateway|--rm --add-host=host.docker.internal:host-gateway|'
  # 뮤테이션이 실제로 걸렸는지 먼저 확인한다 — 치환이 조용히 실패하면 이 레인이 원본을 태워
  # vacuous하게 통과한다(고정 문자열로 대조한다).
  run grep -cF -- '--rm --add-host' "$FX/r3/tests/gates/alertmanager-render-e2e.sh"
  [ "$output" -eq 1 ]
  run_am "$FX/r3"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF -- '--rm은 받지 않는다'
  [ ! -s "$STATE/ports" ]
}

@test "the AM harness recovers from the Created leftover only because the primitive removes it" {
  # ★ AM 하네스에는 이 축의 증인이 0건이었다. 프리미티브에서 `docker rm -f`를 지운 사본으로 태우면
  #   재시도가 전부 "name already in use"로 죽는다 — 하네스가 그 처방을 **받고 있다**는 증거다.
  printf '1\n' > "$STATE/failfirst"
  am_root "$FX/r4" "" 'docker rm -f "$name"'
  run grep -cF 'docker rm -f "$name"' "$FX/r4/tests/gates/lib/host-port.sh"
  [ "$output" -eq 0 ]
  run_am "$FX/r4"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'already in use'
}
